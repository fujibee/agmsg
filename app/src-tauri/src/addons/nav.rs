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

/// The rule for one add-on frame on an engine whose native handler tells frames
/// apart (WebView2's frame navigation events). The first navigation must be to a
/// live pane; after that the frame may only move within that exact origin
/// (scheme, host and port), never to the app origin and never elsewhere.
#[derive(Default)]
pub struct FrameNav {
    own: Mutex<Option<Origin>>,
}

impl FrameNav {
    pub fn decide(&self, policy: &NavPolicy, url: &Url) -> Decision {
        let d = policy.decide(url);
        if !d.is_allow() {
            return d;
        }
        if policy.is_app(url) {
            return Decision::Deny("a frame may not navigate to the app origin");
        }
        let Some(o) = Origin::of(url) else {
            return Decision::Deny("no host to match");
        };
        let mut own = self.own.lock().unwrap();
        match own.as_ref() {
            None => {
                *own = Some(o);
                Decision::Allow
            }
            Some(prev) if *prev == o => Decision::Allow,
            Some(_) => Decision::Deny("frame leaving its own origin"),
        }
    }
}

/// Whether the frame guard of a window is working. The guard is required on
/// engines that need it: until `mark_active` and after any `fail`, `problem()`
/// names why add-ons must stay off.
#[derive(Default)]
pub struct GuardStatus {
    active: std::sync::atomic::AtomicBool,
    failure: Mutex<Option<String>>,
    /// Targets of the frame navigations the guard cancelled (normalized, newest last, capped).
    cancelled: Mutex<Vec<String>>,
}

impl GuardStatus {
    pub fn mark_active(&self) {
        self.active.store(true, std::sync::atomic::Ordering::SeqCst);
    }

    /// Records the first failure; returns true when this call was the first.
    pub fn fail(&self, why: &str) -> bool {
        let mut f = self.failure.lock().unwrap();
        if f.is_some() {
            return false;
        }
        *f = Some(why.to_string());
        true
    }

    /// Turns a setup step into "did it work": a failure is recorded and returns false.
    pub fn check(&self, what: &str, r: Result<(), String>) -> bool {
        match r {
            Ok(()) => true,
            Err(e) => {
                self.fail(&format!("{what}: {e}"));
                false
            }
        }
    }

    pub fn note_cancelled(&self, uri: &str) {
        let mut c = self.cancelled.lock().unwrap();
        if c.len() >= 64 {
            c.remove(0);
        }
        c.push(uri.to_string());
    }

    pub fn cancelled(&self) -> Vec<String> {
        self.cancelled.lock().unwrap().clone()
    }

    /// `None` when the guard is installed and nothing has gone wrong.
    pub fn problem(&self) -> Option<String> {
        if let Some(f) = self.failure.lock().unwrap().clone() {
            return Some(f);
        }
        if !self.active.load(std::sync::atomic::Ordering::SeqCst) {
            return Some("the frame navigation guard is not installed".to_string());
        }
        None
    }
}

/// A frame is about to navigate: cancel unless the rule says allow. An address
/// that could not be read or parsed is cancelled (and a failed read is recorded).
pub fn frame_navigation_allowed(rule: &FrameNav, policy: &NavPolicy, uri: Result<String, String>, status: &GuardStatus) -> bool {
    let uri = match uri {
        Ok(u) => u,
        Err(e) => {
            status.fail(&format!("could not read a frame's navigation target: {e}"));
            return false;
        }
    };
    match Url::parse(&uri) {
        Ok(url) => {
            let allow = rule.decide(policy, &url).is_allow();
            if !allow {
                status.note_cancelled(url.as_str());
            }
            allow
        }
        Err(_) => false,
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

    #[test]
    fn a_frame_stays_in_its_own_pane_origin() {
        let p = policy();
        p.register_pane(5001, "bbbb");
        let f = FrameNav::default();
        assert!(f.decide(&p, &u("http://127.0.0.1:5000/aaaa/index.html")).is_allow());
        assert!(f.decide(&p, &u("http://127.0.0.1:5000/aaaa/other.html")).is_allow());
        // another live pane, the app, and the outside are all refused
        assert!(!f.decide(&p, &u("http://127.0.0.1:5001/bbbb/index.html")).is_allow());
        assert!(!f.decide(&p, &u("tauri://localhost/")).is_allow());
        assert!(!f.decide(&p, &u("http://tauri.localhost/")).is_allow());
        assert!(!f.decide(&p, &u("https://example.com/")).is_allow());
        assert!(!f.decide(&p, &u("about:blank")).is_allow());
    }

    #[test]
    fn a_frame_whose_first_navigation_is_not_a_live_pane_is_refused() {
        let p = policy();
        for s in ["tauri://localhost/", "https://example.com/", "http://127.0.0.1:5000/zzzz/", "about:blank"] {
            let f = FrameNav::default();
            assert!(!f.decide(&p, &u(s)).is_allow(), "{s}");
            // a refusal records nothing: the frame can still start at a live pane
            assert!(f.decide(&p, &u("http://127.0.0.1:5000/aaaa/")).is_allow(), "{s}");
        }
    }

    #[test]
    fn the_guard_is_a_problem_until_installed_and_after_any_failure() {
        let g = GuardStatus::default();
        assert!(g.problem().is_some());
        g.mark_active();
        assert_eq!(g.problem(), None);
        assert!(g.check("a step", Ok(())));
        assert_eq!(g.problem(), None);
        assert!(!g.check("watching a frame", Err("no interface".into())));
        assert_eq!(g.problem().as_deref(), Some("watching a frame: no interface"));
        // the first failure is the one kept
        assert!(!g.fail("later"));
        assert_eq!(g.problem().as_deref(), Some("watching a frame: no interface"));
    }

    #[test]
    fn each_setup_step_that_fails_is_recorded() {
        for step in ["cast to Frame2", "add NavigationStarting", "cast to Frame7", "add child FrameCreated", "cast to Core4", "add FrameCreated"] {
            let g = GuardStatus::default();
            g.mark_active();
            assert!(!g.check(step, Err("E_FAIL".into())), "{step}");
            assert_eq!(g.problem().unwrap(), format!("{step}: E_FAIL"));
        }
    }

    #[test]
    fn a_target_that_cannot_be_read_or_parsed_is_cancelled() {
        let p = policy();
        let g = GuardStatus::default();
        g.mark_active();
        let f = FrameNav::default();
        assert!(!frame_navigation_allowed(&f, &p, Err("E_POINTER".into()), &g));
        assert!(g.problem().unwrap().contains("could not read"));
        let g2 = GuardStatus::default();
        g2.mark_active();
        assert!(!frame_navigation_allowed(&f, &p, Ok("not a url".into()), &g2));
        assert!(!frame_navigation_allowed(&f, &p, Ok("tauri://localhost/".into()), &g2));
        assert_eq!(g2.cancelled(), vec!["tauri://localhost/".to_string()]);
        assert!(frame_navigation_allowed(&f, &p, Ok("http://127.0.0.1:5000/aaaa/".into()), &g2));
        assert_eq!(g2.problem(), None);
    }
}
