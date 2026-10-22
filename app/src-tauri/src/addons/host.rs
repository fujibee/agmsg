//! Window-side wiring of add-on panes: the main window with its native
//! navigation controls, the engine hardening, and the startup probe that
//! decides whether add-ons may run on this machine.
//!
//! Layers (each measured in M1; none is enough alone):
//! - the command ACL (`build.rs`, `capabilities/`) keeps every app command away
//!   from anything but the main UI;
//! - the main-window CSP `frame-src http://127.0.0.1:*` (`tauri.conf.json`)
//!   keeps an add-on frame from navigating itself to the app origin, which the
//!   native handler cannot tell apart from the app reloading itself;
//! - the native handlers below cancel every other navigation, new window and
//!   download;
//! - the engine settings (`engine`) switch off what CSP does not govern;
//! - the probe confirms all of it, for every page load, with an app-owned frame.

use std::collections::HashMap;
use std::net::UdpSocket;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tauri::webview::{NewWindowResponse, PageLoadEvent};
use tauri::{AppHandle, Emitter, Manager, Runtime, Url, WebviewWindowBuilder};

use super::csp::Network;
use super::engine;
use super::gate::{AddonGate, EngineReport, Os, ProbeReport, Verdict, PROBE_TIMEOUT};
use super::nav::NavPolicy;
use super::server::{PaneServer, PaneSpec, Payload};

/// Event the UI listens to; the payload is the `Verdict`.
pub const GATE_EVENT: &str = "addon-gate";

/// One probe in flight.
struct ProbeRun {
    nonce: String,
    server: PaneServer,
    udp_hits: Arc<AtomicUsize>,
    udp_stop: Arc<AtomicBool>,
    udp_port: u16,
}

pub struct AddonHost {
    pub gate: AddonGate,
    pub nav: NavPolicy,
    pub panes: super::commands::Panes,
    catalog: std::sync::OnceLock<super::catalog::Catalog>,
    engine: Mutex<EngineReport>,
    probe: Mutex<Option<ProbeRun>>,
}

impl AddonHost {
    /// The built-in and installed add-ons. Set once at startup.
    pub fn catalog(&self) -> &super::catalog::Catalog {
        self.catalog.get().expect("the add-on catalog is set at startup")
    }

    pub fn new(dev_url: Option<&Url>) -> AddonHost {
        AddonHost { gate: AddonGate::new(), nav: NavPolicy::new(dev_url), panes: super::commands::Panes::new(), catalog: std::sync::OnceLock::new(), engine: Mutex::new(EngineReport::default()), probe: Mutex::new(None) }
    }

    fn end_probe(&self) {
        if let Some(run) = self.probe.lock().unwrap().take() {
            run.udp_stop.store(true, Ordering::SeqCst);
            // wake the UDP reader so it exits
            if let Ok(s) = UdpSocket::bind("127.0.0.1:0") {
                let _ = s.send_to(b"x", ("127.0.0.1", run.udp_port));
            }
            self.nav.unregister_pane(run.server.port(), run.server.token());
            run.server.stop();
        }
    }
}

/// Builds the main window (tauri.conf has `create: false` so the handlers can
/// be attached) and registers the add-on host state. Call first in `setup`.
pub fn init<R: Runtime>(app: &tauri::App<R>) -> tauri::Result<()> {
    let handle = app.handle().clone();
    let cfg = app.config().app.windows.first().cloned().expect("tauri.conf.json defines the main window");
    let dev_url = app.config().build.dev_url.clone();
    let dev_url = if cfg!(dev) { dev_url } else { None };
    let host = Arc::new(AddonHost::new(dev_url.as_ref()));
    app.manage(host.clone());

    let nav_host = host.clone();
    let load_host = host.clone();
    let load_handle = handle.clone();
    let window = WebviewWindowBuilder::from_config(&handle, &cfg)?
        .on_navigation(move |url| {
            let d = nav_host.nav.decide(url);
            if !d.is_allow() {
                eprintln!("[addons] cancelled navigation to {} ({:?})", redact(url), d);
            }
            d.is_allow()
        })
        .on_new_window(|url, _features| {
            eprintln!("[addons] denied new window to {}", redact(&url));
            NewWindowResponse::Deny
        })
        .on_download(|_webview, _event| false)
        .on_page_load(move |webview, payload| {
            let is_app = load_host.nav.is_app(payload.url());
            match payload.event() {
                PageLoadEvent::Started => {
                    // a new page voids every pane: servers stop, tokens die, feeds go
                    for (port, token) in load_host.panes.close_all() {
                        load_host.nav.unregister_pane(port, &token);
                    }
                    load_host.end_probe();
                    load_host.gate.invalidate("page load");
                    let _ = load_handle.emit(GATE_EVENT, load_host.gate.status());
                }
                PageLoadEvent::Finished if is_app => {
                    start_probe(&load_handle, &load_host, webview.label());
                }
                _ => {}
            }
        })
        .build()?;
    host.panes.set_app_dirs(app_owned_dirs(&handle));
    let builtin_root = super::catalog::Catalog::locate_builtin_root(handle.path().resource_dir().ok());
    let _ = host.catalog.set(super::catalog::Catalog::new(builtin_root, crate::agmsg::base_dir().join("addons")));
    // Measure git once at startup, off this thread: git:read is off, with the reason, when it fails.
    std::thread::spawn(|| match super::broker::prepare_git() {
        None => eprintln!("[addons] git:read is available"),
        Some(why) => eprintln!("[addons] git:read is off: {why}"),
    });
    {
        let list: Vec<String> = host.catalog().list().iter().map(|a| format!("{}({})", a.id, if a.digest_ok { "ok" } else { "CHANGED" })).collect();
        eprintln!("[addons] add-ons: {}", if list.is_empty() { "none".to_string() } else { list.join(" ") });
    }
    // One line at startup naming the agmsg base and every store this app resolved,
    // so a tester can see that nothing outside the folder they pointed it at is in play.
    std::thread::spawn(|| {
        let places: Vec<String> = crate::agmsg::protected_locations().iter().map(|p| p.display().to_string()).collect();
        eprintln!("[agmsg-app] resolved: {}", places.join(" | "));
    });
    *host.engine.lock().unwrap() = engine::harden(&window);
    super::commands::listen_for_live_messages(&handle, host.clone());
    Ok(())
}

/// The app's own bundle, data, config, cache and log folders, and the folder the
/// executable lives in: never readable by an add-on, whatever folder is granted.
fn app_owned_dirs<R: Runtime>(app: &AppHandle<R>) -> Vec<std::path::PathBuf> {
    let p = app.path();
    let mut v: Vec<std::path::PathBuf> = [p.app_data_dir(), p.app_config_dir(), p.app_local_data_dir(), p.app_cache_dir(), p.app_log_dir(), p.resource_dir()]
        .into_iter()
        .filter_map(Result::ok)
        .collect();
    if let Some(dir) = std::env::current_exe().ok().and_then(|e| e.parent().map(|d| d.to_path_buf())) {
        v.push(dir);
    }
    v.sort();
    v.dedup();
    v
}

/// Scheme, host and port only: a URL in a log line must not carry a query.
fn redact(u: &Url) -> String {
    format!("{}://{}{}", u.scheme(), u.host_str().unwrap_or(""), u.port().map(|p| format!(":{p}")).unwrap_or_default())
}

fn nonce() -> String {
    let mut b = [0u8; 16];
    getrandom::getrandom(&mut b).expect("the OS random source is unavailable");
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Starts the app-owned probe frame in the main page. Add-ons stay off unless
/// the frame answers, correctly, before the deadline.
fn start_probe<R: Runtime>(app: &AppHandle<R>, host: &Arc<AddonHost>, label: &str) {
    host.end_probe();
    let Some(window) = app.get_webview_window(label) else { return };
    let mut files = HashMap::new();
    files.insert("index.html".to_string(), include_bytes!("probe/index.html").to_vec());
    files.insert("probe.js".to_string(), include_bytes!("probe/probe.js").to_vec());
    files.insert("control.html".to_string(), include_bytes!("probe/control.html").to_vec());
    files.insert("control.js".to_string(), include_bytes!("probe/control.js").to_vec());
    let server = match PaneServer::start(PaneSpec { payload: Payload::Embedded(files), entry: "index.html".into(), network: Network::None, expected_digest: None, pinned: None, on_tamper: None }) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[addons] cannot start the probe server: {e}");
            return;
        }
    };
    let udp = match UdpSocket::bind("127.0.0.1:0") {
        Ok(u) => u,
        Err(e) => {
            eprintln!("[addons] cannot open the probe's UDP sentinel: {e}");
            return;
        }
    };
    let udp_port = udp.local_addr().map(|a| a.port()).unwrap_or(0);
    let udp_hits = Arc::new(AtomicUsize::new(0));
    let udp_stop = Arc::new(AtomicBool::new(false));
    {
        let (hits, stop) = (udp_hits.clone(), udp_stop.clone());
        std::thread::spawn(move || {
            let mut buf = [0u8; 2048];
            while let Ok((n, _)) = udp.recv_from(&mut buf) {
                if stop.load(Ordering::SeqCst) {
                    break;
                }
                if n > 0 {
                    hits.fetch_add(1, Ordering::SeqCst);
                }
            }
        });
    }
    let n = nonce();
    host.nav.register_pane(server.port(), server.token());
    let url = server.url();
    // The forbidden navigation: the app origin (unique per probe so a violation can be tied to it).
    let target = format!("{}/__agmsg_probe_nav__/{n}", app_origin(&window));
    #[cfg(debug_assertions)]
    let target = std::env::var("AGMSG_PROBE_TEST_TARGET").unwrap_or(target); // negative controls only; absent in release
    let hash = serde_json::json!({ "nonce": n, "udp": udp_port, "target": target }).to_string();
    let src = format!("{url}#{}", percent_encode(&hash));
    host.gate.begin(&n, &target, Instant::now());
    *host.probe.lock().unwrap() = Some(ProbeRun { nonce: n.clone(), server, udp_hits, udp_stop, udp_port });

    // The only code the app runs in the main page for this: relay the probe
    // frame's postMessage to the command, and create the frame.
    let js = format!(
        r#"(function () {{
  if (!window.__agmsgProbeRelay) {{
    window.__agmsgProbeRelay = true;
    window.__agmsgViolations = [];
    // The refusal has to be seen here, in the embedding page: an enforced CSP
    // violation, with the blocked URI and the directive.
    document.addEventListener('securitypolicyviolation', function (e) {{
      if (e.disposition === 'enforce') window.__agmsgViolations.push([e.effectiveDirective, e.blockedURI]);
    }});
    window.addEventListener('message', function (ev) {{
      var f = document.getElementById('agmsg-probe-frame');
      if (!f || ev.source !== f.contentWindow) return;
      var d = ev.data;
      if (!d || d.agmsgProbe !== 1) return;
      f.remove();
      var rep = d.report || {{}};
      var target = {target:?};
      var hit = window.__agmsgViolations.filter(function (v) {{ return (v[0] === 'frame-src' || v[0] === 'child-src') && v[1] === target; }})[0];
      rep.navViolationDirective = hit ? hit[0] : '';
      rep.navViolationUri = hit ? hit[1] : '';
      window.__TAURI_INTERNALS__.invoke('addon_probe_report', {{ report: rep }}).catch(function () {{}});
    }});
  }}
  var old = document.getElementById('agmsg-probe-frame');
  if (old) old.remove();
  var f = document.createElement('iframe');
  f.id = 'agmsg-probe-frame';
  f.setAttribute('sandbox', 'allow-scripts');
  f.setAttribute('aria-hidden', 'true');
  f.style.cssText = 'position:fixed;left:0;top:0;width:2px;height:2px;border:0;opacity:0;pointer-events:none';
  f.src = {src:?};
  document.body.appendChild(f);
}})();"#
    );
    if window.eval(&js).is_err() {
        host.end_probe();
        return;
    }

    // Deadline: no answer means off.
    let (app2, host2) = (app.clone(), host.clone());
    let generation = host.gate.generation();
    std::thread::spawn(move || {
        std::thread::sleep(PROBE_TIMEOUT + Duration::from_millis(500));
        if host2.gate.generation() == generation && host2.gate.expire(Instant::now()) {
            host2.end_probe();
            let v = host2.gate.status();
            eprintln!("[addons] startup check: enabled={} {}", v.enabled, v.reasons.join("; "));
            let _ = app2.emit(GATE_EVENT, v);
        }
    });
}

fn app_origin<R: Runtime>(window: &tauri::WebviewWindow<R>) -> String {
    match window.url() {
        Ok(u) => format!("{}://{}{}", u.scheme(), u.host_str().unwrap_or("localhost"), u.port().map(|p| format!(":{p}")).unwrap_or_default()),
        Err(_) => "tauri://localhost".into(),
    }
}

fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Relayed by the main UI from the probe frame. Only the main UI can call this
/// (ACL); the nonce ties the answer to the probe that was started.
#[tauri::command]
pub fn addon_probe_report<R: Runtime>(app: AppHandle<R>, host: tauri::State<'_, Arc<AddonHost>>, report: ProbeReport) -> Verdict {
    let (udp_hits, expected) = {
        let p = host.probe.lock().unwrap();
        match p.as_ref() {
            Some(run) => (run.udp_hits.load(Ordering::SeqCst), run.nonce.clone()),
            None => (0, String::new()),
        }
    };
    let engine = host.engine.lock().unwrap().clone();
    let verdict = host.gate.report(&report, &engine, udp_hits, Os::host(), Instant::now());
    // The probe is over once its nonce was answered (right or wrong verdict);
    // a stray answer with another nonce leaves it running.
    if !expected.is_empty() && report.nonce == expected {
        host.end_probe();
    }
    eprintln!("[addons] startup check: enabled={} {}", verdict.enabled, verdict.reasons.join("; "));
    let _ = app.emit(GATE_EVENT, verdict.clone());
    verdict
}

/// Current verdict for the UI (the engine-off screen reads `reasons`).
#[tauri::command]
pub fn addon_gate_status(host: tauri::State<'_, Arc<AddonHost>>) -> Verdict {
    host.gate.status()
}
