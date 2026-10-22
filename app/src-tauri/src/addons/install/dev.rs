//! "Load from folder" for add-on authors (design 8c). The same checks as an
//! install; the folder is **copied** into `addons/.dev/<id>/<n>/` (never served
//! in place, so editing the folder cannot change a running pane) and gets a
//! digest and a manifest like any installed add-on. Developer grants live until
//! the app quits and are never saved.

use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};

use super::extract::Limits;
use super::stage::{map_error, Failure};
use super::{check_all, tree};
use crate::addons::digest;

pub const MAX_DEV_ADDONS: usize = 20;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct DevEntry {
    /// `dev:<slug>`
    pub id: String,
    /// The folder's name, for the "DEV · <folder>" badge.
    pub label: String,
    /// Where the copy lives: `<addons>/.dev/<slug>/<n>`.
    #[serde(skip)]
    pub tree_root: PathBuf,
    /// Digest of the copy: what every open is checked against.
    #[serde(skip)]
    pub digest: String,
    /// The folder it was loaded from (shown nowhere but the developer's own list).
    #[serde(skip)]
    pub source: PathBuf,
    pub panes: Vec<String>,
    pub copy: u32,
}

pub fn dev_root(addons: &Path) -> PathBuf {
    addons.join(".dev")
}

fn slug_of(name: &str) -> String {
    let mut s: String = name.to_ascii_lowercase().chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    s = s.trim_matches('-').to_string();
    if s.is_empty() {
        s = "addon".into();
    }
    s.truncate(40);
    s
}

fn is_pane_folder(folder: &Path) -> bool {
    folder.join("addon.conf").is_file() && folder.join("web").is_dir()
}

fn copy_plain(src_root: &Path, rel: &str, dest_root: &Path, dest_rel: &str) -> Result<(), Failure> {
    let io = |e: std::io::Error| Failure { code: "io", message: format!("Could not copy {rel}: {e}") };
    let from = src_root.join(rel);
    // checked again right before the copy: a file swapped for a link since the scan is refused
    let md = fs::symlink_metadata(&from).map_err(io)?;
    if !md.is_file() {
        return Err(Failure { code: "unsafe_entry", message: format!("Refused: the repository contains a symbolic link at {rel}. Add-ons may contain only plain files.") });
    }
    let to = dest_root.join(dest_rel);
    if let Some(p) = to.parent() {
        fs::create_dir_all(p).map_err(io)?;
    }
    fs::copy(&from, &to).map_err(io)?;
    Ok(())
}

/// Checks `folder` (a repository root with `app-panes/`, or one pane folder with
/// `addon.conf` and `web/`), copies it, verifies the copy and returns the entry.
/// `previous` is the entry this load replaces (Reload from folder): its copy is
/// deleted once the new one is ready.
pub fn load(addons: &Path, folder: &Path, existing: &[DevEntry], limits: Limits) -> Result<DevEntry, Failure> {
    let source = fs::canonicalize(folder).map_err(|_| Failure { code: "not_found", message: format!("{} no longer exists.", folder.display()) })?;
    if !source.is_dir() {
        return Err(Failure { code: "bad_args", message: "Choose a folder.".into() });
    }
    let label = source.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "addon".into());
    let slug = slug_of(&label);
    let id = format!("dev:{slug}");
    let previous = existing.iter().find(|e| e.id == id || e.source == source).cloned();
    if previous.is_none() && existing.len() >= MAX_DEV_ADDONS {
        return Err(Failure { code: "too_many", message: format!("At most {MAX_DEV_ADDONS} developer add-ons can be loaded at once. Remove one first.") });
    }

    // 1. scan the source with the install rules
    let pane_mode = is_pane_folder(&source);
    let (scan_root, prefix): (PathBuf, String) = if pane_mode { (source.clone(), format!("app-panes/{slug}/")) } else { (source.clone(), String::new()) };
    let files = tree::list_files(&scan_root);
    let report = tree::check_tree(&scan_root, &files, limits);
    if !report.errors.is_empty() {
        return Err(map_error(&report.errors, &label));
    }

    // 2. copy into a fresh numbered folder
    let copy = previous.as_ref().map(|p| p.copy + 1).unwrap_or(1);
    let dest = dev_root(addons).join(&slug).join(copy.to_string());
    if dest.exists() {
        let _ = fs::remove_dir_all(&dest);
    }
    fs::create_dir_all(&dest).map_err(|e| Failure { code: "io", message: format!("Could not prepare the developer copy: {e}") })?;
    let cleanup = |f: Failure| {
        let _ = fs::remove_dir_all(&dest);
        f
    };
    for rel in &files {
        copy_plain(&scan_root, rel, &dest, &format!("{prefix}{rel}")).map_err(cleanup)?;
    }

    // 3. the same layout and conf checks, on the copy
    let (errors, layout) = check_all(&dest, limits);
    if !errors.is_empty() {
        return Err(cleanup(map_error(&errors, &label)));
    }
    if layout.panes.is_empty() {
        return Err(cleanup(Failure { code: "no_app_panes", message: format!("{label} has no app add-on (no app-panes/ folder).") }));
    }
    let manifest = digest::manifest(&dest).map_err(|e| cleanup(Failure { code: "io", message: format!("Could not read the developer copy: {e}") }))?;
    if let Some(p) = previous {
        let _ = fs::remove_dir_all(&p.tree_root);
    }
    Ok(DevEntry { id, label, tree_root: dest, digest: manifest.digest, source, panes: layout.panes.iter().map(|(n, _)| n.clone()).collect(), copy })
}

/// Deletes every developer copy (the app quit or the developer asked).
pub fn clear(addons: &Path) {
    let _ = fs::remove_dir_all(dev_root(addons));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(root: &Path, rel: &str, text: &str) {
        let p = root.join(rel);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, text).unwrap();
    }

    fn repo(dir: &Path, conf: &str) {
        write(dir, "agmsg-plugin.conf", "name = x\n");
        write(dir, "app-panes/main/addon.conf", conf);
        write(dir, "app-panes/main/web/index.html", "<div></div>");
        write(dir, "node_modules/junk/x.js", "ignored");
    }

    const CONF: &str = "title = Dev\nprotocol = 1\npermissions = files:read\nwhy.files:read = r\n";

    #[test]
    fn a_repository_root_is_copied_checked_and_pinned() {
        let a = tempfile::tempdir().unwrap();
        let src = tempfile::tempdir().unwrap();
        repo(src.path(), CONF);
        let e = load(a.path(), src.path(), &[], Limits::default()).unwrap();
        assert!(e.id.starts_with("dev:") && e.copy == 1 && e.panes == vec!["main"]);
        assert!(e.tree_root.starts_with(dev_root(a.path())));
        assert!(e.tree_root.join("app-panes/main/web/index.html").is_file());
        assert!(!e.tree_root.join("node_modules").exists(), "node_modules is not copied");
        assert_eq!(e.digest, digest::payload_digest(&e.tree_root).unwrap());
        // the copy is not the folder: editing the folder cannot change what is served
        write(src.path(), "app-panes/main/web/index.html", "<script>evil()</script>");
        assert_eq!(fs::read_to_string(e.tree_root.join("app-panes/main/web/index.html")).unwrap(), "<div></div>");
        assert_eq!(e.digest, digest::payload_digest(&e.tree_root).unwrap());
    }

    #[test]
    fn a_single_pane_folder_is_wrapped_into_the_layout() {
        let a = tempfile::tempdir().unwrap();
        let src = tempfile::tempdir().unwrap();
        write(src.path(), "addon.conf", CONF);
        write(src.path(), "web/index.html", "<div></div>");
        let e = load(a.path(), src.path(), &[], Limits::default()).unwrap();
        assert_eq!(e.panes.len(), 1);
        let name = &e.panes[0];
        assert!(e.tree_root.join("app-panes").join(name).join("addon.conf").is_file());
        assert!(e.tree_root.join("app-panes").join(name).join("web/index.html").is_file());
    }

    #[test]
    fn reload_from_folder_makes_a_new_copy_and_drops_the_old_one() {
        let a = tempfile::tempdir().unwrap();
        let src = tempfile::tempdir().unwrap();
        repo(src.path(), CONF);
        let e1 = load(a.path(), src.path(), &[], Limits::default()).unwrap();
        write(src.path(), "app-panes/main/web/app.js", "export {}");
        let e2 = load(a.path(), src.path(), std::slice::from_ref(&e1), Limits::default()).unwrap();
        assert_eq!((e2.id.as_str(), e2.copy), (e1.id.as_str(), 2));
        assert!(e2.tree_root.join("app-panes/main/web/app.js").is_file());
        assert!(!e1.tree_root.exists(), "the previous copy is deleted");
        assert_ne!(e1.digest, e2.digest);
    }

    #[cfg(unix)]
    #[test]
    fn links_and_hard_links_are_refused_before_anything_is_copied() {
        let a = tempfile::tempdir().unwrap();
        let src = tempfile::tempdir().unwrap();
        repo(src.path(), CONF);
        std::os::unix::fs::symlink("/etc/hosts", src.path().join("app-panes/main/web/link")).unwrap();
        let e = load(a.path(), src.path(), &[], Limits::default()).unwrap_err();
        assert_eq!(e.code, "unsafe_entry");
        assert!(e.message.contains("symbolic link at app-panes/main/web/link"), "{}", e.message);
        assert!(!dev_root(a.path()).exists() || fs::read_dir(dev_root(a.path())).unwrap().count() == 0);
        let src2 = tempfile::tempdir().unwrap();
        repo(src2.path(), CONF);
        write(src2.path(), "app-panes/main/web/a.txt", "same");
        fs::hard_link(src2.path().join("app-panes/main/web/a.txt"), src2.path().join("app-panes/main/web/b.txt")).unwrap();
        assert_eq!(load(a.path(), src2.path(), &[], Limits::default()).unwrap_err().code, "unsafe_entry");
    }

    #[test]
    fn limits_and_conf_problems_use_the_install_messages() {
        let a = tempfile::tempdir().unwrap();
        let src = tempfile::tempdir().unwrap();
        repo(src.path(), CONF);
        write(src.path(), "app-panes/main/web/big.bin", &"x".repeat(2_000_000));
        let e = load(a.path(), src.path(), &[], Limits { file_bytes: 1_000_000, ..Limits::default() }).unwrap_err();
        assert_eq!(e.code, "too_large");
        let bad = tempfile::tempdir().unwrap();
        repo(bad.path(), "title = X\nprotocol = 1\npermissions = root\n");
        let e = load(a.path(), bad.path(), &[], Limits::default()).unwrap_err();
        assert_eq!(e.code, "invalid_conf");
        assert!(e.message.contains("unknown permission \"root\""));
        let empty = tempfile::tempdir().unwrap();
        write(empty.path(), "README.md", "x");
        assert_eq!(load(a.path(), empty.path(), &[], Limits::default()).unwrap_err().code, "no_app_panes");
        // a failed load leaves no copy behind
        let dev = dev_root(a.path());
        let left = fs::read_dir(&dev).map(|d| d.flatten().flat_map(|s| fs::read_dir(s.path()).map(|x| x.count()).into_iter()).sum::<usize>()).unwrap_or(0);
        assert_eq!(left, 0);
    }

    #[test]
    fn not_a_folder_and_too_many() {
        let a = tempfile::tempdir().unwrap();
        assert_eq!(load(a.path(), &a.path().join("nope"), &[], Limits::default()).unwrap_err().code, "not_found");
        let f = a.path().join("file.txt");
        fs::write(&f, "x").unwrap();
        assert_eq!(load(a.path(), &f, &[], Limits::default()).unwrap_err().code, "bad_args");
        let src = tempfile::tempdir().unwrap();
        repo(src.path(), CONF);
        let fake: Vec<DevEntry> = (0..MAX_DEV_ADDONS).map(|i| DevEntry { id: format!("dev:x{i}"), label: "x".into(), tree_root: PathBuf::from("/nonexistent"), digest: String::new(), source: PathBuf::from(format!("/x{i}")), panes: vec![], copy: 1 }).collect();
        assert_eq!(load(a.path(), src.path(), &fake, Limits::default()).unwrap_err().code, "too_many");
    }

    #[test]
    fn clear_removes_all_copies() {
        let a = tempfile::tempdir().unwrap();
        let src = tempfile::tempdir().unwrap();
        repo(src.path(), CONF);
        let e = load(a.path(), src.path(), &[], Limits::default()).unwrap();
        clear(a.path());
        assert!(!e.tree_root.exists());
    }
}
