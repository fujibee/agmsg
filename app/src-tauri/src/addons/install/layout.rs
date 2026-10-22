//! The add-on layout checks of `npx agmsg addon check` on an extracted tree
//! (design 1): `app-panes/<name>/addon.conf` + `web/` with the entry present,
//! and a valid `addon.conf` per pane. Same wording as the CLI.

use std::fs;
use std::path::Path;

use crate::addons::conf::{self, AddonConf};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LayoutReport {
    pub errors: Vec<String>,
    pub warnings: Vec<String>,
    /// `(pane name, its conf)` for every pane that is valid.
    pub panes: Vec<(String, AddonConf)>,
    /// There is no `app-panes/` folder at all (the UI words this differently).
    pub no_app_panes: bool,
}

fn name_ok(n: &str) -> bool {
    // ^[a-z0-9][a-z0-9-]{0,63}$
    let b = n.as_bytes();
    !b.is_empty() && b.len() <= 64 && (b[0].is_ascii_lowercase() || b[0].is_ascii_digit()) && b.iter().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'-')
}

pub const NO_APP_PANES: &str = "No app add-on here (no app-panes/ folder). Run `npx agmsg addon init <name>` first.";

pub fn check_layout(root: &Path) -> LayoutReport {
    let mut r = LayoutReport::default();
    if !root.join("agmsg-plugin.conf").is_file() {
        r.warnings.push("No agmsg-plugin.conf at the repository root (name, description).".into());
    }
    let panes_dir = root.join("app-panes");
    if !panes_dir.is_dir() {
        r.errors.push(NO_APP_PANES.into());
        r.no_app_panes = true;
        return r;
    }
    let mut panes: Vec<String> = fs::read_dir(&panes_dir).map(|rd| rd.flatten().filter(|e| e.path().is_dir()).map(|e| e.file_name().to_string_lossy().into_owned()).collect()).unwrap_or_default();
    panes.sort();
    if panes.is_empty() {
        r.errors.push("app-panes/ has no add-on folder.".into());
    }
    for pane in panes {
        let rel = format!("app-panes/{pane}/addon.conf");
        if !name_ok(&pane) {
            r.errors.push(format!("app-panes/{pane}: names are lowercase letters, digits and \"-\"."));
        }
        let conf_path = root.join(&rel);
        if !conf_path.is_file() {
            r.errors.push(format!("{rel} is missing."));
            continue;
        }
        let text = fs::read_to_string(&conf_path).unwrap_or_default();
        let c = conf::parse(&text, &rel);
        r.errors.extend(c.errors.iter().cloned());
        r.warnings.extend(c.warnings);
        let entry_name = c.conf.as_ref().map(|c| c.entry.clone()).unwrap_or_else(|| "index.html".into());
        let entry = format!("app-panes/{pane}/web/{entry_name}");
        if !fs::symlink_metadata(root.join(&entry)).map(|m| m.is_file()).unwrap_or(false) {
            r.errors.push(format!("{entry} is missing. Add-ons must commit their built web/ folder."));
        } else if let Some(conf) = c.conf {
            if c.errors.is_empty() {
                r.panes.push((pane, conf));
            }
        }
    }
    r
}
