//! The Tauri commands the main UI uses to run add-on panes. All of them are
//! behind the app ACL (main window only). The UI is a relay: it creates the
//! iframe from `addon_pane_add`'s URL, tells Rust when the frame loaded
//! (`addon_pane_loaded` → the new generation), forwards requests from the pane's
//! MessagePort to `addon_request` with the pane instance and generation of that
//! port, and posts back what Rust returns. Rust decides every time.
//!
//! Shapes (JSON, camelCase):
//! - `addon_pane_add({addon, commit, name, dir, entry?, declared:{messagesRead,filesRead,gitRead}, network?, openArgs:{path?,url?,base?}, expectedDigest?}) → {id, url, port}`
//! - `addon_pane_remove(id)`; `addon_pane_loaded(id) → generation`
//! - `addon_grant_team(id, team)`, `addon_revoke_team(id)`
//! - `addon_grant_root(id, path) → realPath`, `addon_revoke_root(id)`
//! - `addon_feed_init(id, generation) → {init, queued}`: post `init`, then each of `queued`
//! - `addon_request(id, generation, op, args) → {agmsg:1,type:"response",ok:true,result} | {…ok:false,error:{code,message}}`
//!   (the UI adds the request `id`); a `fs.read` result with `bytesBase64` must become an
//!   `ArrayBuffer` in `bytes` before it is posted to the add-on.
//! - event `addon-push`: `{pane, generation, event}` for a live message; the UI posts `event`
//!   to the pane's port only if `generation` is the pane's current one.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Listener, Runtime, State};

use super::broker;
use super::catalog::AddonInfo;
use super::conf::AddonConf;
use super::denylist::{self, Denylist, GrantCheck};
use super::feed::{self, Feed, FeedMessage};
use super::host::AddonHost;
use super::panes::{AddPane, BrokerError, Need, OpenArgs, PaneId, Registry};
use super::server::Payload;

pub const PUSH_EVENT: &str = "addon-push";
/// A pane was closed by the app because its files changed: `{pane, reason}`.
pub const PANE_FAILED_EVENT: &str = "addon-pane-failed";

/// Registry, feeds and the denylist, shared with the window-side `AddonHost`.
pub struct Panes {
    pub registry: Mutex<Registry>,
    pub feeds: Mutex<HashMap<(PaneId, u64), Feed>>,
    /// The protected-location list, rebuilt when a pane opens or a folder is
    /// granted (stores and teams can appear later). Always includes the app's own
    /// folders, the agmsg base and the stores.
    deny: Mutex<Arc<Denylist>>,
    /// The app's own bundle, data, config and cache folders (set at startup).
    app_dirs: Mutex<Vec<PathBuf>>,
    /// Extra protected places from outside (tests, future settings).
    extra_protected: Mutex<Vec<PathBuf>>,
}

impl Default for Panes {
    fn default() -> Self {
        Panes::new()
    }
}

impl Panes {
    pub fn new() -> Panes {
        Panes {
            registry: Mutex::new(Registry::new()),
            feeds: Mutex::new(HashMap::new()),
            deny: Mutex::new(Arc::new(Denylist::from_process_env(crate::agmsg::protected_locations()))),
            app_dirs: Mutex::new(Vec::new()),
            extra_protected: Mutex::new(Vec::new()),
        }
    }

    /// The list to judge a path by right now.
    pub fn deny(&self) -> Arc<Denylist> {
        self.deny.lock().unwrap().clone()
    }

    pub fn set_app_dirs(&self, dirs: Vec<PathBuf>) {
        *self.app_dirs.lock().unwrap() = dirs;
        self.refresh_deny();
    }

    /// Rebuilds the list from the current base, stores and app folders.
    pub fn refresh_deny(&self) {
        let mut extra = self.app_dirs.lock().unwrap().clone();
        extra.extend(self.extra_protected.lock().unwrap().iter().cloned());
        extra.extend(crate::agmsg::protected_locations());
        *self.deny.lock().unwrap() = Arc::new(Denylist::from_process_env(extra));
    }

    /// Closes these panes now: the listener and token go, feeds go, the navigation
    /// entry goes. Returns the ids that were actually closed (each only once).
    pub fn close_ids(&self, nav: &super::nav::NavPolicy, ids: &[PaneId]) -> Vec<PaneId> {
        let mut closed = Vec::new();
        for id in ids {
            let r = self.registry.lock().unwrap().remove(*id);
            if let Some((port, token)) = r {
                nav.unregister_pane(port, &token);
                closed.push(*id);
            }
            self.feeds.lock().unwrap().retain(|(p, _), _| p != id);
        }
        closed
    }

    /// Settings → Revoke: every live pane of this add-on that holds this grant loses it
    /// (the generation is bumped like any scope change) and is closed.
    pub fn revoke_matching(&self, nav: &super::nav::NavPolicy, addon: &str, pane: &str, permission: &str, scope: &str) -> Vec<PaneId> {
        let ids = {
            let mut reg = self.registry.lock().unwrap();
            let ids = reg.holders(addon, pane, permission, scope);
            for id in &ids {
                match permission {
                    "files:read" => reg.revoke_root(*id),
                    _ => reg.revoke_team(*id),
                }
            }
            ids
        };
        self.close_ids(nav, &ids)
    }

    /// Everything a page load, reload or update voids: every pane and its feeds.
    /// Returns the (port, token) pairs that were closed.
    pub fn close_all(&self) -> Vec<(u16, String)> {
        let mut reg = self.registry.lock().unwrap();
        let ids = reg.ids();
        let closed = ids.into_iter().filter_map(|id| reg.remove(id)).collect();
        self.feeds.lock().unwrap().clear();
        closed
    }
}

/// The UI names an add-on and a pane; Rust finds the directory, checks its
/// digest and reads what it declared. No path comes from the UI.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneAddIn {
    /// An `id` from `addon_list`.
    pub addon_id: String,
    pub pane: String,
    /// What the pane is opened with (a folder the user picked, a base ref, …).
    #[serde(default)]
    pub open_args: OpenArgs,
}

#[derive(Debug, Serialize)]
pub struct PaneAddOut {
    pub id: PaneId,
    pub url: String,
    pub port: u16,
    pub title: String,
    pub permissions: Vec<String>,
    pub network: String,
    /// The add-on commit this pane runs; send it back with `addon_save_grant`.
    pub commit: String,
}

fn off(host: &AddonHost) -> String {
    let v = host.gate.status();
    format!("add-ons are off on this computer: {}", v.reasons.join("; "))
}

/// Every add-on the user can open: built-ins, installed ones. Never a path.
#[tauri::command(async)]
pub fn addon_list(host: State<'_, Arc<AddonHost>>) -> Vec<AddonInfo> {
    host.catalog().list()
}

/// What a pane may be opened with: only what its `addon.conf` says it accepts
/// (`opens`), with named errors. `base` rides with a path and needs `git:read`.
pub fn validate_open_args(a: OpenArgs, conf: &AddonConf) -> Result<OpenArgs, String> {
    for (name, v) in [("path", &a.path), ("url", &a.url), ("base", &a.base)] {
        if let Some(v) = v {
            if v.len() > 4096 || v.contains('\0') {
                return Err(format!("open_args_invalid: `{name}` is too long or has a NUL byte"));
            }
        }
    }
    let opens = |k: &str| conf.opens.iter().any(|o| o == k);
    if a.path.is_some() && !opens("path") {
        return Err("open_args_not_declared: this pane does not accept a path (its addon.conf has no `opens = path`)".into());
    }
    if a.url.is_some() && !opens("url") {
        return Err("open_args_not_declared: this pane does not accept a url (its addon.conf has no `opens = url`)".into());
    }
    if a.base.is_some() {
        if a.path.is_none() {
            return Err("open_args_not_declared: `base` is only accepted together with a path".into());
        }
        if !conf.permissions.iter().any(|p| p == "git:read") {
            return Err("open_args_not_declared: this pane did not declare git:read, so it takes no `base`".into());
        }
    }
    Ok(a)
}

/// Opening a pane failed: one line in the log with the step and a fixed code, never the message or a path,
/// so a failure on a user's machine leaves something to go on.
fn log_open_failed(step: &str, code: &str) {
    eprintln!("[addons] open failed: {step} {code}");
}

#[tauri::command(async)]
pub fn addon_pane_add<R: Runtime>(app: AppHandle<R>, host: State<'_, Arc<AddonHost>>, spec: PaneAddIn) -> Result<PaneAddOut, String> {
    pane_add(app, host, spec).map_err(|(code, message)| {
        log_open_failed("pane_add", code);
        message
    })
}

fn pane_add<R: Runtime>(app: AppHandle<R>, host: State<'_, Arc<AddonHost>>, spec: PaneAddIn) -> Result<PaneAddOut, (&'static str, String)> {
    if !host.gate.status().enabled {
        return Err(("gate_off", off(&host)));
    }
    let resolved = host.catalog().resolve(&spec.addon_id, &spec.pane).map_err(|e| {
        let code = match &e {
            super::catalog::CatalogError::Unknown(_) => "unknown",
            super::catalog::CatalogError::Changed(_) => "changed",
            super::catalog::CatalogError::Invalid(_) => "invalid",
        };
        (code, e.to_string())
    })?;
    let open_args = validate_open_args(spec.open_args, &resolved.conf).map_err(|e| ("open_args", e))?;
    host.panes.refresh_deny();
    // If a served file stops matching what was verified, the pane is closed and the UI told why.
    let on_tamper: Arc<dyn Fn(u16, String, String) + Send + Sync> = {
        let host: Arc<AddonHost> = host.inner().clone();
        let app = app.clone();
        Arc::new(move |port: u16, token: String, detail: String| {
            // closes only the pane with this port AND this token: a late notice never touches another pane
            let closed = host.panes.registry.lock().unwrap().remove_matching(port, &token);
            if let Some((id, port, token)) = closed {
                host.nav.unregister_pane(port, &token);
                host.panes.feeds.lock().unwrap().retain(|(p, _), _| *p != id);
                eprintln!("[addons] closed pane {id}: {detail}");
                let _ = app.emit(PANE_FAILED_EVENT, json!({ "pane": id, "reason": "This add-on's files changed after it was opened. Reinstall it or reload." }));
            }
        })
    };
    let added = host
        .panes
        .registry
        .lock()
        .unwrap()
        .add(AddPane {
            addon: resolved.addon.clone(),
            commit: resolved.commit.clone(),
            name: resolved.pane.clone(),
            payload: Payload::Dir(resolved.web_dir.clone()),
            entry: resolved.conf.entry.clone(),
            declared: resolved.conf.declared(),
            open_args,
            expected_digest: None,
            pinned: Some(resolved.pinned.clone()),
            on_tamper: Some(on_tamper),
        })
        .map_err(|e| ("start", e.to_string()))?;
    host.nav.register_pane(added.port, &added.token);
    Ok(PaneAddOut {
        id: added.id,
        url: added.url,
        port: added.port,
        title: resolved.conf.title.clone(),
        permissions: resolved.conf.permissions.clone(),
        network: resolved.conf.network.clone().unwrap_or_default(),
        commit: resolved.commit.clone(),
    })
}

#[tauri::command]
pub fn addon_pane_remove(host: State<'_, Arc<AddonHost>>, id: PaneId) {
    let closed = host.panes.registry.lock().unwrap().remove(id);
    if let Some((port, token)) = closed {
        host.nav.unregister_pane(port, &token);
    }
    host.panes.feeds.lock().unwrap().retain(|(p, _), _| *p != id);
}

/// The pane's iframe finished loading (first load or reload): a new generation.
#[tauri::command]
pub fn addon_pane_loaded(host: State<'_, Arc<AddonHost>>, id: PaneId) -> Result<u64, BrokerError> {
    let g = host.panes.registry.lock().unwrap().begin_generation(id).ok_or_else(|| BrokerError::new("not_granted", "this pane is closed"))?;
    // feeds of older generations are void
    host.panes.feeds.lock().unwrap().retain(|(p, gen), _| *p != id || *gen == g);
    Ok(g)
}

#[tauri::command]
pub fn addon_grant_team(host: State<'_, Arc<AddonHost>>, id: PaneId, team: String) -> Result<(), BrokerError> {
    host.panes.registry.lock().unwrap().grant_team(id, &team)
}

/// The user allowed (or took back) one of `team:join`, `messages:send`, `agents:spawn` for this pane. Each
/// needs the team too; the app calls this from the saved consent, never from the frame.
#[tauri::command]
pub fn addon_set_power(host: State<'_, Arc<AddonHost>>, id: PaneId, power: String, on: bool) -> Result<(), BrokerError> {
    let p = super::panes::Power::parse(&power).ok_or_else(|| BrokerError::new("bad_args", "unknown power"))?;
    host.panes.registry.lock().unwrap().set_power(id, p, on)
}

#[tauri::command]
pub fn addon_revoke_team(host: State<'_, Arc<AddonHost>>, id: PaneId) {
    host.panes.registry.lock().unwrap().revoke_team(id);
    host.panes.feeds.lock().unwrap().retain(|(p, _), _| *p != id);
}

/// Resolves and checks a folder the user picked, then allows the pane to read under it.
#[tauri::command(async)]
pub fn addon_grant_root(host: State<'_, Arc<AddonHost>>, id: PaneId, path: String) -> Result<String, BrokerError> {
    host.panes.refresh_deny();
    let r = grant_root_path(&host.panes.deny(), &path).and_then(|real| {
        host.panes.registry.lock().unwrap().grant_root(id, real.clone())?;
        Ok(real.to_string_lossy().into_owned())
    });
    // a refused or vanished folder is an ordinary answer with its own card; anything else is logged
    if let Err(e) = &r {
        if e.code != "denied_path" && e.code != "not_found" {
            log_open_failed("grant_root", &e.code);
        }
    }
    r
}

/// The real path a chosen folder would be granted as, with the same checks as `addon_grant_root`
/// but nothing granted. The UI uses it to see whether a picked folder is one the person already
/// chose to remember; a refusal here means the card (with its explanation) is the next step.
#[tauri::command(async)]
pub fn addon_resolve_folder(host: State<'_, Arc<AddonHost>>, path: String) -> Result<String, BrokerError> {
    host.panes.refresh_deny();
    Ok(grant_root_path(&host.panes.deny(), &path)?.to_string_lossy().into_owned())
}

pub fn grant_root_path(deny: &Denylist, path: &str) -> Result<PathBuf, BrokerError> {
    let p = PathBuf::from(path);
    if !p.is_absolute() {
        return Err(BrokerError::new("bad_args", "choose a folder by its full path"));
    }
    let real = std::fs::canonicalize(&p).map_err(|_| BrokerError::new("not_found", format!("{path} no longer exists")))?;
    if !real.is_dir() {
        return Err(BrokerError::new("bad_args", "that is not a folder"));
    }
    match deny.check_grant_root(&real) {
        GrantCheck::Ok => Ok(real),
        GrantCheck::Denied(_) => Err(BrokerError::new("denied_path", denylist::refusal_message(&real))),
    }
}

/// What the card says about the folder just allowed for this pane: whether it holds a `.env`
/// file (a bounded look), and whether this pane declares `network`, which means it will not
/// be able to read one. Only information; the refusal itself is decided on every read.
#[tauri::command(async)]
pub fn addon_folder_env_notice(host: State<'_, Arc<AddonHost>>, id: PaneId) -> Result<Value, BrokerError> {
    let (root, network) = host.panes.registry.lock().unwrap().root_and_network(id).ok_or_else(|| BrokerError::new("not_granted", "no folder is allowed for this pane"))?;
    host.panes.refresh_deny();
    let scan = super::dotenv::scan_folder(&root, &host.panes.deny().snapshot());
    Ok(json!({ "found": scan.found, "truncated": scan.truncated, "network": network }))
}

#[tauri::command]
pub fn addon_revoke_root(host: State<'_, Arc<AddonHost>>, id: PaneId) {
    host.panes.registry.lock().unwrap().revoke_root(id);
}

fn to_feed(m: &crate::agmsg::Message) -> FeedMessage {
    FeedMessage { id: m.id.clone(), team: m.team.clone(), from: m.from.clone(), to: m.to.clone(), body: m.body.clone(), created_at: m.created_at.clone(), truncated: None }
}

/// History for the granted team plus whatever arrived while it was being built.
#[tauri::command(async)]
pub fn addon_feed_init(host: State<'_, Arc<AddonHost>>, id: PaneId, generation: u64) -> Result<Value, BrokerError> {
    let out = feed_init_inner(&host, id, generation);
    if out.is_err() {
        // a failed init must not leave a feed buffering messages for a frame that never got its init
        host.panes.feeds.lock().unwrap().remove(&(id, generation));
    }
    out
}

fn feed_init_inner(host: &AddonHost, id: PaneId, generation: u64) -> Result<Value, BrokerError> {
    let auth = host.panes.registry.lock().unwrap().authorize(id, generation, Need::Messages)?;
    let team = auth.team.clone().ok_or_else(|| BrokerError::new("not_granted", "no team is allowed for this pane"))?;
    // live messages queue from now on, so none falls between the history read and `finish`
    host.panes.feeds.lock().unwrap().insert((id, generation), Feed::begin(&team));
    let members = crate::agmsg::agmsg_members(team.clone()).map_err(|e| BrokerError::new("not_available", e))?;
    let members: Vec<(String, String)> = members.into_iter().map(|m| (m.name, m.types.into_iter().next().unwrap_or_else(|| "unknown".into()))).collect();
    let history = crate::agmsg::agmsg_messages(team.clone(), Some(feed::INIT_MAX_MESSAGES as u32), None).map_err(|e| BrokerError::new("not_available", e))?;
    let (init, ids) = feed::build_init(&team, &members, history.iter().map(to_feed).collect()).map_err(|e| BrokerError::new("init_too_large", e.message()))?;
    // the pane may have been revoked, reloaded or moved to another team while the
    // history was read: the same frame and the same team, or nothing is returned
    let again = host.panes.registry.lock().unwrap().authorize(id, generation, Need::Messages)?;
    if again.team.as_deref() != Some(team.as_str()) {
        return Err(BrokerError::new("not_granted", "the allowed team changed while the history was being read"));
    }
    let queued = {
        let mut feeds = host.panes.feeds.lock().unwrap();
        match feeds.get_mut(&(id, generation)) {
            Some(f) => f.finish(ids),
            None => return Err(BrokerError::new("not_granted", "this frame is not the pane's current one")),
        }
    };
    let queued: Vec<Value> = queued.iter().map(feed::message_event).collect();
    Ok(json!({ "init": init, "queued": queued }))
}

/// One request from the pane's port. The answer is ready to post back.
#[tauri::command(async)]
pub fn addon_request(host: State<'_, Arc<AddonHost>>, id: PaneId, generation: u64, op: String, args: Value) -> Value {
    let out = if broker::power_need(&op).is_some() {
        match super::agents::global() {
            Some(mgr) => broker::handle_power(&host.panes.registry, &host.panes.deny(), mgr, id, generation, &op, &args),
            None => Err(BrokerError::new("not_available", "the app is still starting")),
        }
    } else {
        broker::handle(&host.panes.registry, &host.panes.deny(), id, generation, &op, &args)
    };
    match out {
        Ok(result) => json!({ "agmsg": 1, "type": "response", "ok": true, "result": result }),
        Err(e) => json!({ "agmsg": 1, "type": "response", "ok": false, "error": { "code": e.code, "message": e.message } }),
    }
}

#[allow(dead_code)]
fn addon_request_plain(host: State<'_, Arc<AddonHost>>, id: PaneId, generation: u64, op: String, args: Value) -> Value {
    match broker::handle(&host.panes.registry, &host.panes.deny(), id, generation, &op, &args) {
        Ok(result) => json!({ "agmsg": 1, "type": "response", "ok": true, "result": result }),
        Err(e) => json!({ "agmsg": 1, "type": "response", "ok": false, "error": { "code": e.code, "message": e.message } }),
    }
}

/// Listens for the app's own `agmsg-message` events and pushes each to the panes
/// that read that team. Rust filters; the UI forwards.
pub fn listen_for_live_messages<R: Runtime>(app: &AppHandle<R>, host: Arc<AddonHost>) {
    let emit_app = app.clone();
    app.listen("agmsg-message", move |ev| {
        let Ok(m) = serde_json::from_str::<FeedMessage>(&strip_to_feed(ev.payload())) else { return };
        let targets = host.panes.registry.lock().unwrap().panes_reading_team(&m.team);
        for (pane, generation) in targets {
            let push = {
                let mut feeds = host.panes.feeds.lock().unwrap();
                feeds.get_mut(&(pane, generation)).and_then(|f| f.on_live(m.clone()))
            };
            if let Some(msg) = push {
                // re-check right before sending: the grant may have changed since
                if host.panes.registry.lock().unwrap().authorize(pane, generation, Need::Messages).is_ok() {
                    let _ = emit_app.emit(PUSH_EVENT, json!({ "pane": pane, "generation": generation, "event": feed::message_event(&msg) }));
                }
            }
        }
    });
}

/// The watcher's `Message` has exactly the feed fields; keep only those.
fn strip_to_feed(payload: &str) -> String {
    payload.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;
    use crate::addons::panes::Declared;
    use std::fs;
    use crate::addons::broker;

    fn conf_with(opens: &str, perms: &str) -> AddonConf {
        let mut t = String::from("title = T\nprotocol = 1\n");
        if !opens.is_empty() {
            t.push_str(&format!("opens = {opens}\n"));
        }
        if !perms.is_empty() {
            t.push_str(&format!("permissions = {perms}\n"));
        }
        crate::addons::conf::parse(&t, "c").conf.expect("valid conf")
    }

    fn args(path: Option<&str>, url: Option<&str>, base: Option<&str>) -> OpenArgs {
        OpenArgs { path: path.map(Into::into), url: url.map(Into::into), base: base.map(Into::into) }
    }

    #[test]
    fn open_args_must_be_declared_by_the_pane() {
        let none = conf_with("", "");
        assert!(validate_open_args(OpenArgs::default(), &none).is_ok(), "no args is always fine");
        assert!(validate_open_args(args(Some("/p"), None, None), &none).unwrap_err().starts_with("open_args_not_declared"));
        assert!(validate_open_args(args(None, Some("https://a"), None), &none).unwrap_err().starts_with("open_args_not_declared"));
        let path_only = conf_with("path", "files:read");
        assert!(validate_open_args(args(Some("/p"), None, None), &path_only).is_ok());
        assert!(validate_open_args(args(None, Some("https://a"), None), &path_only).unwrap_err().contains("does not accept a url"));
        let url_only = conf_with("url", "");
        assert!(validate_open_args(args(None, Some("https://a"), None), &url_only).is_ok());
        assert!(validate_open_args(args(Some("/p"), None, None), &url_only).unwrap_err().contains("does not accept a path"));
        let both = conf_with("path, url", "");
        assert!(validate_open_args(args(Some("/p"), Some("https://a"), None), &both).is_ok());
    }

    #[test]
    fn base_needs_a_path_and_git_read() {
        let no_git = conf_with("path", "files:read");
        assert!(validate_open_args(args(Some("/p"), None, Some("main")), &no_git).unwrap_err().contains("git:read"));
        let git = conf_with("path", "files:read, git:read");
        assert!(validate_open_args(args(Some("/p"), None, Some("main")), &git).is_ok());
        assert!(validate_open_args(args(None, None, Some("main")), &git).unwrap_err().contains("together with a path"));
        assert!(validate_open_args(args(Some("/p"), None, None), &git).is_ok());
    }

    #[test]
    fn open_args_are_bounded() {
        let c = conf_with("path", "");
        assert!(validate_open_args(args(Some(&"a".repeat(4097)), None, None), &c).unwrap_err().starts_with("open_args_invalid"));
        assert!(validate_open_args(args(Some("a\0b"), None, None), &c).unwrap_err().starts_with("open_args_invalid"));
        assert!(validate_open_args(args(Some(&"a".repeat(4096)), None, None), &c).is_ok());
    }

    #[test]
    fn grant_root_needs_an_absolute_existing_folder() {
        let deny = Denylist::from_process_env(Vec::new());
        let tmp = tempfile::tempdir().unwrap();
        let ok = grant_root_path(&deny, tmp.path().to_str().unwrap()).unwrap();
        assert_eq!(ok, tmp.path().canonicalize().unwrap());
        assert_eq!(grant_root_path(&deny, "relative/dir").unwrap_err().code, "bad_args");
        assert_eq!(grant_root_path(&deny, "").unwrap_err().code, "bad_args");
        assert_eq!(grant_root_path(&deny, tmp.path().join("nope").to_str().unwrap()).unwrap_err().code, "not_found");
        let f = tmp.path().join("file.txt");
        fs::write(&f, "x").unwrap();
        assert_eq!(grant_root_path(&deny, f.to_str().unwrap()).unwrap_err().code, "bad_args");
    }

    #[test]
    fn grant_root_refuses_protected_places_by_their_real_path() {
        let tmp = tempfile::tempdir().unwrap();
        let protected = tmp.path().join("keys");
        fs::create_dir_all(protected.join("sub")).unwrap();
        let deny = Denylist::from_process_env(vec![protected.canonicalize().unwrap()]);
        assert_eq!(grant_root_path(&deny, protected.to_str().unwrap()).unwrap_err().code, "denied_path");
        assert_eq!(grant_root_path(&deny, protected.join("sub").to_str().unwrap()).unwrap_err().code, "denied_path");
        #[cfg(unix)]
        {
            let link = tmp.path().join("innocent");
            std::os::unix::fs::symlink(&protected, &link).unwrap();
            assert_eq!(grant_root_path(&deny, link.to_str().unwrap()).unwrap_err().code, "denied_path");
        }
    }

    fn embedded_pane(panes: &Panes, addon: &str, name: &str) -> PaneId {
        let mut files = HashMap::new();
        files.insert("index.html".to_string(), b"x".to_vec());
        let declared = Declared { messages_read: true, files_read: true, ..Default::default() };
        panes
            .registry
            .lock()
            .unwrap()
            .add(AddPane { addon: addon.into(), commit: "c".into(), name: name.into(), payload: Payload::Embedded(files), entry: "index.html".into(), declared, open_args: OpenArgs::default(), expected_digest: None, pinned: None, on_tamper: None })
            .unwrap()
            .id
    }

    #[test]
    #[serial]
    fn revoke_voids_the_live_grant_closes_the_pane_and_reports_each_pane_once() {
        let nav = crate::addons::nav::NavPolicy::new(None);
        let panes = Panes::new();
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().canonicalize().unwrap();
        std::fs::write(root.join("f.txt"), "data").unwrap();
        let a = embedded_pane(&panes, "o/r", "main");
        let other_folder = embedded_pane(&panes, "o/r", "main");
        let other_addon = embedded_pane(&panes, "x/y", "main");
        let g = panes.registry.lock().unwrap().begin_generation(a).unwrap();
        panes.registry.lock().unwrap().grant_root(a, root.clone()).unwrap();
        let g2 = panes.registry.lock().unwrap().begin_generation(other_folder).unwrap();
        panes.registry.lock().unwrap().grant_root(other_folder, std::env::temp_dir()).unwrap();
        let g3 = panes.registry.lock().unwrap().begin_generation(other_addon).unwrap();
        panes.registry.lock().unwrap().grant_root(other_addon, root.clone()).unwrap();
        // before: the pane reads
        let deny = Denylist::from_process_env(Vec::new());
        let ok = broker::handle(&panes.registry, &deny, a, g, "fs.read", &json!({"path": "f.txt"}));
        assert_eq!(ok.unwrap()["text"], "data");
        // revoke that folder for that add-on
        let closed = panes.revoke_matching(&nav, "o/r", "main", "files:read", &root.to_string_lossy());
        assert_eq!(closed, vec![a], "exactly the pane that held the grant");
        let after = broker::handle(&panes.registry, &deny, a, g, "fs.read", &json!({"path": "f.txt"}));
        assert_eq!(after.unwrap_err().code, "not_granted");
        assert!(!panes.registry.lock().unwrap().contains(a));
        // a second revoke finds nothing: the UI is told once per pane
        assert!(panes.revoke_matching(&nav, "o/r", "main", "files:read", &root.to_string_lossy()).is_empty());
        // the other folder's pane and the other add-on's pane are untouched
        assert!(broker::handle(&panes.registry, &deny, other_folder, g2, "open.args", &json!({})).is_ok());
        assert!(broker::handle(&panes.registry, &deny, other_addon, g3, "fs.read", &json!({"path": "f.txt"})).is_ok());
    }

    #[test]
    #[serial]
    fn revoking_a_team_stops_pushes_and_closes_the_pane() {
        let nav = crate::addons::nav::NavPolicy::new(None);
        let panes = Panes::new();
        let a = embedded_pane(&panes, "o/r", "main");
        let g = panes.registry.lock().unwrap().begin_generation(a).unwrap();
        panes.registry.lock().unwrap().grant_team(a, "team-a").unwrap();
        panes.feeds.lock().unwrap().insert((a, g), Feed::begin("team-a"));
        assert_eq!(panes.registry.lock().unwrap().panes_reading_team("team-a"), vec![(a, g)]);
        let closed = panes.revoke_matching(&nav, "o/r", "main", "messages:read", "team-a");
        assert_eq!(closed, vec![a]);
        assert!(panes.registry.lock().unwrap().panes_reading_team("team-a").is_empty());
        assert!(panes.feeds.lock().unwrap().is_empty(), "the feed is dropped with the pane");
    }

    #[test]
    #[serial]
    fn a_grant_for_another_scope_or_pane_name_revokes_nothing() {
        let nav = crate::addons::nav::NavPolicy::new(None);
        let panes = Panes::new();
        let a = embedded_pane(&panes, "o/r", "main");
        panes.registry.lock().unwrap().begin_generation(a).unwrap();
        panes.registry.lock().unwrap().grant_team(a, "team-a").unwrap();
        assert!(panes.revoke_matching(&nav, "o/r", "main", "messages:read", "team-b").is_empty());
        assert!(panes.revoke_matching(&nav, "o/r", "other-pane", "messages:read", "team-a").is_empty());
        assert!(panes.revoke_matching(&nav, "o/r", "main", "git:read", "team-a").is_empty());
        assert!(panes.registry.lock().unwrap().contains(a));
    }

    #[test]
    #[serial]
    fn close_all_voids_panes_and_feeds() {
        use std::collections::HashMap;
        let panes = Panes::new();
        let mut files = HashMap::new();
        files.insert("index.html".to_string(), b"x".to_vec());
        let a = panes
            .registry
            .lock()
            .unwrap()
            .add(AddPane { addon: "o/r".into(), commit: "c".into(), name: "n".into(), payload: Payload::Embedded(files), entry: "index.html".into(), declared: Declared::default(), open_args: OpenArgs::default(), expected_digest: None, pinned: None, on_tamper: None })
            .unwrap();
        let g = panes.registry.lock().unwrap().begin_generation(a.id).unwrap();
        panes.feeds.lock().unwrap().insert((a.id, g), Feed::begin("t"));
        let closed = panes.close_all();
        assert_eq!(closed, vec![(a.port, a.token.clone())]);
        assert!(panes.feeds.lock().unwrap().is_empty());
        assert!(panes.registry.lock().unwrap().authorize(a.id, g, Need::Current).is_err());
        assert!(panes.close_all().is_empty());
    }
}
