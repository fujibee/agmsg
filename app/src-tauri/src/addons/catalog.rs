//! What add-ons exist: the built-ins shipped inside the app bundle, the ones
//! installed under `<base>/addons` (from `index.tsv`), and developer copies.
//! The UI only ever sees ids and pane names, never a directory: `resolve` turns
//! `(id, pane)` into the pinned directory, after checking its digest.
//!
//! Built-ins are pinned by the app's own signature: their digest is computed at
//! build time (`build.rs`) from `app/addons/<name>/app-panes` and checked every
//! time one is listed or opened.

use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};

use super::conf::{self, AddonConf};
use super::digest;
use super::index::{self, IndexEntry};

include!(concat!(env!("OUT_DIR"), "/builtin_digests.rs"));

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PaneInfo {
    pub name: String,
    pub title: String,
    pub entry: String,
    pub permissions: Vec<String>,
    pub network: String,
    pub opens: Vec<String>,
    /// `why.<permission>` lines, for the permission dialog.
    pub why: std::collections::BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AddonInfo {
    /// `builtin:<name>` or `owner/repo`; opaque to the UI.
    pub id: String,
    /// `builtin` | `installed`
    pub kind: &'static str,
    /// `agmsg` for built-ins, `owner/repo` for installed ones.
    pub source: String,
    /// App version for built-ins, the commit SHA for installed ones.
    pub commit: String,
    pub title: String,
    pub panes: Vec<PaneInfo>,
    /// The files on disk hash to what was pinned. When false the add-on cannot be opened.
    pub digest_ok: bool,
    pub enabled: bool,
    /// Panes whose `addon.conf` was refused, in the words `check` uses.
    pub problems: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CatalogError {
    /// No such add-on or pane (or it is disabled).
    Unknown(String),
    /// The digest does not match: incomplete or changed after install.
    Changed(String),
    Invalid(String),
}

impl std::fmt::Display for CatalogError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CatalogError::Unknown(m) | CatalogError::Changed(m) | CatalogError::Invalid(m) => f.write_str(m),
        }
    }
}

/// A pane ready to be served. `pane_dir` holds `addon.conf` and `web/`.
#[derive(Debug, Clone)]
pub struct Resolved {
    pub addon: String,
    pub commit: String,
    pub pane: String,
    pub web_dir: PathBuf,
    pub conf: AddonConf,
}

pub struct Catalog {
    /// Where the built-ins live: `<resources>/builtin-addons` (falls back to the source tree in a dev build).
    builtin_root: Option<PathBuf>,
    /// `<base>/addons`.
    addons_dir: PathBuf,
}

fn pane_names(app_panes: &Path) -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(app_panes)
        .map(|rd| rd.flatten().filter(|e| e.path().is_dir()).map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    v.sort();
    v
}

fn read_panes(app_panes: &Path) -> (Vec<PaneInfo>, Vec<String>) {
    let mut panes = Vec::new();
    let mut problems = Vec::new();
    for name in pane_names(app_panes) {
        let rel = format!("app-panes/{name}/addon.conf");
        let Ok(text) = fs::read_to_string(app_panes.join(&name).join("addon.conf")) else {
            problems.push(format!("{rel} is missing."));
            continue;
        };
        let r = conf::parse(&text, &rel);
        problems.extend(r.errors);
        if let Some(c) = r.conf {
            // the entry must exist as a plain file under web/
            let entry = app_panes.join(&name).join("web").join(&c.entry);
            if !fs::symlink_metadata(&entry).map(|m| m.is_file()).unwrap_or(false) {
                problems.push(format!("app-panes/{name}/web/{} is missing. Add-ons must commit their built web/ folder.", c.entry));
                continue;
            }
            panes.push(PaneInfo { name, title: c.title.clone(), entry: c.entry.clone(), permissions: c.permissions.clone(), network: c.network.clone().unwrap_or_default(), opens: c.opens.clone(), why: c.why.clone() });
        }
    }
    (panes, problems)
}

impl Catalog {
    pub fn new(builtin_root: Option<PathBuf>, addons_dir: PathBuf) -> Catalog {
        Catalog { builtin_root, addons_dir }
    }

    /// The built-in root: the bundle's resources, or in a development build the
    /// source tree (`app/addons`) when the bundle copy is not there.
    pub fn locate_builtin_root(resource_dir: Option<PathBuf>) -> Option<PathBuf> {
        if let Some(r) = resource_dir.map(|r| r.join("builtin-addons")) {
            if r.is_dir() {
                return Some(r);
            }
        }
        if cfg!(debug_assertions) {
            return None;
        }
        None
    }

    fn builtin_pane_root(&self, name: &str) -> Option<PathBuf> {
        let root = self.builtin_root.as_ref()?.join(name);
        root.is_dir().then_some(root)
    }

    fn builtin_digest_ok(&self, name: &str, expected: &str) -> bool {
        match self.builtin_pane_root(name) {
            Some(dir) => digest::payload_digest(&dir).map(|d| d == expected).unwrap_or(false),
            None => false,
        }
    }

    pub fn list(&self) -> Vec<AddonInfo> {
        let mut out = Vec::new();
        for (name, expected) in BUILTIN_DIGESTS {
            let Some(dir) = self.builtin_pane_root(name) else { continue };
            let ok = self.builtin_digest_ok(name, expected);
            let (panes, problems) = if ok { read_panes(&dir) } else { (Vec::new(), vec!["its files are incomplete or were changed".to_string()]) };
            let title = panes.first().map(|p| p.title.clone()).unwrap_or_else(|| (*name).to_string());
            out.push(AddonInfo { id: format!("builtin:{name}"), kind: "builtin", source: "agmsg".into(), commit: env!("CARGO_PKG_VERSION").into(), title, panes, digest_ok: ok, enabled: true, problems });
        }
        for e in index::read(&self.addons_dir) {
            let dir = e.dir(&self.addons_dir);
            let ok = digest::payload_digest(&dir).map(|d| d == e.payload_digest).unwrap_or(false);
            let (panes, problems) = if ok { read_panes(&dir.join("app-panes")) } else { (Vec::new(), vec!["its files are incomplete or were changed after install".to_string()]) };
            let title = panes.first().map(|p| p.title.clone()).unwrap_or_else(|| e.repo.clone());
            out.push(AddonInfo { id: e.repo.clone(), kind: "installed", source: e.repo.clone(), commit: e.sha.clone(), title, panes, digest_ok: ok, enabled: e.enabled, problems });
        }
        out
    }

    /// `(id, pane)` → the directory to serve and what it declared. The digest
    /// is checked here, every time.
    pub fn resolve(&self, id: &str, pane: &str) -> Result<Resolved, CatalogError> {
        if !pane.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-') || pane.is_empty() {
            return Err(CatalogError::Unknown("no such pane".into()));
        }
        let (addon, commit, app_panes, tree_ok): (String, String, PathBuf, bool) = if let Some(name) = id.strip_prefix("builtin:") {
            let expected = BUILTIN_DIGESTS.iter().find(|(n, _)| *n == name).map(|(_, d)| *d).ok_or_else(|| CatalogError::Unknown("no such add-on".into()))?;
            let dir = self.builtin_pane_root(name).ok_or_else(|| CatalogError::Unknown("this build does not include that add-on".into()))?;
            (id.to_string(), env!("CARGO_PKG_VERSION").to_string(), dir.clone(), self.builtin_digest_ok(name, expected))
        } else {
            let e: IndexEntry = index::read(&self.addons_dir).into_iter().find(|e| e.repo == id).ok_or_else(|| CatalogError::Unknown("no such add-on".into()))?;
            if !e.enabled {
                return Err(CatalogError::Unknown("that add-on is turned off".into()));
            }
            let dir = e.dir(&self.addons_dir);
            let ok = digest::payload_digest(&dir).map(|d| d == e.payload_digest).unwrap_or(false);
            (e.repo.clone(), e.sha.clone(), dir.join("app-panes"), ok)
        };
        if !tree_ok {
            return Err(CatalogError::Changed("can't open: its files are incomplete or were changed after install".into()));
        }
        let pane_dir = app_panes.join(pane);
        let text = fs::read_to_string(pane_dir.join("addon.conf")).map_err(|_| CatalogError::Unknown("no such pane".into()))?;
        let r = conf::parse(&text, &format!("app-panes/{pane}/addon.conf"));
        let conf = r.conf.ok_or_else(|| CatalogError::Invalid(r.errors.join(" ")))?;
        Ok(Resolved { addon, commit, pane: pane.to_string(), web_dir: pane_dir.join("web"), conf })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_pane(app_panes: &Path, name: &str, conf_text: &str, with_web: bool) {
        let d = app_panes.join(name);
        fs::create_dir_all(d.join("web")).unwrap();
        fs::write(d.join("addon.conf"), conf_text).unwrap();
        if with_web {
            fs::write(d.join("web/index.html"), "<div></div>").unwrap();
        }
    }

    fn install(addons: &Path, repo: &str, sha_c: char, enabled: bool) -> IndexEntry {
        let mut e = IndexEntry {
            repo: repo.into(),
            sha: sha_c.to_string().repeat(40),
            archive_sha256: "a".repeat(64),
            payload_digest: "b".repeat(64),
            panes: vec!["main".into()],
            permissions: vec!["files:read".into()],
            network: String::new(),
            installed_at: "2026-10-23T00:00:00Z".into(),
            enabled,
        };
        let dir = e.dir(addons);
        write_pane(&dir.join("app-panes"), "main", "title=Main\nprotocol=1\npermissions=files:read\nwhy.files:read=reads\n", true);
        e.payload_digest = digest::payload_digest(&dir).unwrap();
        e
    }

    #[test]
    fn the_build_pins_the_shipped_builtins() {
        let names: Vec<&str> = BUILTIN_DIGESTS.iter().map(|(n, _)| *n).collect();
        assert!(names.contains(&"fileview") && names.contains(&"diffview"), "{names:?}");
        for (_, d) in BUILTIN_DIGESTS {
            assert_eq!(d.len(), 64);
        }
    }

    #[test]
    fn builtins_from_the_source_tree_match_their_build_time_digest() {
        // the source tree is exactly what build.rs hashed
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../addons");
        let tmp = tempfile::tempdir().unwrap();
        let cat = Catalog::new(None, tmp.path().to_path_buf());
        assert!(cat.list().is_empty(), "no builtin root, no built-ins");
        // simulate the bundle: <resources>/builtin-addons/<name> = app-panes of each
        let res = tmp.path().join("res/builtin-addons");
        for (name, _) in BUILTIN_DIGESTS {
            copy_dir(&root.join(name).join("app-panes"), &res.join(name));
        }
        let cat = Catalog::new(Some(res.clone()), tmp.path().join("addons"));
        let list = cat.list();
        assert_eq!(list.len(), BUILTIN_DIGESTS.len());
        for a in &list {
            assert!(a.digest_ok, "{} {:?}", a.id, a.problems);
            assert_eq!(a.kind, "builtin");
            assert!(!a.panes.is_empty(), "{}", a.id);
        }
        let f = list.iter().find(|a| a.id == "builtin:fileview").unwrap();
        assert_eq!(f.panes[0].permissions, vec!["files:read"]);
        assert_eq!(f.panes[0].opens, vec!["path"]);
        // one changed byte and the add-on cannot be opened
        fs::write(res.join("fileview/fileview/addon.conf"), "title=Evil\nprotocol=1\npermissions=files:read\n").unwrap();
        let list = cat.list();
        let f = list.iter().find(|a| a.id == "builtin:fileview").unwrap();
        assert!(!f.digest_ok && f.panes.is_empty());
        assert!(matches!(cat.resolve("builtin:fileview", "fileview"), Err(CatalogError::Changed(_))));
        assert!(cat.resolve("builtin:diffview", "diffview").is_ok());
    }

    fn copy_dir(from: &Path, to: &Path) {
        fs::create_dir_all(to).unwrap();
        for e in fs::read_dir(from).unwrap().flatten() {
            let (src, dst) = (e.path(), to.join(e.file_name()));
            if src.is_dir() {
                copy_dir(&src, &dst);
            } else {
                fs::copy(&src, &dst).unwrap();
            }
        }
    }

    #[test]
    fn installed_addons_come_from_the_index_and_are_pinned_by_their_digest() {
        let tmp = tempfile::tempdir().unwrap();
        let addons = tmp.path().join("addons");
        let a = install(&addons, "o/r", '1', true);
        let b = install(&addons, "x/y", '2', false);
        index::write(&addons, &[a.clone(), b.clone()]).unwrap();
        let cat = Catalog::new(None, addons.clone());
        let l = cat.list();
        assert_eq!(l.len(), 2);
        let la = l.iter().find(|x| x.id == "o/r").unwrap();
        assert!(la.digest_ok && la.enabled && la.kind == "installed");
        assert_eq!(la.commit, a.sha);
        assert_eq!(la.panes[0].name, "main");
        assert_eq!(la.panes[0].why["files:read"], "reads");
        assert!(!l.iter().find(|x| x.id == "x/y").unwrap().enabled);
        let r = cat.resolve("o/r", "main").unwrap();
        assert_eq!(r.web_dir, a.dir(&addons).join("app-panes/main/web"));
        assert_eq!(r.conf.permissions, vec!["files:read"]);
        assert!(matches!(cat.resolve("x/y", "main"), Err(CatalogError::Unknown(_))), "disabled add-ons do not open");
        assert!(matches!(cat.resolve("o/r", "nope"), Err(CatalogError::Unknown(_))));
        assert!(matches!(cat.resolve("nobody/none", "main"), Err(CatalogError::Unknown(_))));
        // a half-written / changed directory never opens
        fs::write(a.dir(&addons).join("app-panes/main/web/index.html"), "<script>evil()</script>").unwrap();
        assert!(matches!(cat.resolve("o/r", "main"), Err(CatalogError::Changed(_))));
        assert!(!cat.list().iter().find(|x| x.id == "o/r").unwrap().digest_ok);
    }

    #[test]
    fn pane_names_cannot_walk_out() {
        let tmp = tempfile::tempdir().unwrap();
        let addons = tmp.path().join("addons");
        let a = install(&addons, "o/r", '1', true);
        index::write(&addons, &[a]).unwrap();
        let cat = Catalog::new(None, addons);
        for bad in ["", "..", "../main", "main/../main", "a/b", "Main", "main\0", "a b"] {
            assert!(cat.resolve("o/r", bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn a_pane_with_a_bad_conf_or_no_entry_is_reported_not_listed() {
        let tmp = tempfile::tempdir().unwrap();
        let addons = tmp.path().join("addons");
        let mut e = install(&addons, "o/r", '1', true);
        let panes = e.dir(&addons).join("app-panes");
        write_pane(&panes, "bad", "title=Bad\nprotocol=9\n", true);
        write_pane(&panes, "noentry", "title=NoEntry\nprotocol=1\n", false);
        e.payload_digest = digest::payload_digest(&e.dir(&addons)).unwrap();
        index::write(&addons, &[e]).unwrap();
        let l = Catalog::new(None, addons).list();
        let a = &l[0];
        assert_eq!(a.panes.len(), 1);
        assert!(a.problems.iter().any(|p| p.contains("protocol 9 is not known")), "{:?}", a.problems);
        assert!(a.problems.iter().any(|p| p.contains("app-panes/noentry/web/index.html is missing")), "{:?}", a.problems);
    }
}
