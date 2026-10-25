//! M1 spike: measurement harness for add-on panes. Not production code.
//!
//! Enabled by `M1_SPIKE=1`. Starts a pane server, a report sink and sentinel
//! servers on loopback, then injects an `<iframe sandbox="allow-scripts">`
//! pointing at the pane server into the main window. Every hit on a sentinel
//! and every entry into `addon_canary` is appended to `$M1_LOG`.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use tauri::{AppHandle, Manager};
use tauri::webview::NewWindowResponse;
use std::sync::OnceLock;

/// (port, token) of the live pane; the navigation handler allows only this.
static REPORT_PORT: std::sync::atomic::AtomicU16 = std::sync::atomic::AtomicU16::new(0);
static LIVE_PANE: OnceLock<Mutex<Option<(u16, String)>>> = OnceLock::new();
fn live() -> &'static Mutex<Option<(u16, String)>> {
    LIVE_PANE.get_or_init(|| Mutex::new(None))
}

fn nav_allowed(url: &tauri::Url) -> bool {
    let s = url.as_str();
    let app = matches!(url.scheme(), "tauri") || s.starts_with("http://tauri.localhost") || s.starts_with("https://tauri.localhost");
    let pane = live().lock().unwrap().as_ref().map(|(p, t)| s.starts_with(&format!("http://127.0.0.1:{p}/{t}/"))).unwrap_or(false);
    app || pane
}

/// Main window built here (tauri.conf has create=false) so native handlers can be attached.
pub fn create_main_window(app: &AppHandle) -> tauri::Result<()> {
    let cfg = app.config().app.windows[0].clone();
    let spike = std::env::var("M1_SPIKE").ok().as_deref() == Some("1");
    let mut b = tauri::WebviewWindowBuilder::from_config(app, &cfg)?;
    #[cfg(windows)]
    if let Ok(a) = std::env::var("M1_WV2_ARGS") {
        b = b.additional_browser_args(&a);
    }
    if spike {
        let enforce = std::env::var("M1_NAV").ok().as_deref() != Some("off");
        b = b
            .on_navigation(move |url| {
                let ok = nav_allowed(url);
                log(&format!("NAV {} -> {}", url, if ok || !enforce { "allow" } else { "CANCEL" }));
                ok || !enforce
            })
            .on_new_window(|url, _f| {
                log(&format!("NEWWINDOW {url} -> deny"));
                NewWindowResponse::Deny
            })
            .on_download(|_w, ev| {
                log(&format!("DOWNLOAD {:?} -> deny", std::mem::discriminant(&ev)));
                false
            });
    }
    let _w = b.build()?;
    #[cfg(windows)]
    if spike && std::env::var("M1_FRAME_GUARD").ok().as_deref() == Some("1") {
        frame_guard::install(&_w);
    }
    Ok(())
}

/// Windows only: cancel a pane frame's navigation unless it stays inside the origin of the live pane.
#[cfg(windows)]
mod frame_guard {
    use super::{live, log};
    use std::sync::{Arc, Mutex};
    use tauri::Url;
    use webview2_com::Microsoft::Web::WebView2::Win32::{ICoreWebView2Frame, ICoreWebView2Frame2, ICoreWebView2_4};
    use webview2_com::{take_pwstr, FrameCreatedEventHandler, FrameNavigationStartingEventHandler};
    use windows::core::{Interface, PWSTR};

    fn origin(u: &Url) -> Option<(String, String, Option<u16>)> {
        Some((u.scheme().to_string(), u.host_str()?.to_ascii_lowercase(), u.port()))
    }

    fn guard(frame: &ICoreWebView2Frame) {
        let own: Arc<Mutex<Option<(String, String, Option<u16>)>>> = Arc::new(Mutex::new(None));
        let Ok(f2) = frame.cast::<ICoreWebView2Frame2>() else {
            log("FRAMEGUARD frame has no NavigationStarting");
            return;
        };
        let h = FrameNavigationStartingEventHandler::create(Box::new(move |_f, args| {
            let Some(args) = args else { return Ok(()) };
            let mut raw = PWSTR::null();
            unsafe { args.Uri(&mut raw)? };
            let uri = take_pwstr(raw);
            let mut allow = false;
            if let Ok(url) = Url::parse(&uri) {
                let pane = live().lock().unwrap().as_ref().map(|(p, t)| url.as_str().starts_with(&format!("http://127.0.0.1:{p}/{t}/"))).unwrap_or(false);
                let o = origin(&url);
                let mut g = own.lock().unwrap();
                allow = match (g.as_ref(), pane) {
                    (None, true) => { *g = o; true }
                    (Some(prev), _) => Some(prev) == o.as_ref() && pane,
                    _ => false,
                };
            }
            log(&format!("FRAMENAV {uri} -> {}", if allow { "allow" } else { "CANCEL" }));
            if !allow {
                unsafe { args.SetCancel(true)? };
            }
            Ok(())
        }));
        let mut t = 0i64;
        let _ = unsafe { f2.add_NavigationStarting(&h, &mut t) };
    }

    pub fn install(w: &tauri::WebviewWindow) {
        let r = w.with_webview(|wv| unsafe {
            let Ok(core) = wv.controller().CoreWebView2() else { return log("FRAMEGUARD no core") };
            let Ok(c4) = core.cast::<ICoreWebView2_4>() else { return log("FRAMEGUARD no FrameCreated") };
            let h = FrameCreatedEventHandler::create(Box::new(|_c, args| {
                if let Some(f) = args.and_then(|a| a.Frame().ok()) {
                    guard(&f);
                }
                Ok(())
            }));
            let mut t = 0i64;
            match c4.add_FrameCreated(&h, &mut t) {
                Ok(()) => log("FRAMEGUARD installed"),
                Err(e) => log(&format!("FRAMEGUARD failed {e}")),
            }
        });
        if let Err(e) = r {
            log(&format!("FRAMEGUARD with_webview failed {e}"));
        }
    }
}

pub fn log(line: &str) {
    let ts = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
    let msg = format!("{ts} {line}\n");
    eprint!("[m1] {msg}");
    if let Ok(path) = std::env::var("M1_LOG") {
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = f.write_all(msg.as_bytes());
        }
    }
}

#[tauri::command]
pub fn addon_canary(arg: Option<String>) -> String {
    log(&format!("CANARY ENTERED arg={:?}", arg));
    "canary-ok".to_string()
}

/// Streams 4 KB binary chunks over a Channel for ~12 s, so the Tauri channel-data queue
/// (`plugin:__TAURI_CHANNEL__|fetch`) holds live entries while an add-on frame polls it.
#[tauri::command]
pub async fn addon_channel_feed(on_event: tauri::ipc::Channel<tauri::ipc::InvokeResponseBody>) -> Result<(), String> {
    log("CHANNEL FEED started");
    for i in 0..60u32 {
        let mut b = vec![0x41u8; 4096];
        b[..4].copy_from_slice(&i.to_be_bytes());
        let _ = on_event.send(tauri::ipc::InvokeResponseBody::Raw(b));
        tokio_sleep().await;
    }
    Ok(())
}
async fn tokio_sleep() { tauri::async_runtime::spawn_blocking(|| std::thread::sleep(std::time::Duration::from_millis(200))).await.ok(); }

struct Req {
    method: String,
    path: String,
    headers: HashMap<String, String>,
}

fn read_req(s: &mut TcpStream) -> Option<Req> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    loop {
        let n = s.read(&mut tmp).ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&tmp[..n]);
        if buf.windows(4).any(|w| w == b"\r\n\r\n") || buf.len() > 65536 {
            break;
        }
    }
    let text = String::from_utf8_lossy(&buf).to_string();
    let mut lines = text.split("\r\n");
    let first = lines.next()?;
    let mut parts = first.split(' ');
    let method = parts.next()?.to_string();
    let path = parts.next()?.to_string();
    let mut headers = HashMap::new();
    for l in lines {
        if l.is_empty() {
            break;
        }
        if let Some((k, v)) = l.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    Some(Req { method, path, headers })
}

fn respond(s: &mut TcpStream, status: &str, headers: &[(&str, String)], body: &[u8], head_only: bool) {
    let mut out = format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n", body.len());
    for (k, v) in headers {
        out.push_str(&format!("{k}: {v}\r\n"));
    }
    out.push_str("\r\n");
    let _ = s.write_all(out.as_bytes());
    if !head_only {
        let _ = s.write_all(body);
    }
}

/// Sentinel: logs every hit, answers 200 with ACAO * so a fetch() "succeeds".
fn spawn_sentinel(name: &'static str) -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for s in l.incoming().flatten() {
            std::thread::spawn(move || {
            let mut s = s;
            let _ = s.set_read_timeout(Some(std::time::Duration::from_secs(5)));
            if let Some(r) = read_req(&mut s) {
                log(&format!(
                    "SENTINEL {name} port={port} {} {} origin={:?} referer={:?} host={:?}",
                    r.method,
                    r.path,
                    r.headers.get("origin"),
                    r.headers.get("referer"),
                    r.headers.get("host")
                ));
                if r.path.starts_with("/redir") {
                    let to = r.path.split("to=").nth(1).unwrap_or("").to_string();
                    let loc = percent_decode(&to);
                    respond(&mut s, "302 Found", &[("Location", loc), ("Access-Control-Allow-Origin", "*".into())], b"", false);
                    return;
                }
                let is_js = r.path.split('?').next().unwrap_or("").ends_with(".js");
                let rp = REPORT_PORT.load(std::sync::atomic::Ordering::Relaxed);
                let body = if is_js {
                    format!("(new Image).src='http://127.0.0.1:{rp}/r?RAN_remote_script_from_{name}=1';")
                } else {
                    "sentinel".to_string()
                };
                respond(
                    &mut s,
                    "200 OK",
                    &[
                        ("Access-Control-Allow-Origin", "*".into()),
                        ("Access-Control-Allow-Headers", "*".into()),
                        ("Content-Type", if is_js { "text/javascript" } else { "text/plain" }.into()),
                    ],
                    body.as_bytes(),
                    r.method == "HEAD",
                );
            }
            });
        }
    });
    port
}

/// Report sink: the frame reports results with `new Image().src = ".../r?k=v"`.
fn spawn_report() -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for s in l.incoming().flatten() {
            std::thread::spawn(move || {
            let mut s = s;
            let _ = s.set_read_timeout(Some(std::time::Duration::from_secs(5)));
            if let Some(r) = read_req(&mut s) {
                let p = r.path.replace('+', " ");
                log(&format!("REPORT {}", percent_decode(&p)));
                respond(&mut s, "200 OK", &[("Access-Control-Allow-Origin", "*".into()), ("Content-Type", "text/plain".into())], b"ok", false);
            }
            });
        }
    });
    port
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() + 0 && i + 2 <= b.len() - 1 {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

#[derive(Clone)]
pub struct PaneCfg {
    pub token: String,
    pub csp: Option<String>,
    pub root: std::path::PathBuf,
    pub ports: Arc<Mutex<Vec<u16>>>,
    pub net: Arc<Mutex<String>>,
}

fn mime(path: &str) -> &'static str {
    match path.rsplit('.').next().unwrap_or("") {
        "html" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css",
        "json" => "application/json",
        "wasm" => "application/wasm",
        "png" => "image/png",
        "woff2" => "font/woff2",
        "txt" | "svg" => "text/plain",
        _ => "application/octet-stream",
    }
}

/// Per-pane server per design 4.1/4.4: token path, Host check, GET/HEAD only,
/// no listing/redirect, ACAO *, no-referrer, no-store, CSP header.
pub fn spawn_pane(cfg: PaneCfg) -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for s in l.incoming().flatten() {
            let cfg = cfg.clone();
            std::thread::spawn(move || {
            let mut s = s;
            let _ = s.set_read_timeout(Some(std::time::Duration::from_secs(5)));
            let Some(r) = read_req(&mut s) else { return };
            let head_only = r.method == "HEAD";
            let host_ok = r.headers.get("host").map(|h| h == &format!("127.0.0.1:{port}")).unwrap_or(false);
            let path_only = r.path.split('?').next().unwrap_or("").to_string();
            let status;
            let mut body: Vec<u8> = Vec::new();
            let mut ct = "text/plain";
            if r.method != "GET" && r.method != "HEAD" {
                status = "405 Method Not Allowed";
            } else if !host_ok {
                status = "421 Misdirected Request";
            } else if let Some(rest) = path_only.strip_prefix(&format!("/{}/", cfg.token)) {
                // refuse any traversal-ish spelling outright; D-cases measure this
                let dec = percent_decode(rest);
                if dec.contains("..") || dec.contains('\\') || dec.starts_with('/') || dec.contains(':') || dec.contains('\0') {
                    status = "400 Bad Request";
                } else {
                    let file = cfg.root.join(if dec.is_empty() { "index.html" } else { &dec });
                    // pinned-directory rule: every component must be a plain file/dir (no symlinks) and the
                    // real path must stay under the real root
                    let mut plain = true;
                    let mut cur = cfg.root.clone();
                    for comp in std::path::Path::new(if dec.is_empty() { "index.html" } else { &dec }).components() {
                        cur.push(comp);
                        match std::fs::symlink_metadata(&cur) {
                            Ok(m) if m.file_type().is_symlink() => { plain = false; break; }
                            Ok(_) => {}
                            Err(_) => { plain = false; break; }
                        }
                    }
                    let under = match (std::fs::canonicalize(&file), std::fs::canonicalize(&cfg.root)) {
                        (Ok(f), Ok(r)) => f.starts_with(r),
                        _ => false,
                    };
                    let read = if plain && under && file.is_file() { std::fs::read(&file) } else { Err(std::io::Error::from(std::io::ErrorKind::NotFound)) };
                    match read {
                        Ok(b) => {
                            status = "200 OK";
                            body = b;
                            ct = mime(&dec);
                        }
                        Err(_) => status = "404 Not Found",
                    }
                }
            } else {
                status = "404 Not Found";
            }
            log(&format!("PANE {} {} -> {}", r.method, path_only, status));
            let mut hs: Vec<(&str, String)> = vec![
                ("Content-Type", ct.into()),
                ("Access-Control-Allow-Origin", "*".into()),
                ("Referrer-Policy", "no-referrer".into()),
                ("Cache-Control", "no-store".into()),
                ("X-Content-Type-Options", "nosniff".into()),
            ];
            if let Some(csp) = &cfg.csp {
                let net = cfg.net.lock().unwrap().clone();
                let csp = csp.replace("<own>", &format!("http://127.0.0.1:{port}")).replace("<net>", &net);
                hs.push(("Content-Security-Policy", csp));
            }
            respond(&mut s, status, &hs, &body, head_only);
            });
        }
    });
    let _ = &port;
    port
}

pub fn start(app: &AppHandle) {
    if std::env::var("M1_SPIKE").ok().as_deref() != Some("1") {
        return;
    }
    let variant = env!("M1_VARIANT");
    let report = spawn_report();
    REPORT_PORT.store(report, std::sync::atomic::Ordering::Relaxed);
    let s1 = spawn_sentinel("S1");
    let s2 = spawn_sentinel("S2");
    let udp = spawn_udp();
    let lan = spawn_lan();
    let lan_js = lan.map(|x| format!("\"{x}\"")).unwrap_or_else(|| "null".into());
    let token: String = (0..16).map(|_| format!("{:02x}", rand_byte())).collect();
    let root = std::path::PathBuf::from(std::env::var("M1_PAYLOAD").unwrap_or_else(|_| "m1/payload".into()));
    let csp = std::env::var("M1_CSP").ok().filter(|s| !s.is_empty());
    let ports = Arc::new(Mutex::new(vec![]));
    let net = Arc::new(Mutex::new(String::new()));
    let pane = spawn_pane(PaneCfg { token: token.clone(), csp: csp.clone(), root: root.clone(), ports, net: net.clone() });
    *live().lock().unwrap() = Some((pane, token.clone()));
    if std::env::var("M1_NET").ok().as_deref() == Some("1") {
        *net.lock().unwrap() = format!("http://127.0.0.1:{s2} http://127.0.0.1:{report}");
    } else {
        *net.lock().unwrap() = format!("http://127.0.0.1:{report}");
    }
    if let Ok(root2) = std::env::var("M1_PAYLOAD2") {
        let token2: String = (0..16).map(|_| format!("{:02x}", rand_byte())).collect();
        let pane2 = spawn_pane(PaneCfg { token: token2.clone(), csp: None, root: std::path::PathBuf::from(root2), ports: Arc::new(Mutex::new(vec![])), net: Arc::new(Mutex::new(String::new())) });
        log(&format!("PANE2 port={pane2} token={token2}"));
    }
    log(&format!("PANE1 port={pane} token={token}"));
    let entry = std::env::var("M1_ENTRY").unwrap_or_else(|_| "index.html".into());
    log(&format!(
        "START variant={variant} debug={} pane={pane} report={report} s1={s1} s2={s2} csp={:?} root={:?} entry={entry}",
        cfg!(debug_assertions),
        csp,
        root
    ));
    let nokey = std::env::var("M1_NOKEY").ok().as_deref() == Some("1");
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_secs(4));
        let Some(w) = app.get_webview_window("main") else { return };
        let js = format!(
            r#"(async () => {{
  const cfg = {{ udp: {udp}, lan: {lan_js}, pane: {pane}, token: "{token}", report: {report}, s1: {s1}, s2: {s2}, entry: "{entry}", variant: "{variant}" }};
  window.__m1cfg = cfg;
  setInterval(() => {{ new Image().src = 'http://127.0.0.1:' + cfg.report + '/r?mainhb=' + (document.visibilityState); }}, 2000);
  // Capture the real invoke key from one genuine invoke by the main UI.
  let key = null;
  const of = window.fetch;
  window.fetch = function (u, o) {{
    try {{ const h = new Headers((o && o.headers) || {{}}); if (h.get('Tauri-Invoke-Key')) key = h.get('Tauri-Invoke-Key'); }} catch (e) {{}}
    return of.apply(this, arguments);
  }};
  const oi = window.ipc && window.ipc.postMessage;
  if (oi) window.ipc.postMessage = function (d) {{ try {{ const m = JSON.parse(d); if (m.__TAURI_INVOKE_KEY__) key = m.__TAURI_INVOKE_KEY__; }} catch (e) {{}} return oi.apply(this, arguments); }};
  try {{ await window.__TAURI_INTERNALS__.invoke('agmsg_is_installed'); }} catch (e) {{}}
  try {{ const r = await window.__TAURI_INTERNALS__.invoke('addon_canary', {{ arg: 'from-main-ui' }}); new Image().src = 'http://127.0.0.1:' + cfg.report + '/r?main_canary=' + encodeURIComponent(String(r)); }} catch (e) {{ new Image().src = 'http://127.0.0.1:' + cfg.report + '/r?main_canary_err=' + encodeURIComponent(String(e)); }}
  try {{ const cb = window.__TAURI_INTERNALS__.transformCallback(() => {{}}); window.__TAURI_INTERNALS__.invoke('addon_channel_feed', {{ onEvent: '__CHANNEL__:' + cb }}); }} catch (e) {{}}
  const f = document.createElement('iframe');
  f.setAttribute('sandbox', 'allow-scripts');
  f.style.cssText = 'position:fixed;right:0;bottom:0;width:480px;height:320px;z-index:99999;background:#fff;border:2px solid red';
  f.src = 'http://127.0.0.1:' + cfg.pane + '/' + cfg.token + '/' + cfg.entry;
  f.addEventListener('load', () => {{
    f.contentWindow.postMessage({{ m1: 'cfg', cfg, key: {nokey} ? null : key }}, '*');
  }});
  document.body.appendChild(f);
  window.__m1frame = f;
}})();"#
        );
        #[cfg(target_os = "macos")]
        {
            // M1 harness only: the screen may be locked, which makes WebKit treat every page as hidden
            // and suspend it. Turn off visibility-based suppression so measurements can run.
            let _ = w.with_webview(|wv| unsafe {
                use objc2::runtime::AnyObject;
                use objc2::{msg_send, sel};
                let view = wv.inner() as *mut AnyObject;
                let conf: *mut AnyObject = msg_send![view, configuration];
                let prefs: *mut AnyObject = msg_send![conf, preferences];
                let r: bool = msg_send![prefs, respondsToSelector: sel!(_setPageVisibilityBasedProcessSuppressionEnabled:)];
                if r { let _: () = msg_send![prefs, _setPageVisibilityBasedProcessSuppressionEnabled: false]; }
                let r2: bool = msg_send![view, respondsToSelector: sel!(_setWindowOcclusionDetectionEnabled:)];
                if r2 { let _: () = msg_send![view, _setWindowOcclusionDetectionEnabled: false]; }
                {
                    use objc2::runtime::{AnyClass, Sel};
                    let cls: &AnyClass = (*prefs).class();
                    let mut names = vec![];
                    for m in cls.instance_methods().iter() {
                        let n = m.name().name().to_string_lossy().to_string();
                        if n.to_lowercase().contains("peer") || n.to_lowercase().contains("webrtc") || n.to_lowercase().contains("mediadevices") || n.to_lowercase().contains("ice") && n.starts_with("_") { names.push(n); }
                    }
                    log(&format!("WK prefs webrtc-ish selectors: {:?}", names));
                    let _ = Sel::register(c"_x");
                }
                if std::env::var("M1_NO_WEBRTC").ok().as_deref() == Some("1") {
                    let _: () = msg_send![prefs, _setPeerConnectionEnabled: false];
                    let now: bool = msg_send![prefs, _peerConnectionEnabled];
                    log(&format!("WK _setPeerConnectionEnabled(false) -> _peerConnectionEnabled={now}"));
                }
                log(&format!("WK visibility SPI: suppression_pref={r} occlusion_detection={r2}"));
            });
        }
        let _ = w.show();
        let _ = w.set_always_on_top(true);
        let _ = w.set_focus();
        let _ = w.eval(&js);
    });
}

fn rand_byte() -> u8 {
    use std::io::Read;
    let mut b = [0u8; 1];
    if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
        let _ = f.read_exact(&mut b);
    } else {
        b[0] = (SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(7) & 0xff) as u8;
    }
    b[0]
}

fn spawn_udp() -> u16 {
    let sock = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let port = sock.local_addr().unwrap().port();
    std::thread::spawn(move || {
        let mut b = [0u8; 2048];
        while let Ok((n, from)) = sock.recv_from(&mut b) {
            log(&format!("SENTINEL UDP(stun) port={port} {n} bytes from {from}"));
        }
    });
    port
}

/// Sentinel bound on all interfaces, reached through the machine's LAN address.
fn spawn_lan() -> Option<String> {
    let ip = std::env::var("M1_LAN_IP").ok().or_else(|| std::process::Command::new("ipconfig").args(["getifaddr", "en0"]).output().ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).filter(|s| !s.is_empty())).filter(|s| !s.is_empty())?;
    let l = TcpListener::bind("0.0.0.0:0").ok()?;
    let port = l.local_addr().ok()?.port();
    std::thread::spawn(move || {
        for s in l.incoming().flatten() {
            std::thread::spawn(move || {
            let mut s = s;
            let _ = s.set_read_timeout(Some(std::time::Duration::from_secs(5)));
            if let Some(r) = read_req(&mut s) {
                log(&format!("SENTINEL LAN port={port} {} {} origin={:?}", r.method, r.path, r.headers.get("origin")));
                respond(&mut s, "200 OK", &[("Access-Control-Allow-Origin", "*".into())], b"lan", r.method == "HEAD");
            }
            });
        }
    });
    Some(format!("{ip}:{port}"))
}
