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
            let mut s = s;
            if let Some(r) = read_req(&mut s) {
                log(&format!(
                    "SENTINEL {name} port={port} {} {} origin={:?} referer={:?} host={:?}",
                    r.method,
                    r.path,
                    r.headers.get("origin"),
                    r.headers.get("referer"),
                    r.headers.get("host")
                ));
                respond(
                    &mut s,
                    "200 OK",
                    &[
                        ("Access-Control-Allow-Origin", "*".into()),
                        ("Access-Control-Allow-Headers", "*".into()),
                        ("Content-Type", "text/plain".into()),
                    ],
                    b"sentinel",
                    r.method == "HEAD",
                );
            }
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
            let mut s = s;
            if let Some(r) = read_req(&mut s) {
                let p = r.path.replace('+', " ");
                log(&format!("REPORT {}", percent_decode(&p)));
                respond(&mut s, "200 OK", &[("Access-Control-Allow-Origin", "*".into()), ("Content-Type", "text/plain".into())], b"ok", false);
            }
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
            let mut s = s;
            let Some(r) = read_req(&mut s) else { continue };
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
                    match std::fs::read(&file) {
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
            log(&format!("PANE {} {} -> {}", r.method, r.path, status));
            let mut hs: Vec<(&str, String)> = vec![
                ("Content-Type", ct.into()),
                ("Access-Control-Allow-Origin", "*".into()),
                ("Referrer-Policy", "no-referrer".into()),
                ("Cache-Control", "no-store".into()),
                ("X-Content-Type-Options", "nosniff".into()),
            ];
            if let Some(csp) = &cfg.csp {
                let csp = csp.replace("<own>", &format!("http://127.0.0.1:{port}"));
                hs.push(("Content-Security-Policy", csp));
            }
            respond(&mut s, status, &hs, &body, head_only);
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
    let s1 = spawn_sentinel("S1");
    let s2 = spawn_sentinel("S2");
    let token: String = (0..16).map(|_| format!("{:02x}", rand_byte())).collect();
    let root = std::path::PathBuf::from(std::env::var("M1_PAYLOAD").unwrap_or_else(|_| "m1/payload".into()));
    let csp = std::env::var("M1_CSP").ok().filter(|s| !s.is_empty());
    let ports = Arc::new(Mutex::new(vec![]));
    let pane = spawn_pane(PaneCfg { token: token.clone(), csp: csp.clone(), root: root.clone(), ports });
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
  const cfg = {{ pane: {pane}, token: "{token}", report: {report}, s1: {s1}, s2: {s2}, entry: "{entry}", variant: "{variant}" }};
  window.__m1cfg = cfg;
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
