//! The per-pane loopback HTTP server (design 4.1).
//!
//! One listener per open add-on pane, bound to `127.0.0.1` on a random port,
//! with a 128-bit random token in the path. The token maps to exactly one
//! immutable payload; nothing else is served: no listing, no redirects, GET and
//! HEAD only, the query string is ignored and never logged, and the `Host`
//! header must be exactly `127.0.0.1:<port>` (DNS rebinding). Every response
//! carries the pane's CSP, `Referrer-Policy: no-referrer` and
//! `Cache-Control: no-store`; payload responses carry `Access-Control-Allow-Origin: *`
//! (no credentials) because an opaque-origin frame fetching its own files is
//! cross-origin. When the server is stopped the listener and the token are gone.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;

use super::csp::{self, Network, PaneCsp};
use super::digest;

const MAX_HEAD: usize = 16 * 1024;
const MAX_FILE: u64 = 50 * 1024 * 1024;
const MAX_CONNECTIONS: usize = 64;
const IO_TIMEOUT: Duration = Duration::from_secs(5);

pub enum Payload {
    /// A directory on disk (an installed add-on or a developer copy).
    Dir(PathBuf),
    /// Files held in memory (the app's own probe page, built-in add-ons).
    Embedded(HashMap<String, Vec<u8>>),
}

pub struct PaneSpec {
    pub payload: Payload,
    /// Path of the entry file inside the payload, e.g. `index.html`.
    pub entry: String,
    pub network: Network,
    /// When set, the payload directory must hash to this value to start.
    pub expected_digest: Option<String>,
}

#[derive(Debug)]
pub enum StartError {
    Io(std::io::Error),
    DigestMismatch,
    Digest(String),
    /// The entry file is missing or not a plain file.
    NoEntry(String),
}

impl std::fmt::Display for StartError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StartError::Io(e) => write!(f, "{e}"),
            StartError::DigestMismatch => f.write_str("the add-on's files are incomplete or were changed after install"),
            StartError::Digest(e) => write!(f, "cannot hash the add-on's files: {e}"),
            StartError::NoEntry(e) => write!(f, "entry file {e} is missing"),
        }
    }
}

impl From<std::io::Error> for StartError {
    fn from(e: std::io::Error) -> Self {
        StartError::Io(e)
    }
}

/// Everything a request needs; shared by the accept loop and the tests.
struct Ctx {
    port: u16,
    token: String,
    payload: Payload,
    /// Canonical root for `Payload::Dir`.
    root: Option<PathBuf>,
    entry: String,
    csp: String,
}

pub struct PaneServer {
    port: u16,
    token: String,
    csp: String,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl PaneServer {
    pub fn start(spec: PaneSpec) -> Result<PaneServer, StartError> {
        let (root, hashes) = match &spec.payload {
            Payload::Dir(dir) => {
                if let Some(expected) = &spec.expected_digest {
                    let actual = digest::payload_digest(dir).map_err(|e| StartError::Digest(e.to_string()))?;
                    if &actual != expected {
                        return Err(StartError::DigestMismatch);
                    }
                }
                let canon = std::fs::canonicalize(dir)?;
                let entry_path = canon.join(&spec.entry);
                match std::fs::symlink_metadata(&entry_path) {
                    Ok(m) if m.is_file() => {}
                    _ => return Err(StartError::NoEntry(spec.entry.clone())),
                }
                let mut hashes = Vec::new();
                collect_html_hashes(&canon, &mut hashes);
                (Some(canon), hashes)
            }
            Payload::Embedded(files) => {
                if !files.contains_key(&spec.entry) {
                    return Err(StartError::NoEntry(spec.entry.clone()));
                }
                let mut hashes = Vec::new();
                for (name, bytes) in files {
                    if name.ends_with(".html") {
                        for h in csp::inline_script_hashes(&String::from_utf8_lossy(bytes)) {
                            if !hashes.contains(&h) {
                                hashes.push(h);
                            }
                        }
                    }
                }
                (None, hashes)
            }
        };

        let listener = TcpListener::bind(SocketAddr::from((Ipv4Addr::LOCALHOST, 0)))?;
        let port = listener.local_addr()?.port();
        let token = new_token();
        let own = format!("http://127.0.0.1:{port}");
        let csp = csp::build(&PaneCsp { own: &own, network: &spec.network, script_hashes: &hashes });
        let ctx = Arc::new(Ctx { port, token: token.clone(), payload: spec.payload, root, entry: spec.entry, csp: csp.clone() });

        let stop = Arc::new(AtomicBool::new(false));
        let active = Arc::new(AtomicUsize::new(0));
        let thread = {
            let stop = stop.clone();
            std::thread::Builder::new().name(format!("addon-pane-{port}")).spawn(move || {
                for conn in listener.incoming() {
                    if stop.load(Ordering::SeqCst) {
                        break;
                    }
                    let Ok(stream) = conn else { continue };
                    if active.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
                        active.fetch_sub(1, Ordering::SeqCst);
                        let _ = stream.shutdown(Shutdown::Both);
                        continue;
                    }
                    let ctx = ctx.clone();
                    let active = active.clone();
                    std::thread::spawn(move || {
                        handle(&ctx, stream);
                        active.fetch_sub(1, Ordering::SeqCst);
                    });
                }
            })?
        };
        Ok(PaneServer { port, token, csp, stop, thread: Some(thread) })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn token(&self) -> &str {
        &self.token
    }

    /// `http://127.0.0.1:<port>`, the pane's origin as the CSP names it.
    pub fn origin(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    /// The URL the iframe loads: `http://127.0.0.1:<port>/<token>/`.
    pub fn url(&self) -> String {
        format!("{}/{}/", self.origin(), self.token)
    }

    pub fn csp(&self) -> &str {
        &self.csp
    }

    /// Closes the listener and forgets the token.
    pub fn stop(mut self) {
        self.shutdown();
    }

    fn shutdown(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        // wake the accept loop
        let _ = TcpStream::connect_timeout(&SocketAddr::from((Ipv4Addr::LOCALHOST, self.port)), Duration::from_millis(500));
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

impl Drop for PaneServer {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn new_token() -> String {
    let mut b = [0u8; 16];
    getrandom::getrandom(&mut b).expect("the OS random source is unavailable");
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn collect_html_hashes(dir: &Path, out: &mut Vec<String>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        let Ok(m) = std::fs::symlink_metadata(&p) else { continue };
        if m.is_dir() {
            collect_html_hashes(&p, out);
        } else if m.is_file() && p.extension().is_some_and(|x| x.eq_ignore_ascii_case("html") || x.eq_ignore_ascii_case("htm")) {
            if let Ok(text) = std::fs::read(&p) {
                for h in csp::inline_script_hashes(&String::from_utf8_lossy(&text)) {
                    if !out.contains(&h) {
                        out.push(h);
                    }
                }
            }
        }
    }
}

// --- one connection --------------------------------------------------------

fn handle(ctx: &Ctx, mut stream: TcpStream) {
    let _ = stream.set_read_timeout(Some(IO_TIMEOUT));
    let _ = stream.set_write_timeout(Some(IO_TIMEOUT));
    let head = match read_head(&mut stream) {
        Ok(h) => h,
        Err(status) => {
            let _ = write_reply(ctx, &mut stream, &Reply::status(status), false);
            return;
        }
    };
    let reply = match parse_head(&head) {
        Ok(req) => route(ctx, &req.method, &req.target, &req.hosts),
        Err(status) => Reply::status(status),
    };
    let head_only = head.starts_with("HEAD ");
    let _ = write_reply(ctx, &mut stream, &reply, head_only);
    let _ = stream.shutdown(Shutdown::Both);
}

fn read_head(stream: &mut TcpStream) -> Result<String, u16> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 2048];
    loop {
        match stream.read(&mut tmp) {
            Ok(0) => return Err(400),
            Ok(n) => buf.extend_from_slice(&tmp[..n]),
            Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => return Err(408),
            Err(_) => return Err(400),
        }
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            buf.truncate(end);
            return String::from_utf8(buf).map_err(|_| 400);
        }
        if buf.len() > MAX_HEAD {
            return Err(431);
        }
    }
}

struct Request {
    method: String,
    target: String,
    hosts: Vec<String>,
}

fn parse_head(head: &str) -> Result<Request, u16> {
    let mut lines = head.split("\r\n");
    let first = lines.next().ok_or(400u16)?;
    let mut parts = first.split(' ');
    let method = parts.next().ok_or(400u16)?;
    let target = parts.next().ok_or(400u16)?;
    let version = parts.next().ok_or(400u16)?;
    if parts.next().is_some() || !(version == "HTTP/1.1" || version == "HTTP/1.0") || method.is_empty() || !method.bytes().all(|b| b.is_ascii_uppercase()) {
        return Err(400);
    }
    let mut hosts = Vec::new();
    for l in lines {
        if let Some((k, v)) = l.split_once(':') {
            if k.eq_ignore_ascii_case("host") {
                hosts.push(v.trim().to_string());
            }
        } else if !l.is_empty() {
            return Err(400);
        }
    }
    Ok(Request { method: method.to_string(), target: target.to_string(), hosts })
}

// --- routing ----------------------------------------------------------------

pub(crate) struct Reply {
    pub status: u16,
    pub content_type: &'static str,
    pub body: Vec<u8>,
    pub payload: bool,
}

impl Reply {
    fn status(status: u16) -> Reply {
        Reply { status, content_type: "text/plain; charset=utf-8", body: Vec::new(), payload: false }
    }
}

fn route(ctx: &Ctx, method: &str, target: &str, hosts: &[String]) -> Reply {
    // DNS rebinding first: the one allowed Host is exactly this listener.
    if hosts.len() != 1 || hosts[0] != format!("127.0.0.1:{}", ctx.port) {
        return Reply::status(421);
    }
    if method != "GET" && method != "HEAD" {
        return Reply::status(405);
    }
    if !target.starts_with('/') || target.starts_with("//") {
        return Reply::status(400);
    }
    // The query string is ignored and never looked at again.
    let path = target.split('?').next().unwrap_or("");
    if path.bytes().any(|b| b < 0x21 || b == 0x7f || b == b'\\') {
        return Reply::status(400);
    }
    let Some(rest_raw) = path.strip_prefix('/').and_then(|p| p.strip_prefix(ctx.token.as_str())) else {
        return Reply::status(404);
    };
    let rest_raw = match rest_raw.strip_prefix('/') {
        Some(r) => r,
        None => return Reply::status(404),
    };
    let rest = match percent_decode_once(rest_raw) {
        Some(r) => r,
        None => return Reply::status(400),
    };
    let rel: &str = if rest.is_empty() { &ctx.entry } else { &rest };
    if !valid_relative(rel) {
        return Reply::status(400);
    }
    match read_payload_file(ctx, rel) {
        Ok(body) => Reply { status: 200, content_type: mime(rel), body, payload: true },
        Err(404) => Reply::status(404),
        Err(s) => Reply::status(s),
    }
}

/// Decodes `%XX` once. Returns `None` for a bad escape or non-UTF-8 result.
fn percent_decode_once(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            let hex = s.get(i + 1..i + 3)?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// A relative path made of plain names: no empty, `.` or `..` segment, no
/// backslash, drive colon, NUL or control character, no Windows reserved
/// device name, nothing ending in a dot or space.
pub(crate) fn valid_relative(rel: &str) -> bool {
    if rel.is_empty() || rel.len() > 1024 {
        return false;
    }
    rel.split('/').all(|seg| {
        !seg.is_empty()
            && seg.len() <= 255
            && seg != "."
            && seg != ".."
            && !seg.ends_with('.')
            && !seg.ends_with(' ')
            && !seg.chars().any(|c| c.is_control() || c == '\\' || c == ':' || c == '<' || c == '>' || c == '"' || c == '|' || c == '?' || c == '*')
            && !is_reserved_device_name(seg)
    })
}

fn is_reserved_device_name(seg: &str) -> bool {
    let stem = seg.split('.').next().unwrap_or("").trim_end().to_ascii_uppercase();
    matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$")
        || (stem.len() == 4 && (stem.starts_with("COM") || stem.starts_with("LPT")) && stem.as_bytes()[3].is_ascii_digit() && stem.as_bytes()[3] != b'0')
}

fn read_payload_file(ctx: &Ctx, rel: &str) -> Result<Vec<u8>, u16> {
    match &ctx.payload {
        Payload::Embedded(files) => files.get(rel).cloned().ok_or(404),
        Payload::Dir(_) => {
            let root = ctx.root.as_ref().ok_or(404u16)?;
            let mut cur = root.clone();
            let mut last_meta = None;
            for seg in rel.split('/') {
                cur.push(seg);
                let meta = std::fs::symlink_metadata(&cur).map_err(|_| 404u16)?;
                if meta.file_type().is_symlink() {
                    return Err(404);
                }
                last_meta = Some(meta);
            }
            let meta = last_meta.ok_or(404u16)?;
            if !meta.is_file() {
                return Err(404);
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::MetadataExt;
                if meta.nlink() > 1 {
                    return Err(404);
                }
            }
            if meta.len() > MAX_FILE {
                return Err(413);
            }
            let real = std::fs::canonicalize(&cur).map_err(|_| 404u16)?;
            if !real.starts_with(root) {
                return Err(404);
            }
            std::fs::read(&real).map_err(|_| 404)
        }
    }
}

fn mime(path: &str) -> &'static str {
    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "html" | "htm" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" | "map" | "webmanifest" => "application/json",
        "txt" | "md" => "text/plain; charset=utf-8",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "avif" => "image/avif",
        "ico" => "image/x-icon",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "mp3" => "audio/mpeg",
        "ogg" | "oga" => "audio/ogg",
        "wav" => "audio/wav",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "wasm" => "application/wasm",
        _ => "application/octet-stream",
    }
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        413 => "Content Too Large",
        421 => "Misdirected Request",
        431 => "Request Header Fields Too Large",
        _ => "Error",
    }
}

fn render(ctx: &Ctx, r: &Reply, head_only: bool) -> Vec<u8> {
    let mut h = format!(
        "HTTP/1.1 {} {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\
         Content-Security-Policy: {}\r\nReferrer-Policy: no-referrer\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n",
        r.status,
        reason(r.status),
        r.content_type,
        r.body.len(),
        ctx.csp
    );
    if r.payload {
        h.push_str("Access-Control-Allow-Origin: *\r\n");
    }
    if r.status == 405 {
        h.push_str("Allow: GET, HEAD\r\n");
    }
    h.push_str("\r\n");
    let mut out = h.into_bytes();
    if !head_only {
        out.extend_from_slice(&r.body);
    }
    out
}

fn write_reply(ctx: &Ctx, stream: &mut TcpStream, r: &Reply, head_only: bool) -> std::io::Result<()> {
    stream.write_all(&render(ctx, r, head_only))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("agmsg-server-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn fixture(name: &str) -> (PathBuf, PathBuf) {
        let root = tmp(name);
        let payload = root.join("payload");
        fs::create_dir_all(payload.join("sub")).unwrap();
        fs::write(payload.join("index.html"), "<!doctype html><script>var a=1;</script>").unwrap();
        fs::write(payload.join("sub/file.txt"), "sub-file").unwrap();
        fs::write(payload.join("app.js"), "export {}").unwrap();
        fs::write(root.join("outside.txt"), "OUTSIDE-SECRET").unwrap();
        (root, payload)
    }

    fn start(payload: &Path) -> PaneServer {
        PaneServer::start(PaneSpec { payload: Payload::Dir(payload.to_path_buf()), entry: "index.html".into(), network: Network::None, expected_digest: None }).unwrap()
    }

    /// One raw request over a real socket; returns (status, headers text, body).
    fn raw(port: u16, request: &str) -> (u16, String, Vec<u8>) {
        let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        s.write_all(request.as_bytes()).unwrap();
        let mut buf = Vec::new();
        let _ = s.read_to_end(&mut buf);
        let end = buf.windows(4).position(|w| w == b"\r\n\r\n").unwrap_or(buf.len());
        let head = String::from_utf8_lossy(&buf[..end]).to_string();
        let body = buf.get(end + 4..).unwrap_or(&[]).to_vec();
        let status = head.split(' ').nth(1).and_then(|s| s.parse().ok()).unwrap_or(0);
        (status, head, body)
    }

    fn get(srv: &PaneServer, path: &str) -> (u16, String, Vec<u8>) {
        raw(srv.port(), &format!("GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n\r\n", srv.port()))
    }

    #[test]
    fn serves_the_entry_and_files_with_the_pane_headers() {
        let (_r, p) = fixture("serve");
        let srv = start(&p);
        let t = srv.token().to_string();
        let (st, head, body) = get(&srv, &format!("/{t}/index.html"));
        assert_eq!(st, 200);
        assert!(body.starts_with(b"<!doctype html>"));
        let h = head.to_ascii_lowercase();
        assert!(h.contains("access-control-allow-origin: *"));
        assert!(h.contains("referrer-policy: no-referrer"));
        assert!(h.contains("cache-control: no-store"));
        assert!(h.contains("x-content-type-options: nosniff"));
        assert!(h.contains("content-type: text/html"));
        assert!(h.contains(&format!("content-security-policy: default-src http://127.0.0.1:{}", srv.port())));
        // the inline script found in index.html is hashed into script-src
        assert!(head.contains(&csp::script_hash("var a=1;")));
        assert_eq!(get(&srv, &format!("/{t}/")).0, 200, "the bare token path serves the entry");
        let (st, _, body) = get(&srv, &format!("/{t}/sub/file.txt"));
        assert_eq!((st, body.as_slice()), (200, &b"sub-file"[..]));
        assert!(get(&srv, &format!("/{t}/app.js")).1.contains("text/javascript"));
    }

    #[test]
    fn head_has_headers_and_no_body() {
        let (_r, p) = fixture("head");
        let srv = start(&p);
        let (st, head, body) = raw(srv.port(), &format!("HEAD /{}/index.html HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n\r\n", srv.token(), srv.port()));
        assert_eq!(st, 200);
        assert!(head.to_ascii_lowercase().contains("content-length:"));
        assert!(body.is_empty());
    }

    #[test]
    fn traversal_and_odd_spellings_are_refused() {
        let (_r, p) = fixture("trav");
        let srv = start(&p);
        let t = srv.token().to_string();
        for path in [
            "..%2foutside.txt",
            "..%2f..%2foutside.txt",
            "%2e%2e/outside.txt",
            "%2E%2E/outside.txt",
            "../outside.txt",
            "sub/../index.html",
            "./index.html",
            "sub//file.txt",
            "..%5coutside.txt",
            "sub%5cfile.txt",
            "C:/Windows/win.ini",
            "C%3a/Windows/win.ini",
            "%5c%5cserver%5cshare%5cx",
            "index.html%00.txt",
            "/etc/hosts",
            "sub/",
            "CON",
            "nul.txt",
            "COM1",
            "file.txt.",
            "bad%zz",
            "%ff%fe",
        ] {
            let (st, _, body) = get(&srv, &format!("/{t}/{path}"));
            assert!(st == 400 || st == 404, "{path} -> {st}");
            assert!(!String::from_utf8_lossy(&body).contains("OUTSIDE-SECRET"), "{path} leaked");
        }
        // double encoding is decoded once only: the literal name `%2e%2e` does not exist
        assert_eq!(get(&srv, &format!("/{t}/%252e%252e/outside.txt")).0, 404);
        // raw backslash and control bytes in the request line
        assert_eq!(get(&srv, &format!("/{t}/a\\b")).0, 400);
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_and_hardlinks_are_not_served() {
        let (r, p) = fixture("links");
        std::os::unix::fs::symlink(r.join("outside.txt"), p.join("link")).unwrap();
        std::os::unix::fs::symlink(&r, p.join("dirlink")).unwrap();
        fs::hard_link(r.join("outside.txt"), p.join("hard.txt")).unwrap();
        let srv = start(&p);
        let t = srv.token().to_string();
        for path in ["link", "dirlink/outside.txt", "hard.txt"] {
            let (st, _, body) = get(&srv, &format!("/{t}/{path}"));
            assert_eq!(st, 404, "{path}");
            assert!(!String::from_utf8_lossy(&body).contains("OUTSIDE-SECRET"));
        }
    }

    #[test]
    fn wrong_token_or_shape_is_404_with_no_listing_and_no_redirect() {
        let (_r, p) = fixture("tok");
        let srv = start(&p);
        let t = srv.token().to_string();
        assert_eq!(t.len(), 32);
        for path in ["/", "/index.html", &format!("/{t}"), &format!("/{}/index.html", "0".repeat(32)), &format!("/{t}x/index.html"), &format!("/{t}/sub"), &format!("/{}/{}", &t[..31], "index.html")] {
            let (st, head, _) = get(&srv, path);
            assert_eq!(st, 404, "{path}");
            assert!(!head.to_ascii_lowercase().contains("location:"), "{path}");
        }
        assert_eq!(get(&srv, "//etc/hosts").0, 400);
    }

    #[test]
    fn tokens_and_ports_are_per_pane() {
        let (_r, p) = fixture("two");
        let a = start(&p);
        let b = start(&p);
        assert_ne!(a.token(), b.token());
        assert_ne!(a.port(), b.port());
        assert_eq!(get(&a, &format!("/{}/index.html", b.token())).0, 404);
        assert_eq!(raw(b.port(), &format!("GET /{}/index.html HTTP/1.1\r\nHost: 127.0.0.1:{}\r\n\r\n", a.token(), b.port())).0, 404);
    }

    #[test]
    fn host_header_must_be_this_listener_exactly() {
        let (_r, p) = fixture("host");
        let srv = start(&p);
        let t = srv.token().to_string();
        let port = srv.port();
        for host in [format!("evil.test:{port}"), "127.0.0.1".to_string(), format!("localhost:{port}"), "127.0.0.1:1".to_string(), format!("127.0.0.1:{port}.evil.test"), String::new()] {
            let (st, _, _) = raw(port, &format!("GET /{t}/index.html HTTP/1.1\r\nHost: {host}\r\n\r\n"));
            assert_eq!(st, 421, "Host {host:?}");
        }
        assert_eq!(raw(port, &format!("GET /{t}/index.html HTTP/1.1\r\n\r\n")).0, 421, "no Host");
        assert_eq!(raw(port, &format!("GET /{t}/index.html HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nHost: evil.test\r\n\r\n")).0, 421, "two Hosts");
    }

    #[test]
    fn only_get_and_head() {
        let (_r, p) = fixture("meth");
        let srv = start(&p);
        let (t, port) = (srv.token().to_string(), srv.port());
        for m in ["POST", "PUT", "DELETE", "OPTIONS", "TRACE", "PATCH", "CONNECT"] {
            let (st, head, _) = raw(port, &format!("{m} /{t}/index.html HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Length: 1\r\n\r\nx"));
            assert_eq!(st, 405, "{m}");
            assert!(head.contains("Allow: GET, HEAD"));
        }
    }

    #[test]
    fn query_string_is_ignored_and_malformed_requests_are_refused() {
        let (_r, p) = fixture("q");
        let srv = start(&p);
        let (t, port) = (srv.token().to_string(), srv.port());
        assert_eq!(get(&srv, &format!("/{t}/index.html?secret=1&x=%zz")).0, 200);
        assert_eq!(raw(port, "garbage\r\n\r\n").0, 400);
        assert_eq!(raw(port, &format!("GET /{t}/index.html HTTP/2\r\nHost: 127.0.0.1:{port}\r\n\r\n")).0, 400);
        assert_eq!(raw(port, &format!("get /{t}/index.html HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n")).0, 400);
        let huge = format!("GET /{t}/index.html HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nX: {}\r\n\r\n", "a".repeat(20_000));
        assert_eq!(raw(port, &huge).0, 431);
    }

    #[test]
    fn digest_mismatch_refuses_to_start_and_match_starts() {
        let (_r, p) = fixture("dig");
        let good = digest::payload_digest(&p).unwrap();
        let ok = PaneServer::start(PaneSpec { payload: Payload::Dir(p.clone()), entry: "index.html".into(), network: Network::None, expected_digest: Some(good.clone()) });
        assert!(ok.is_ok());
        drop(ok);
        fs::write(p.join("app.js"), "changed").unwrap();
        let bad = PaneServer::start(PaneSpec { payload: Payload::Dir(p.clone()), entry: "index.html".into(), network: Network::None, expected_digest: Some(good) });
        assert!(matches!(bad, Err(StartError::DigestMismatch)));
    }

    #[test]
    fn missing_entry_refuses_to_start() {
        let (_r, p) = fixture("noentry");
        let r = PaneServer::start(PaneSpec { payload: Payload::Dir(p), entry: "nope.html".into(), network: Network::None, expected_digest: None });
        assert!(matches!(r, Err(StartError::NoEntry(_))));
    }

    #[test]
    fn embedded_payload_and_network_in_the_csp() {
        let mut files = HashMap::new();
        files.insert("index.html".to_string(), b"<script>x()</script><div></div>".to_vec());
        let srv = PaneServer::start(PaneSpec {
            payload: Payload::Embedded(files),
            entry: "index.html".into(),
            network: Network::Origins(vec!["https://api.example.com".into()]),
            expected_digest: None,
        })
        .unwrap();
        let (st, head, body) = get(&srv, &format!("/{}/", srv.token()));
        assert_eq!(st, 200);
        assert!(body.starts_with(b"<script>"));
        assert!(head.contains("connect-src http://127.0.0.1:"));
        assert!(head.contains("https://api.example.com"));
        assert!(head.contains(&csp::script_hash("x()")));
        assert_eq!(get(&srv, &format!("/{}/missing.js", srv.token())).0, 404);
    }

    #[test]
    fn stopping_closes_the_listener() {
        let (_r, p) = fixture("stop");
        let srv = start(&p);
        let port = srv.port();
        assert!(TcpStream::connect(("127.0.0.1", port)).is_ok());
        srv.stop();
        assert!(TcpStream::connect_timeout(&SocketAddr::from((Ipv4Addr::LOCALHOST, port)), Duration::from_millis(500)).is_err());
    }

    #[test]
    fn reserved_names_and_relative_rules() {
        for ok in ["index.html", "a/b.js", "assets/index-4xt2AJ_m.css", ".well-known/x", "a b.txt", "console.log.js"] {
            assert!(valid_relative(ok), "{ok}");
        }
        for bad in ["", ".", "..", "a/../b", "a//b", "/a", "a/", "con", "CON.txt", "Aux", "lpt1.x", "com9", "a:b", "a\\b", "a\0b", "a.", "a ", "a?b", "a*b", "a<b"] {
            assert!(!valid_relative(bad), "{bad:?}");
        }
        assert!(valid_relative("com0"));
        assert!(valid_relative("console"));
    }
}
