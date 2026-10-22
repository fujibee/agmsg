//! What the main webview may navigate to (design 4.4).
//!
//! The native `on_navigation` handler sees subframe navigations too (measured
//! on WKWebView) but gets only a URL, so it cannot tell the app reloading
//! itself from an add-on frame navigating to the app origin. This list is
//! therefore one layer only: the main-window CSP `frame-src` is the layer that
//! keeps a frame from becoming the app origin (see `host`).

use std::sync::Mutex;
use tauri::Url;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Allow,
    Deny(&'static str),
}

impl Decision {
    pub fn is_allow(&self) -> bool {
        matches!(self, Decision::Allow)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Origin {
    scheme: String,
    host: String,
    port: Option<u16>,
}

impl Origin {
    fn of(url: &Url) -> Option<Origin> {
        Some(Origin { scheme: url.scheme().to_string(), host: url.host_str()?.to_ascii_lowercase(), port: url.port() })
    }
}

pub struct NavPolicy {
    app: Vec<Origin>,
    panes: Mutex<Vec<(u16, String)>>,
}

impl NavPolicy {
    /// `dev_url` is the dev server of `tauri dev`; `None` in a built app.
    pub fn new(dev_url: Option<&Url>) -> NavPolicy {
        let mut app = vec![
            Origin { scheme: "tauri".into(), host: "localhost".into(), port: None },
            Origin { scheme: "http".into(), host: "tauri.localhost".into(), port: None },
            Origin { scheme: "https".into(), host: "tauri.localhost".into(), port: None },
        ];
        if let Some(o) = dev_url.and_then(Origin::of) {
            app.push(o);
        }
        NavPolicy { app, panes: Mutex::new(Vec::new()) }
    }

    /// Allow navigations to this live pane (`http://127.0.0.1:<port>/<token>/…`).
    pub fn register_pane(&self, port: u16, token: &str) {
        let mut p = self.panes.lock().unwrap();
        if !p.iter().any(|(pp, t)| *pp == port && t == token) {
            p.push((port, token.to_string()));
        }
    }

    pub fn unregister_pane(&self, port: u16, token: &str) {
        self.panes.lock().unwrap().retain(|(pp, t)| !(*pp == port && t == token));
    }

    /// True for the app's own origins (not panes).
    pub fn is_app(&self, url: &Url) -> bool {
        Origin::of(url).is_some_and(|o| self.app.contains(&o))
    }

    pub fn decide(&self, url: &Url) -> Decision {
        if let Some(o) = Origin::of(url) {
            if self.app.contains(&o) {
                return Decision::Allow;
            }
            if o.scheme == "http" && o.host == "127.0.0.1" {
                if let Some(port) = o.port {
                    let path = url.path();
                    let panes = self.panes.lock().unwrap();
                    if panes.iter().any(|(pp, t)| *pp == port && path.strip_prefix('/').and_then(|p| p.strip_prefix(t.as_str())).is_some_and(|r| r.starts_with('/'))) {
                        return Decision::Allow;
                    }
                    return Decision::Deny("loopback address that is not a live add-on pane");
                }
            }
            return Decision::Deny("not the app and not a live add-on pane");
        }
        Decision::Deny("no host to match (about:, data:, blob:, file: and the like)")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn u(s: &str) -> Url {
        Url::parse(s).unwrap()
    }

    fn policy() -> NavPolicy {
        let p = NavPolicy::new(None);
        p.register_pane(5000, "aaaa");
        p
    }

    #[test]
    fn the_app_origins_are_allowed() {
        let p = policy();
        for s in ["tauri://localhost/", "tauri://localhost/index.html?x=1#y", "http://tauri.localhost/", "https://tauri.localhost/a"] {
            assert!(p.decide(&u(s)).is_allow(), "{s}");
        }
    }

    #[test]
    fn only_registered_pane_urls_are_allowed() {
        let p = policy();
        assert!(p.decide(&u("http://127.0.0.1:5000/aaaa/index.html")).is_allow());
        assert!(p.decide(&u("http://127.0.0.1:5000/aaaa/")).is_allow());
        for s in [
            "http://127.0.0.1:5000/bbbb/index.html",
            "http://127.0.0.1:5000/aaaax/index.html",
            "http://127.0.0.1:5000/aaaa",
            "http://127.0.0.1:5000/",
            "http://127.0.0.1:5001/aaaa/index.html",
            "https://127.0.0.1:5000/aaaa/index.html",
            "http://localhost:5000/aaaa/index.html",
            "http://127.0.0.2:5000/aaaa/index.html",
            "http://127.0.0.1/aaaa/index.html",
        ] {
            assert!(!p.decide(&u(s)).is_allow(), "{s}");
        }
    }

    #[test]
    fn everything_else_is_denied() {
        let p = policy();
        for s in [
            "https://example.com/",
            "http://tauri.localhost.evil.test/",
            "http://evil.test/tauri.localhost",
            "tauri://evil/",
            "ipc://localhost/addon_canary",
            "asset://localhost/etc/hosts",
            "file:///etc/hosts",
            "about:blank",
            "about:srcdoc",
            "data:text/html,x",
            "blob:http://127.0.0.1:5000/abc",
            "javascript:alert(1)",
            "http://192.168.1.2:5000/aaaa/",
            "http://[::1]:5000/aaaa/",
        ] {
            assert!(!p.decide(&u(s)).is_allow(), "{s}");
        }
    }

    #[test]
    fn unregistering_a_pane_revokes_it() {
        let p = policy();
        p.unregister_pane(5000, "aaaa");
        assert!(!p.decide(&u("http://127.0.0.1:5000/aaaa/index.html")).is_allow());
        p.register_pane(5000, "aaaa");
        assert!(p.decide(&u("http://127.0.0.1:5000/aaaa/index.html")).is_allow());
    }

    #[test]
    fn dev_server_is_allowed_only_when_given() {
        assert!(!NavPolicy::new(None).decide(&u("http://localhost:1420/")).is_allow());
        let d = u("http://localhost:1420/");
        let p = NavPolicy::new(Some(&d));
        assert!(p.decide(&u("http://localhost:1420/src/main.tsx")).is_allow());
        assert!(!p.decide(&u("http://localhost:1421/")).is_allow());
    }
}
