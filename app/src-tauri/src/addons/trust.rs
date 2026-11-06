//! Folder trust for the agents an add-on starts (agents:spawn).
//!
//! Claude Code asks once per folder whether to trust it. The agents an add-on starts live under
//! `~/agmsg-agents`, which is outside any repository, so one acceptance covers every subdirectory (apart from a git
//! repository nested inside it; see the "Outside a repository" paragraph of code.claude.com/docs/en/permissions.md,
//! which also says `hasTrustDialogAccepted` can be set by hand). When the user ticked "trust ~/agmsg-agents in Claude
//! Code" at grant time, the app sets exactly that one key for that one folder, in the config the agents will see:
//! `$CLAUDE_CONFIG_DIR/.claude.json` when `CLAUDE_CONFIG_DIR` is set, else `~/.claude.json`.
//!
//! Everything else in the file is kept (a JSON round trip that keeps unknown keys and their order); the new file is
//! written beside the old one and renamed over it; a missing file is never created.

use serde::Serialize;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum Trust {
    #[serde(rename = "trusted")]
    Trusted,
    #[serde(rename = "not trusted")]
    NotTrusted,
    #[serde(rename = "config not found")]
    ConfigNotFound,
}

/// The Claude Code config the spawned agents will read.
pub fn config_path(config_dir: Option<&str>, home: &Path) -> PathBuf {
    match config_dir {
        Some(d) if !d.is_empty() => PathBuf::from(d).join(".claude.json"),
        _ => home.join(".claude.json"),
    }
}

/// `~/agmsg-agents` as the agents' working folders resolve it (created if missing, then canonical), refusing
/// anything that is not a folder of that name below the home folder: the home folder itself is never trusted here.
pub fn agents_folder(home: &Path) -> Result<PathBuf, String> {
    let dir = home.join("agmsg-agents");
    std::fs::create_dir_all(&dir).map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    let real = std::fs::canonicalize(&dir).map_err(|e| e.to_string())?;
    let home_real = std::fs::canonicalize(home).map_err(|e| e.to_string())?;
    if real == home_real || real.file_name().and_then(|n| n.to_str()) != Some("agmsg-agents") || real.parent() != Some(home_real.as_path()) {
        return Err("the agents' folder is not ~/agmsg-agents".into());
    }
    Ok(PathBuf::from(super::agents::plain_path_str(&real.to_string_lossy())))
}

fn key_of(folder: &Path) -> String {
    folder.to_string_lossy().into_owned()
}

fn read_config(config: &Path) -> Result<Option<Value>, String> {
    let text = match std::fs::read_to_string(config) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("cannot read {}: {e}", config.display())),
    };
    serde_json::from_str::<Value>(&text).map(Some).map_err(|e| format!("{} is not valid JSON, left as it is: {e}", config.display()))
}

/// Whether the folder is trusted in this config. Read only.
pub fn status(config: &Path, folder: &Path) -> Result<Trust, String> {
    let Some(v) = read_config(config)? else { return Ok(Trust::ConfigNotFound) };
    let on = v.get("projects").and_then(|p| p.get(key_of(folder))).and_then(|p| p.get("hasTrustDialogAccepted")).and_then(Value::as_bool) == Some(true);
    Ok(if on { Trust::Trusted } else { Trust::NotTrusted })
}

/// Sets `projects[<folder>].hasTrustDialogAccepted = true` and nothing else. A missing config is left missing.
///
/// Claude Code sessions rewrite this file often, so the read-modify-write can lose their change or be lost to it.
/// The window is kept small (read, change, write, rename with nothing in between), and after the rename the file is
/// read again: if our key is not there (another writer replaced the file meanwhile) the step is repeated, at most
/// three times, and then reported as an error. What stays: a change another session makes between our read and our
/// rename is lost; that cannot be closed without a lock Claude Code does not take.
pub fn trust(config: &Path, folder: &Path) -> Result<Trust, String> {
    let mut last = Ok(Trust::NotTrusted);
    for _ in 0..3 {
        last = trust_once(config, folder);
        match &last {
            Ok(Trust::Trusted) => {
                if status(config, folder)? == Trust::Trusted {
                    return last;
                }
            }
            _ => return last,
        }
    }
    let _ = last;
    Err(format!("{} was rewritten by another program each time; the trust setting did not stay", config.display()))
}

fn trust_once(config: &Path, folder: &Path) -> Result<Trust, String> {
    let Some(mut v) = read_config(config)? else { return Ok(Trust::ConfigNotFound) };
    let root = v.as_object_mut().ok_or_else(|| format!("{} is not a JSON object, left as it is", config.display()))?;
    let projects = root.entry("projects").or_insert_with(|| json!({}));
    let projects = projects.as_object_mut().ok_or_else(|| format!("\"projects\" in {} is not an object, left as it is", config.display()))?;
    let entry = projects.entry(key_of(folder)).or_insert_with(|| json!({}));
    let entry = entry.as_object_mut().ok_or_else(|| format!("the entry for {} in {} is not an object, left as it is", folder.display(), config.display()))?;
    if entry.get("hasTrustDialogAccepted").and_then(Value::as_bool) == Some(true) {
        return Ok(Trust::Trusted);
    }
    entry.insert("hasTrustDialogAccepted".into(), Value::Bool(true));
    let mut out = serde_json::to_string_pretty(&v).map_err(|e| e.to_string())?;
    out.push('\n');
    let tmp = config.with_file_name(format!(".claude.json.agmsg-{}.tmp", std::process::id()));
    std::fs::write(&tmp, out).map_err(|e| format!("cannot write beside {}: {e}", config.display()))?;
    if let Ok(md) = std::fs::metadata(config) {
        let _ = std::fs::set_permissions(&tmp, md.permissions());
    }
    if let Err(e) = std::fs::rename(&tmp, config) {
        let _ = std::fs::remove_file(&tmp);
        return Err(format!("cannot replace {}: {e}", config.display()));
    }
    Ok(Trust::Trusted)
}

fn resolve() -> Result<(PathBuf, PathBuf), String> {
    let home = crate::agmsg::home_dir_string().map(PathBuf::from).ok_or("the home folder is not known")?;
    let folder = agents_folder(&home)?;
    let cfg = std::env::var("CLAUDE_CONFIG_DIR").ok();
    Ok((config_path(cfg.as_deref(), &home), folder))
}

/// Whether `~/agmsg-agents` is trusted in the config the agents will use (for the settings and the grant card).
#[tauri::command]
pub fn addon_agents_folder_trust() -> Result<Trust, super::panes::BrokerError> {
    let (cfg, folder) = resolve().map_err(|e| super::panes::BrokerError::new("not_available", e))?;
    status(&cfg, &folder).map_err(|e| super::panes::BrokerError::new("not_available", e))
}

/// Called by the app from the saved consent when the user ticked the box; an add-on frame cannot call it.
/// Only for an add-on that declares `agents:spawn`.
#[tauri::command]
pub fn addon_trust_agents_folder(host: tauri::State<'_, std::sync::Arc<super::host::AddonHost>>, addon: String) -> Result<Trust, super::panes::BrokerError> {
    use super::panes::BrokerError;
    let info = host.catalog().list().into_iter().find(|a| a.id == addon).ok_or_else(|| BrokerError::new("not_found", "No such add-on."))?;
    if !info.panes.iter().any(|p| p.permissions.iter().any(|x| x == "agents:spawn")) {
        return Err(BrokerError::new("not_declared", "This add-on did not declare agents:spawn."));
    }
    let (cfg, folder) = resolve().map_err(|e| BrokerError::new("not_available", e))?;
    trust(&cfg, &folder).map_err(|e| BrokerError::new("not_available", e))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(dir: &Path, text: &str) -> PathBuf {
        let p = dir.join(".claude.json");
        std::fs::write(&p, text).unwrap();
        p
    }

    #[test]
    fn the_config_is_the_one_the_agents_will_see() {
        let home = Path::new("/h");
        assert_eq!(config_path(Some("/acct"), home), Path::new("/acct/.claude.json"));
        assert_eq!(config_path(Some(""), home), Path::new("/h/.claude.json"));
        assert_eq!(config_path(None, home), Path::new("/h/.claude.json"));
    }

    #[test]
    fn only_the_agents_folder_below_home_is_ever_named() {
        let t = tempfile::tempdir().unwrap();
        let home = t.path().canonicalize().unwrap();
        let f = agents_folder(&home).unwrap();
        // on Windows `canonicalize` gives the verbatim form, which is dropped from what the app names
        let plain = |p: &Path| PathBuf::from(crate::addons::agents::plain_path_str(&p.to_string_lossy()));
        assert_eq!(f, plain(&home.join("agmsg-agents")));
        assert_ne!(f, plain(&home));
    }

    #[test]
    fn sets_one_key_and_keeps_everything_else_in_order() {
        let t = tempfile::tempdir().unwrap();
        let folder = t.path().join("agmsg-agents");
        let original = format!(
            "{{\n  \"zeta\": 1,\n  \"numStartups\": 12345678901234,\n  \"projects\": {{\n    \"/other\": {{ \"hasTrustDialogAccepted\": false, \"allowedTools\": [\"x\"], \"future\": {{ \"a\": null }} }},\n    {}: {{ \"allowedTools\": [], \"history\": [1, 2] }}\n  }},\n  \"alpha\": [true, 1.5, \"s\"]\n}}\n",
            serde_json::to_string(&key_of(&folder)).unwrap()
        );
        let c = cfg(t.path(), &original);
        assert_eq!(status(&c, &folder).unwrap(), Trust::NotTrusted);
        assert_eq!(trust(&c, &folder).unwrap(), Trust::Trusted);
        assert_eq!(status(&c, &folder).unwrap(), Trust::Trusted);
        let after: Value = serde_json::from_str(&std::fs::read_to_string(&c).unwrap()).unwrap();
        let mut expect: Value = serde_json::from_str(&original).unwrap();
        expect["projects"][key_of(&folder)]["hasTrustDialogAccepted"] = Value::Bool(true);
        assert_eq!(after, expect, "the only difference is the one key");
        assert_eq!(after["projects"]["/other"]["hasTrustDialogAccepted"], false, "another folder is untouched");
        let order: Vec<&String> = after.as_object().unwrap().keys().collect();
        assert_eq!(order, ["zeta", "numStartups", "projects", "alpha"], "the order of the keys is kept");
        assert_eq!(after["numStartups"], 12345678901234u64);
        // nothing is left beside it
        let left: Vec<_> = std::fs::read_dir(t.path()).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        assert_eq!(left, [".claude.json"], "{left:?}");
    }

    #[test]
    fn adds_the_project_entry_and_is_idempotent() {
        let t = tempfile::tempdir().unwrap();
        let folder = t.path().join("agmsg-agents");
        let c = cfg(t.path(), "{\"theme\":\"dark\"}");
        trust(&c, &folder).unwrap();
        let once = std::fs::read_to_string(&c).unwrap();
        let v: Value = serde_json::from_str(&once).unwrap();
        assert_eq!(v["theme"], "dark");
        assert_eq!(v["projects"][key_of(&folder)], json!({ "hasTrustDialogAccepted": true }));
        trust(&c, &folder).unwrap();
        assert_eq!(std::fs::read_to_string(&c).unwrap(), once, "a second call changes nothing");
    }

    #[test]
    fn a_missing_config_is_not_created() {
        let t = tempfile::tempdir().unwrap();
        let c = t.path().join(".claude.json");
        assert_eq!(status(&c, &t.path().join("agmsg-agents")).unwrap(), Trust::ConfigNotFound);
        assert_eq!(trust(&c, &t.path().join("agmsg-agents")).unwrap(), Trust::ConfigNotFound);
        assert!(!c.exists());
    }

    #[test]
    fn a_config_that_is_not_what_we_expect_is_left_alone() {
        let t = tempfile::tempdir().unwrap();
        let folder = t.path().join("agmsg-agents");
        for text in ["not json", "[1,2]", "{\"projects\": 3}", &format!("{{\"projects\": {{{}: \"x\"}}}}", serde_json::to_string(&key_of(&folder)).unwrap())] {
            let c = cfg(t.path(), text);
            assert!(trust(&c, &folder).is_err(), "{text}");
            assert_eq!(std::fs::read_to_string(&c).unwrap(), text, "left as it was: {text}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn the_file_keeps_its_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let t = tempfile::tempdir().unwrap();
        let c = cfg(t.path(), "{}");
        std::fs::set_permissions(&c, std::fs::Permissions::from_mode(0o600)).unwrap();
        trust(&c, &t.path().join("agmsg-agents")).unwrap();
        assert_eq!(std::fs::metadata(&c).unwrap().permissions().mode() & 0o777, 0o600);
    }
}
