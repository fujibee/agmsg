//! Commands for installing, updating and removing add-ons, and for the
//! developer's "Load from folder" (design 3). Like `commands`, all of them are
//! behind the app ACL (main window only).
//!
//! Shapes (JSON, camelCase):
//! - `addon_install_start({source, opId?}) → Confirm` (see `stage::Confirm`); the files are
//!   downloaded, checked and staged but not installed; progress arrives as event
//!   `addon-install-progress {opId, step: resolving|downloading|checking, detail}`.
//!   Errors are `{code, message}` with the message of the install failure table.
//! - `addon_install_confirm({stagingId}) → {id, repo, sha, closedPanes}`; `addon_install_cancel({stagingId})`
//! - `addon_check_update({id, opId?}) → Confirm` for an installed add-on (default branch),
//!   or `{code: "up_to_date", message: "Up to date (abc1234)."}`
//! - `addon_remove({id})`; `addon_dev_load({path}) → DevEntry`; `addon_dev_remove({id})`
//! - `addon_saved_grants({id, pane})`, `addon_save_grant({id, pane, permission, scope})`,
//!   `addon_forget_grant({id, pane, permission, scope})`: remembered "Always for this folder" /
//!   team grants (never for developer copies).

use serde::{Deserialize, Serialize};
use serde_json::json;
use std::sync::Arc;
use tauri::{AppHandle, Emitter, Runtime, State};

use super::commands::PANE_FAILED_EVENT;
use super::denylist::GrantCheck;
use super::host::AddonHost;
use super::index;
use super::install::dev::{self, DevEntry};
use super::install::extract::Limits;
use super::install::github::{parse_source, Github};
use super::install::grants::{self, SavedGrant};
use super::install::stage::{self, short_sha, Confirm, Failure};

pub const PROGRESS_EVENT: &str = "addon-install-progress";
pub const UPDATED_EVENT: &str = "addon-updated";
const APP_VERSION: &str = env!("CARGO_PKG_VERSION");
const MAX_STAGED: usize = 4;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallStartIn {
    pub source: String,
    #[serde(default)]
    pub op_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateIn {
    pub id: String,
    #[serde(default)]
    pub op_id: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StagingIn {
    pub staging_id: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InstallDone {
    pub id: String,
    pub repo: String,
    pub sha: String,
    pub previous_sha: Option<String>,
    pub closed_panes: Vec<u64>,
}

fn progress<R: Runtime>(app: &AppHandle<R>, op: &Option<String>, step: &str, detail: &str) {
    let _ = app.emit(PROGRESS_EVENT, json!({ "opId": op, "step": step, "detail": detail }));
}

fn now_iso() -> String {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    super::broker::iso8601(secs)
}

/// Resolve → download → stage, for any source. `installed_sha` makes an
/// already-installed commit an "up to date"/"already installed" answer before downloading.
fn fetch_and_stage<R: Runtime>(app: &AppHandle<R>, host: &AddonHost, source: &str, op: &Option<String>, update_of: Option<&str>) -> Result<Confirm, Failure> {
    let src = parse_source(source)?;
    let gh = Github::new(&format!("agmsg-app/{APP_VERSION}"))?;
    progress(app, op, "resolving", &src.slug());
    let sha = gh.resolve(&src)?;
    progress(app, op, "resolving", &format!("commit {}", short_sha(&sha)));
    let addons = host.catalog().addons_dir().to_path_buf();
    let previous = index::read(&addons).into_iter().find(|e| e.repo == src.slug());
    if let Some(p) = &previous {
        if p.sha == sha {
            return Err(if update_of.is_some() {
                Failure { code: "up_to_date", message: format!("Up to date ({}).", short_sha(&sha)) }
            } else {
                Failure { code: "already_installed", message: format!("Already installed ({}).", short_sha(&sha)) }
            });
        }
    }
    progress(app, op, "downloading", "");
    let body = gh.download(&src, &sha)?;
    progress(app, op, "checking", "");
    let staged = stage::stage(&addons, &src.slug(), &sha, body, APP_VERSION, Limits::default())?;
    let prev = previous.as_ref().map(|p| stage::Previous::load(&addons, p));
    let confirm = staged.confirm_data(prev.as_ref());
    let mut map = host.staged.lock().unwrap();
    // one staged install per add-on, and a bounded number overall
    let same: Vec<String> = map.iter().filter(|(_, s)| s.repo == staged.repo).map(|(k, _)| k.clone()).collect();
    for k in same {
        if let Some(old) = map.remove(&k) {
            stage::discard(&old);
        }
    }
    while map.len() >= MAX_STAGED {
        if let Some(k) = map.keys().next().cloned() {
            if let Some(old) = map.remove(&k) {
                stage::discard(&old);
            }
        }
    }
    map.insert(staged.id.clone(), staged);
    Ok(confirm)
}

#[tauri::command(async)]
pub fn addon_install_start<R: Runtime>(app: AppHandle<R>, host: State<'_, Arc<AddonHost>>, spec: InstallStartIn) -> Result<Confirm, Failure> {
    let _one_at_a_time = host.install_lock.lock().unwrap();
    fetch_and_stage(&app, &host, &spec.source, &spec.op_id, None)
}

#[tauri::command(async)]
pub fn addon_check_update<R: Runtime>(app: AppHandle<R>, host: State<'_, Arc<AddonHost>>, spec: UpdateIn) -> Result<Confirm, Failure> {
    let _one_at_a_time = host.install_lock.lock().unwrap();
    let installed = index::read(host.catalog().addons_dir()).into_iter().any(|e| e.repo == spec.id);
    if !installed {
        return Err(Failure { code: "not_found", message: "That add-on is not installed.".into() });
    }
    fetch_and_stage(&app, &host, &spec.id, &spec.op_id, Some(&spec.id))
}

/// Closes every open pane of `addon` (an update or a removal ends them) and tells the UI.
fn close_panes_of<R: Runtime>(app: &AppHandle<R>, host: &AddonHost, addon: &str, reason: &str) -> Vec<u64> {
    let ids = host.panes.registry.lock().unwrap().ids_for_addon(addon);
    for id in &ids {
        let closed = host.panes.registry.lock().unwrap().remove(*id);
        if let Some((port, token)) = closed {
            host.nav.unregister_pane(port, &token);
        }
        host.panes.feeds.lock().unwrap().retain(|(p, _), _| p != id);
        let _ = app.emit(PANE_FAILED_EVENT, json!({ "pane": id, "reason": reason }));
    }
    ids
}

#[tauri::command(async)]
pub fn addon_install_confirm<R: Runtime>(app: AppHandle<R>, host: State<'_, Arc<AddonHost>>, spec: StagingIn) -> Result<InstallDone, Failure> {
    let _one_at_a_time = host.install_lock.lock().unwrap();
    let staged = host.staged.lock().unwrap().remove(&spec.staging_id).ok_or_else(|| Failure { code: "not_found", message: "That install is no longer waiting. Start it again.".into() })?;
    let addons = host.catalog().addons_dir().to_path_buf();
    let done = stage::activate(&addons, &staged, &now_iso())?;
    // an update ends the open panes of the old version; the UI reopens them (and asks again where it must)
    let closed = if done.previous.is_some() { close_panes_of(&app, &host, &staged.repo, "This add-on was updated. Open it again.") } else { Vec::new() };
    let _ = app.emit(UPDATED_EVENT, json!({ "id": staged.repo, "sha": staged.sha, "closedPanes": closed }));
    Ok(InstallDone { id: staged.repo.clone(), repo: staged.repo.clone(), sha: staged.sha.clone(), previous_sha: done.previous.map(|p| p.sha), closed_panes: closed })
}

#[tauri::command]
pub fn addon_install_cancel(host: State<'_, Arc<AddonHost>>, spec: StagingIn) {
    if let Some(s) = host.staged.lock().unwrap().remove(&spec.staging_id) {
        stage::discard(&s);
    }
}

#[derive(Debug, Deserialize)]
pub struct IdIn {
    pub id: String,
}

#[tauri::command(async)]
pub fn addon_remove<R: Runtime>(app: AppHandle<R>, host: State<'_, Arc<AddonHost>>, spec: IdIn) -> Result<(), Failure> {
    let _one_at_a_time = host.install_lock.lock().unwrap();
    if spec.id.starts_with("builtin:") || spec.id.starts_with("dev:") {
        return Err(Failure { code: "bad_args", message: "Built-in add-ons cannot be removed.".into() });
    }
    close_panes_of(&app, &host, &spec.id, "This add-on was removed.");
    stage::remove(host.catalog().addons_dir(), &spec.id)?;
    let _ = app.emit(UPDATED_EVENT, json!({ "id": spec.id, "removed": true }));
    Ok(())
}

#[derive(Debug, Deserialize)]
pub struct PathIn {
    pub path: String,
}

#[tauri::command(async)]
pub fn addon_dev_load<R: Runtime>(app: AppHandle<R>, host: State<'_, Arc<AddonHost>>, spec: PathIn) -> Result<DevEntry, Failure> {
    let _one_at_a_time = host.install_lock.lock().unwrap();
    host.panes.refresh_deny();
    // a developer folder is a folder the add-on machinery reads: the protected places are off limits here too
    let real = std::fs::canonicalize(&spec.path).map_err(|_| Failure { code: "not_found", message: format!("{} no longer exists.", spec.path) })?;
    if let GrantCheck::Denied(_) = host.panes.deny().check_grant_root(&real) {
        return Err(Failure { code: "denied_path", message: super::denylist::refusal_message(&real) });
    }
    let addons = host.catalog().addons_dir().to_path_buf();
    let existing = host.catalog().dev_entries();
    let entry = dev::load(&addons, &real, &existing, Limits::default())?;
    // a reload replaces the copy under any open pane: those panes end
    if existing.iter().any(|e| e.id == entry.id) {
        close_panes_of(&app, &host, &entry.id, "Reloaded from the folder. Open it again.");
    }
    host.catalog().dev_put(entry.clone());
    let _ = app.emit(UPDATED_EVENT, json!({ "id": entry.id }));
    Ok(entry)
}

#[tauri::command(async)]
pub fn addon_dev_remove<R: Runtime>(app: AppHandle<R>, host: State<'_, Arc<AddonHost>>, spec: IdIn) -> Result<(), Failure> {
    let _one_at_a_time = host.install_lock.lock().unwrap();
    close_panes_of(&app, &host, &spec.id, "This developer add-on was removed.");
    match host.catalog().dev_remove(&spec.id) {
        Some(e) => {
            let _ = std::fs::remove_dir_all(&e.tree_root);
            let _ = app.emit(UPDATED_EVENT, json!({ "id": spec.id, "removed": true }));
            Ok(())
        }
        None => Err(Failure { code: "not_found", message: "That developer add-on is not loaded.".into() }),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GrantIn {
    pub id: String,
    pub pane: String,
    #[serde(default)]
    pub permission: String,
    #[serde(default)]
    pub scope: String,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SavedGrantOut {
    pub permission: String,
    pub scope: String,
    pub granted_at: String,
}

#[tauri::command]
pub fn addon_saved_grants(host: State<'_, Arc<AddonHost>>, spec: GrantIn) -> Vec<SavedGrantOut> {
    grants::for_pane(host.catalog().addons_dir(), &spec.id, &spec.pane).into_iter().map(|g| SavedGrantOut { permission: g.permission, scope: g.scope, granted_at: g.granted_at }).collect()
}

/// Remembering a grant is bound to the pane instance and the commit the user
/// consented under, and to what that pane actually holds right now.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SaveGrantIn {
    pub id: String,
    pub pane: String,
    pub permission: String,
    pub scope: String,
    /// The pane instance the user clicked Allow in.
    pub pane_id: u64,
    /// The add-on commit that pane runs (`addon_pane_add` returned it as `commit`).
    pub commit: String,
}

/// Checks a save against the live pane and the catalog; returns what to store.
pub fn check_save(host: &AddonHost, spec: &SaveGrantIn) -> Result<SavedGrant, Failure> {
    if spec.id.starts_with("dev:") {
        return Err(Failure { code: "bad_args", message: "Developer grants last until the app quits and are never saved.".into() });
    }
    let gone = || Failure { code: "pane_gone", message: "That pane is closed, so its permission was not saved.".into() };
    let v = host.panes.registry.lock().unwrap().consent_view(spec.pane_id).ok_or_else(gone)?;
    let (addon, pane, commit, team, root) = (v.addon, v.pane, v.commit, v.team, v.root);
    if addon != spec.id || pane != spec.pane {
        return Err(Failure { code: "pane_gone", message: "That pane is not this add-on's pane.".into() });
    }
    if commit != spec.commit {
        return Err(Failure { code: "commit_changed", message: "This add-on changed after you allowed it. Allow it again to remember it.".into() });
    }
    let info = host.catalog().list().into_iter().find(|a| a.id == spec.id).ok_or_else(|| Failure { code: "not_found", message: "No such add-on.".into() })?;
    if info.commit != spec.commit {
        return Err(Failure { code: "commit_changed", message: "This add-on was updated after you allowed it. Allow it again to remember it.".into() });
    }
    let declared = info.panes.iter().find(|p| p.name == spec.pane).ok_or_else(|| Failure { code: "not_found", message: "No such pane.".into() })?;
    if !declared.permissions.contains(&spec.permission) {
        return Err(Failure { code: "not_declared", message: "This add-on did not declare that permission.".into() });
    }
    // only what the pane really holds can be remembered
    let held = match spec.permission.as_str() {
        "files:read" => root.as_deref() == Some(spec.scope.as_str()),
        "messages:read" => team.as_deref() == Some(spec.scope.as_str()),
        _ => false,
    };
    if !held {
        return Err(Failure { code: "not_granted", message: "That pane does not hold that permission, so nothing was saved.".into() });
    }
    Ok(SavedGrant { repo: spec.id.clone(), sha: spec.commit.clone(), pane: spec.pane.clone(), permission: spec.permission.clone(), scope: spec.scope.clone(), granted_at: now_iso() })
}

#[tauri::command]
pub fn addon_save_grant(host: State<'_, Arc<AddonHost>>, spec: SaveGrantIn) -> Result<(), Failure> {
    let g = check_save(&host, &spec)?;
    grants::add(host.catalog().addons_dir(), g).map_err(|e| Failure { code: "bad_args", message: format!("That grant cannot be saved: {e}") })
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ForgetOut {
    pub forgotten: bool,
    pub closed_panes: Vec<u64>,
}

/// Settings → Revoke: forgets the remembered grant AND takes it away from every
/// live pane that holds it (they lose access at once and are closed; the UI gets
/// `addon-pane-failed {pane, reason}` once per pane).
#[tauri::command]
pub fn addon_forget_grant<R: Runtime>(app: AppHandle<R>, host: State<'_, Arc<AddonHost>>, spec: GrantIn) -> Result<ForgetOut, Failure> {
    let forgotten = grants::revoke(host.catalog().addons_dir(), &spec.id, &spec.pane, &spec.permission, &spec.scope).map_err(|e| Failure { code: "io", message: e.to_string() })?;
    let closed = host.panes.revoke_matching(&host.nav, &spec.id, &spec.pane, &spec.permission, &spec.scope);
    for id in &closed {
        let _ = app.emit(PANE_FAILED_EVENT, json!({ "pane": id, "reason": "Permission revoked. Open it again." }));
    }
    Ok(ForgetOut { forgotten, closed_panes: closed })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::addons::catalog::Catalog;
    use crate::addons::install::testutil::tarball;
    use crate::addons::panes::{AddPane, Declared, OpenArgs};
    use crate::addons::server::Payload;
    use std::collections::HashMap;

    const SHA1: &str = "1111111111111111111111111111111111111111";
    const SHA2: &str = "2222222222222222222222222222222222222222";

    fn install(addons: &std::path::Path, sha: &str) {
        let tar = tarball(&[
            json!({"path": "agmsg-plugin.conf", "type": "file", "text": "name = x\n"}),
            json!({"path": "app-panes/main/addon.conf", "type": "file", "text": "title = M\nprotocol = 1\npermissions = files:read, messages:read\nwhy.files:read = r\nwhy.messages:read = m\n"}),
            json!({"path": "app-panes/main/web/index.html", "type": "file", "text": "<div></div>"}),
        ]);
        let s = stage::stage(addons, "o/r", sha, &tar[..], "0.5.0", Limits::default()).unwrap();
        stage::activate(addons, &s, "t").unwrap();
    }

    fn host_with(addons: &std::path::Path) -> Arc<AddonHost> {
        let h = Arc::new(AddonHost::new(None));
        h.set_catalog_for_test(Catalog::new(None, addons.to_path_buf()));
        h
    }

    fn open_pane(h: &AddonHost, commit: &str, root: Option<&str>, team: Option<&str>) -> u64 {
        let mut files = HashMap::new();
        files.insert("index.html".to_string(), b"x".to_vec());
        let declared = Declared { messages_read: true, files_read: true, ..Default::default() };
        let mut reg = h.panes.registry.lock().unwrap();
        let id = reg
            .add(AddPane { addon: "o/r".into(), commit: commit.into(), name: "main".into(), payload: Payload::Embedded(files), entry: "index.html".into(), declared, open_args: OpenArgs::default(), expected_digest: None, pinned: None, on_tamper: None })
            .unwrap()
            .id;
        reg.begin_generation(id);
        if let Some(r) = root {
            reg.grant_root(id, std::path::PathBuf::from(r)).unwrap();
        }
        if let Some(t) = team {
            reg.grant_team(id, t).unwrap();
        }
        id
    }

    fn save(id: &str, pane_id: u64, commit: &str, perm: &str, scope: &str) -> SaveGrantIn {
        SaveGrantIn { id: id.into(), pane: "main".into(), permission: perm.into(), scope: scope.into(), pane_id, commit: commit.into() }
    }

    #[test]
    fn a_save_is_bound_to_the_pane_instance_the_commit_and_what_it_holds() {
        let d = tempfile::tempdir().unwrap();
        install(d.path(), SHA1);
        let h = host_with(d.path());
        let p = open_pane(&h, SHA1, Some("/proj"), Some("team-a"));
        let g = check_save(&h, &save("o/r", p, SHA1, "files:read", "/proj")).unwrap();
        assert_eq!((g.repo.as_str(), g.sha.as_str(), g.scope.as_str()), ("o/r", SHA1, "/proj"));
        assert!(check_save(&h, &save("o/r", p, SHA1, "messages:read", "team-a")).is_ok());
        // what the pane does not hold cannot be remembered
        assert_eq!(check_save(&h, &save("o/r", p, SHA1, "files:read", "/elsewhere")).unwrap_err().code, "not_granted");
        assert_eq!(check_save(&h, &save("o/r", p, SHA1, "messages:read", "team-b")).unwrap_err().code, "not_granted");
        assert_eq!(check_save(&h, &save("o/r", p, SHA1, "git:read", "/proj")).unwrap_err().code, "not_declared");
        // a pane that never existed, or belongs to another add-on id
        assert_eq!(check_save(&h, &save("o/r", p + 99, SHA1, "files:read", "/proj")).unwrap_err().code, "pane_gone");
        assert_eq!(check_save(&h, &save("x/y", p, SHA1, "files:read", "/proj")).unwrap_err().code, "pane_gone");
        // developer add-ons are never saved
        assert_eq!(check_save(&h, &save("dev:thing", p, SHA1, "files:read", "/proj")).unwrap_err().code, "bad_args");
    }

    #[test]
    fn consent_given_under_an_old_commit_cannot_be_attached_to_the_new_one() {
        let d = tempfile::tempdir().unwrap();
        install(d.path(), SHA1);
        let h = host_with(d.path());
        let old_pane = open_pane(&h, SHA1, Some("/proj"), None);
        // the add-on is updated while the old pane's Allow is still in flight
        let tar_dir = d.path();
        install(tar_dir, SHA2);
        // the old consent names SHA1: the catalog now says SHA2
        let e = check_save(&h, &save("o/r", old_pane, SHA1, "files:read", "/proj")).unwrap_err();
        assert_eq!(e.code, "commit_changed");
        // a save that claims the new commit for the old pane is refused too
        let e = check_save(&h, &save("o/r", old_pane, SHA2, "files:read", "/proj")).unwrap_err();
        assert_eq!(e.code, "commit_changed");
        assert!(grants::read(d.path()).is_empty(), "nothing was written");
        // a pane opened after the update, under the new commit, can save
        let new_pane = open_pane(&h, SHA2, Some("/proj"), None);
        assert!(check_save(&h, &save("o/r", new_pane, SHA2, "files:read", "/proj")).is_ok());
    }

    #[test]
    fn a_closed_pane_cannot_save() {
        let d = tempfile::tempdir().unwrap();
        install(d.path(), SHA1);
        let h = host_with(d.path());
        let p = open_pane(&h, SHA1, Some("/proj"), None);
        h.panes.registry.lock().unwrap().remove(p);
        assert_eq!(check_save(&h, &save("o/r", p, SHA1, "files:read", "/proj")).unwrap_err().code, "pane_gone");
    }
}
