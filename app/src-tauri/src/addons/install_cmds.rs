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
    let confirm = staged.confirm_data(previous.as_ref());
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

fn rememberable(id: &str) -> Result<(), Failure> {
    if id.starts_with("dev:") {
        return Err(Failure { code: "bad_args", message: "Developer grants last until the app quits and are never saved.".into() });
    }
    Ok(())
}

#[tauri::command]
pub fn addon_saved_grants(host: State<'_, Arc<AddonHost>>, spec: GrantIn) -> Vec<SavedGrantOut> {
    grants::for_pane(host.catalog().addons_dir(), &spec.id, &spec.pane).into_iter().map(|g| SavedGrantOut { permission: g.permission, scope: g.scope, granted_at: g.granted_at }).collect()
}

#[tauri::command]
pub fn addon_save_grant(host: State<'_, Arc<AddonHost>>, spec: GrantIn) -> Result<(), Failure> {
    rememberable(&spec.id)?;
    let addons = host.catalog().addons_dir().to_path_buf();
    // only a pane that exists and declared the permission can have it remembered
    let info = host.catalog().list().into_iter().find(|a| a.id == spec.id).ok_or_else(|| Failure { code: "not_found", message: "No such add-on.".into() })?;
    let pane = info.panes.iter().find(|p| p.name == spec.pane).ok_or_else(|| Failure { code: "not_found", message: "No such pane.".into() })?;
    if !pane.permissions.contains(&spec.permission) {
        return Err(Failure { code: "not_declared", message: "This add-on did not declare that permission.".into() });
    }
    grants::add(&addons, SavedGrant { repo: spec.id, sha: info.commit, pane: spec.pane, permission: spec.permission, scope: spec.scope, granted_at: now_iso() })
        .map_err(|e| Failure { code: "bad_args", message: format!("That grant cannot be saved: {e}") })
}

#[tauri::command]
pub fn addon_forget_grant(host: State<'_, Arc<AddonHost>>, spec: GrantIn) -> Result<bool, Failure> {
    grants::revoke(host.catalog().addons_dir(), &spec.id, &spec.pane, &spec.permission, &spec.scope).map_err(|e| Failure { code: "io", message: e.to_string() })
}
