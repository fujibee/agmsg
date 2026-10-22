//! Staging and activation (design 3.1): fetch → stage → verify → confirm →
//! atomic activation. Nothing is visible to the rest of the app until the last
//! step, which is replacing `index.tsv`.
//!
//! ```text
//! addons/.staging/<random>/tree/     extracted, checked, hashed; waiting for the user
//! addons/<owner>/<repo>/<sha>/       the activated tree (rename of the staged one, same volume)
//! addons/index.tsv                   the record that makes it an installed add-on
//! ```

use serde::Serialize;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{self, Read};
use std::path::{Path, PathBuf};

use super::extract::{self, InstallErrorKind, Limits};
use super::grants;
use super::update::{self, Diff, PermSet};
use super::check_all;
use crate::addons::conf::AddonConf;
use crate::addons::csp::{self, Network};
use crate::addons::digest;
use crate::addons::index::{self, IndexEntry};

/// A refusal the UI shows, with a stable code.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Failure {
    pub code: &'static str,
    pub message: String,
}

impl Failure {
    fn new(code: &'static str, message: impl Into<String>) -> Failure {
        Failure { code, message: message.into() }
    }
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PaneConfirm {
    pub name: String,
    pub title: String,
    pub entry: String,
    pub permissions: Vec<String>,
    pub network: String,
    pub opens: Vec<String>,
    pub why: std::collections::BTreeMap<String, String>,
    /// A read permission and `network` together: "it can send what it reads to <hosts | any site>".
    pub can_send_what_it_reads: bool,
}

#[derive(Debug, Clone)]
pub struct Staged {
    /// Random; names the staging folder.
    pub id: String,
    pub repo: String,
    pub sha: String,
    pub archive_sha256: String,
    /// Digest of the staged tree: what the user is shown and what activation re-checks.
    pub tree_digest: String,
    /// `<addons>/.staging/<id>`
    pub root: PathBuf,
    pub panes: Vec<(String, AddonConf)>,
    pub warnings: Vec<String>,
    pub files: usize,
    pub bytes: u64,
}

impl Staged {
    pub fn tree(&self) -> PathBuf {
        self.root.join("tree")
    }

    pub fn confirm_data(&self, previous: Option<&IndexEntry>) -> Confirm {
        let panes: Vec<PaneConfirm> = self
            .panes
            .iter()
            .map(|(name, c)| PaneConfirm {
                name: name.clone(),
                title: c.title.clone(),
                entry: c.entry.clone(),
                permissions: c.permissions.clone(),
                network: c.network.clone().unwrap_or_default(),
                opens: c.opens.clone(),
                why: c.why.clone(),
                can_send_what_it_reads: c.permissions.iter().any(|p| p == "network") && c.permissions.iter().any(|p| p == "messages:read" || p == "files:read" || p == "git:read"),
            })
            .collect();
        let new = self.perm_set();
        let (diff, previous_sha) = match previous {
            Some(p) => (Some(update::diff(&perm_set_of_entry(p), &new)), Some(p.sha.clone())),
            None => (None, None),
        };
        Confirm {
            staging_id: self.id.clone(),
            repo: self.repo.clone(),
            sha: self.sha.clone(),
            archive_sha256: self.archive_sha256.clone(),
            tree_digest: self.tree_digest.clone(),
            panes,
            warnings: self.warnings.clone(),
            files: self.files,
            bytes: self.bytes,
            previous_sha,
            asks_again: diff.as_ref().map_or(false, Diff::needs_confirm_again),
            added_permissions: diff.as_ref().map(|d| d.added.clone()).unwrap_or_default(),
            removed_permissions: diff.as_ref().map(|d| d.removed.clone()).unwrap_or_default(),
            network_widened: diff.as_ref().map_or(false, |d| d.network_widened),
            network_newly_combined: diff.as_ref().map_or(false, |d| d.network_newly_combined),
        }
    }

    /// Union over the panes (the index keeps one permission list per add-on).
    pub fn perm_set(&self) -> PermSet {
        let mut permissions: Vec<String> = Vec::new();
        let mut origins: Vec<String> = Vec::new();
        let mut any = false;
        for (_, c) in &self.panes {
            for p in &c.permissions {
                if !permissions.contains(p) {
                    permissions.push(p.clone());
                }
            }
            if let Some(n) = &c.network {
                match csp::parse_network(n) {
                    Ok(Network::Any) => any = true,
                    Ok(Network::Origins(o)) => {
                        for x in o {
                            if !origins.contains(&x) {
                                origins.push(x);
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
        let network = if any {
            Network::Any
        } else if origins.is_empty() {
            Network::None
        } else {
            Network::Origins(origins)
        };
        PermSet { permissions, network }
    }
}

pub fn perm_set_of_entry(e: &IndexEntry) -> PermSet {
    PermSet { permissions: e.permissions.clone(), network: csp::parse_network(&e.network).unwrap_or(Network::None) }
}

/// What the confirm dialog (S3/S8) is built from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Confirm {
    pub staging_id: String,
    pub repo: String,
    pub sha: String,
    pub archive_sha256: String,
    pub tree_digest: String,
    pub panes: Vec<PaneConfirm>,
    pub warnings: Vec<String>,
    pub files: usize,
    pub bytes: u64,
    /// Set for an update: the commit being replaced.
    pub previous_sha: Option<String>,
    /// An update that adds a permission, widens the network list or combines network with a read permission.
    pub asks_again: bool,
    pub added_permissions: Vec<String>,
    pub removed_permissions: Vec<String>,
    pub network_widened: bool,
    pub network_newly_combined: bool,
}

/// Hashes (SHA-256) and counts what passes through, so the archive's hash comes
/// from the very bytes that were extracted.
struct Tee<R> {
    inner: R,
    hash: Sha256,
    bytes: u64,
    cap: u64,
}

impl<R: Read> Read for Tee<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.hash.update(&buf[..n]);
        self.bytes += n as u64;
        if self.bytes > self.cap {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "the download is larger than the limit"));
        }
        Ok(n)
    }
}

/// Largest download read, compressed (a bit above the extracted limit so a normal repository always fits).
pub const MAX_DOWNLOAD: u64 = 300 * 1024 * 1024;

pub fn staging_root(addons: &Path) -> PathBuf {
    addons.join(".staging")
}

fn random_id() -> String {
    let mut b = [0u8; 12];
    getrandom::getrandom(&mut b).expect("the OS random source is unavailable");
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// `0.6.0` style comparison; anything unparsable counts as "not satisfied".
pub fn version_at_least(have: &str, need: &str) -> bool {
    fn parse(v: &str) -> Option<[u64; 3]> {
        let core = v.split(['-', '+']).next()?;
        let p: Vec<u64> = core.split('.').map(|x| x.parse().ok()).collect::<Option<Vec<_>>>()?;
        (p.len() == 3).then(|| [p[0], p[1], p[2]])
    }
    match (parse(have), parse(need)) {
        (Some(h), Some(n)) => h >= n,
        _ => false,
    }
}

fn map_error(errors: &[String], repo: &str) -> Failure {
    let first = errors.first().cloned().unwrap_or_default();
    if errors.iter().any(|e| e.starts_with("No app add-on here")) {
        return Failure::new("no_app_panes", format!("{repo} has no app add-on (no app-panes/ folder). If it is an agmsg CLI plugin, it is installed from the CLI, not here."));
    }
    if let Some(e) = errors.iter().find(|e| e.contains("is not known to this version")) {
        let n = e.split("protocol ").nth(1).and_then(|r| r.split(' ').next()).unwrap_or("?");
        return Failure::new("protocol", format!("Made for a newer app (protocol {n}). Update the app to use it."));
    }
    if errors.iter().any(|e| e.starts_with("Too large to install")) {
        return Failure::new("too_large", errors.iter().find(|e| e.starts_with("Too large to install")).cloned().unwrap_or(first));
    }
    if errors.iter().any(|e| e.starts_with("Refused:")) {
        return Failure::new("unsafe_entry", errors.iter().find(|e| e.starts_with("Refused:")).cloned().unwrap_or(first));
    }
    if errors.iter().any(|e| e.contains("web/") && e.contains("is missing")) {
        let e = errors.iter().find(|e| e.contains("is missing")).cloned().unwrap_or(first.clone());
        return Failure::new("entry_missing", format!("{e} See the author guide: Build an app add-on."));
    }
    Failure::new("invalid_conf", errors.join(" "))
}

/// Extracts and checks one archive into a new staging folder.
pub fn stage<R: Read>(addons: &Path, repo: &str, sha: &str, archive: R, app_version: &str, limits: Limits) -> Result<Staged, Failure> {
    let id = random_id();
    let root = staging_root(addons).join(&id);
    let tree = root.join("tree");
    fs::create_dir_all(&tree).map_err(|e| Failure::new("io", format!("Could not prepare the install folder: {e}")))?;
    let fail = |f: Failure| {
        extract::discard(&root);
        f
    };
    let mut tee = Tee { inner: archive, hash: Sha256::new(), bytes: 0, cap: MAX_DOWNLOAD };
    let extracted = match extract::extract_tar_gz(&mut tee, &tree, limits) {
        Ok(x) => x,
        Err(e) => {
            let code = match e.kind {
                InstallErrorKind::UnsafeEntry => "unsafe_entry",
                InstallErrorKind::TooLarge => "too_large",
                InstallErrorKind::BadArchive => "archive",
                InstallErrorKind::Io => "io",
            };
            return Err(fail(Failure::new(code, e.message)));
        }
    };
    // drain what the extractor did not need (the tar end blocks), so the hash covers the whole download
    let mut sink = [0u8; 8192];
    while tee.read(&mut sink).map(|n| n > 0).unwrap_or(false) {}
    let archive_sha256 = hex(&tee.hash.finalize());

    let (errors, layout_report) = check_all(&tree, limits);
    if !errors.is_empty() {
        return Err(fail(map_error(&errors, repo)));
    }
    let panes = layout_report.panes.clone();
    if panes.is_empty() {
        return Err(fail(Failure::new("no_app_panes", format!("{repo} has no app add-on (no app-panes/ folder). If it is an agmsg CLI plugin, it is installed from the CLI, not here."))));
    }
    for (_, c) in &panes {
        if let Some(min) = &c.min_app {
            if !version_at_least(app_version, min) {
                return Err(fail(Failure::new("min_app", format!("Needs agmsg app {min} or newer; this is {app_version}."))));
            }
        }
    }
    let manifest = digest::manifest(&tree).map_err(|e| fail(Failure::new("io", format!("Could not read the add-on's files: {e}"))))?;
    Ok(Staged { id, repo: repo.to_string(), sha: sha.to_string(), archive_sha256, tree_digest: manifest.digest, root, panes, warnings: layout_report.warnings, files: extracted.files.len(), bytes: extracted.total })
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// Deletes a staged install the user cancelled (or that was abandoned).
pub fn discard(s: &Staged) {
    extract::discard(&s.root);
}

/// Removes staging folders left behind by a crash or an abandoned dialog.
pub fn gc_staging(addons: &Path) {
    let _ = fs::remove_dir_all(staging_root(addons));
}

#[derive(Debug, Clone)]
pub struct Activation {
    pub entry: IndexEntry,
    pub previous: Option<IndexEntry>,
    pub diff: Option<Diff>,
}

fn short(sha: &str) -> &str {
    &sha[..sha.len().min(7)]
}

/// Moves the staged tree into place and records it. The user confirmed
/// `staged.tree_digest`; if the files no longer hash to it, nothing is activated.
/// Order: re-hash → rename into `addons/<owner>/<repo>/<sha>` → grants → `index.tsv`
/// (the activation point) → delete the previous version.
pub fn activate(addons: &Path, staged: &Staged, installed_at: &str) -> Result<Activation, Failure> {
    let now = digest::payload_digest(&staged.tree()).map_err(|e| Failure::new("io", format!("Could not read the add-on's files: {e}")))?;
    if now != staged.tree_digest {
        extract::discard(&staged.root);
        return Err(Failure::new("changed", "The downloaded files changed before they were installed. Nothing was installed; try again."));
    }
    let mut table = index::read(addons);
    let previous = table.iter().find(|e| e.repo == staged.repo).cloned();
    if previous.as_ref().is_some_and(|p| p.sha == staged.sha) {
        extract::discard(&staged.root);
        return Err(Failure::new("already_installed", format!("Already installed ({}).", short(&staged.sha))));
    }
    let perm = staged.perm_set();
    let entry = IndexEntry {
        repo: staged.repo.clone(),
        sha: staged.sha.clone(),
        archive_sha256: staged.archive_sha256.clone(),
        payload_digest: staged.tree_digest.clone(),
        panes: staged.panes.iter().map(|(n, _)| n.clone()).collect(),
        permissions: perm.permissions.clone(),
        network: match &perm.network {
            Network::None => String::new(),
            Network::Any => "*".into(),
            Network::Origins(o) => o.join(","),
        },
        installed_at: installed_at.to_string(),
        enabled: true,
    };
    let target = entry.dir(addons);
    if entry.to_line().is_none() {
        extract::discard(&staged.root);
        return Err(Failure::new("invalid", "The add-on's record has fields that cannot be stored."));
    }
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|e| Failure::new("io", format!("Could not create the install folder: {e}")))?;
    }
    // a folder at the target that the table does not know is a leftover of a crash: it is ours to replace
    if target.exists() {
        let _ = fs::remove_dir_all(&target);
    }
    fs::rename(staged.tree(), &target).map_err(|e| Failure::new("io", format!("Could not activate the add-on: {e}")))?;

    let diff = previous.as_ref().map(|p| update::diff(&perm_set_of_entry(p), &perm));
    if let Some(d) = &diff {
        let kept = update::migrate_grants(grants::read(addons), &staged.repo, &staged.sha, d);
        grants::write(addons, &kept).map_err(|e| Failure::new("io", format!("Could not update the saved permissions: {e}")))?;
    }
    table.retain(|e| e.repo != staged.repo);
    table.push(entry.clone());
    index::write(addons, &table).map_err(|e| Failure::new("io", format!("Could not record the install: {e}")))?;
    // the old version, now unreferenced
    if let Some(p) = &previous {
        let _ = fs::remove_dir_all(p.dir(addons));
    }
    extract::discard(&staged.root);
    Ok(Activation { entry, previous, diff })
}

/// Removes an installed add-on: its record, its remembered grants and every version on disk.
pub fn remove(addons: &Path, repo: &str) -> Result<(), Failure> {
    let mut table = index::read(addons);
    let Some(i) = table.iter().position(|e| e.repo == repo) else {
        return Err(Failure::new("not_found", "That add-on is not installed."));
    };
    let gone = table.remove(i);
    // record first: from this moment it is not installed, whatever happens to the files
    index::write(addons, &table).map_err(|e| Failure::new("io", format!("Could not update the install record: {e}")))?;
    grants::remove_repo(addons, repo).map_err(|e| Failure::new("io", format!("Could not forget the saved permissions: {e}")))?;
    let repo_dir = gone.dir(addons).parent().map(Path::to_path_buf);
    if let Some(d) = repo_dir {
        let _ = fs::remove_dir_all(&d);
        // drop the owner folder when it is empty
        if let Some(owner) = d.parent() {
            let _ = fs::remove_dir(owner);
        }
    }
    Ok(())
}

pub fn short_sha(sha: &str) -> &str {
    short(sha)
}

#[cfg(test)]
mod tests {
    use super::super::testutil::tarball;
    use super::*;
    use crate::addons::catalog::Catalog;
    use serde_json::json;

    const SHA1: &str = "1111111111111111111111111111111111111111";
    const SHA2: &str = "2222222222222222222222222222222222222222";

    fn addon(conf: &str, extra: Vec<serde_json::Value>) -> Vec<u8> {
        let mut e = vec![
            json!({"path": "agmsg-plugin.conf", "type": "file", "text": "name = x\n"}),
            json!({"path": "app-panes/main/addon.conf", "type": "file", "text": conf}),
            json!({"path": "app-panes/main/web/index.html", "type": "file", "text": "<div id=root></div>"}),
        ];
        e.extend(extra);
        tarball(&e)
    }

    const FILES_CONF: &str = "title = Main\nprotocol = 1\npermissions = files:read\nwhy.files:read = reads\n";

    fn stage_ok(addons: &Path, repo: &str, sha: &str, tar: &[u8]) -> Staged {
        stage(addons, repo, sha, tar, "0.5.0", Limits::default()).unwrap()
    }

    fn fail(addons: &Path, tar: &[u8]) -> Failure {
        stage(addons, "o/r", SHA1, tar, "0.5.0", Limits::default()).unwrap_err()
    }

    #[test]
    fn a_good_archive_is_staged_with_the_data_for_the_confirm_dialog() {
        let d = tempfile::tempdir().unwrap();
        let tar = addon("title = Main\nprotocol = 1\npermissions = files:read, network\nnetwork = https://api.test\nwhy.files:read = r\nwhy.network = n\nopens = path\n", vec![]);
        let s = stage_ok(d.path(), "o/r", SHA1, &tar);
        assert_eq!(s.archive_sha256, digest::sha256_hex(&tar), "the archive hash covers exactly the downloaded bytes");
        assert!(s.tree().join("app-panes/main/web/index.html").is_file());
        let c = s.confirm_data(None);
        assert_eq!((c.repo.as_str(), c.sha.as_str()), ("o/r", SHA1));
        assert_eq!(c.panes.len(), 1);
        let p = &c.panes[0];
        assert_eq!((p.name.as_str(), p.title.as_str()), ("main", "Main"));
        assert_eq!(p.permissions, vec!["files:read", "network"]);
        assert_eq!(p.network, "https://api.test");
        assert_eq!(p.opens, vec!["path"]);
        assert!(p.can_send_what_it_reads, "a read permission together with network says it can send what it reads");
        assert!(!c.asks_again && c.previous_sha.is_none());
        assert_eq!(c.tree_digest, s.tree_digest);
        assert!(c.files >= 3 && c.bytes > 0);
        // nothing is installed yet
        assert!(index::read(d.path()).is_empty());
        assert!(!d.path().join("o").exists());
    }

    #[test]
    fn refusals_carry_the_messages_of_the_design() {
        let d = tempfile::tempdir().unwrap();
        let no_panes = tarball(&[json!({"path": "README.md", "type": "file", "text": "x"})]);
        let f = fail(d.path(), &no_panes);
        assert_eq!(f.code, "no_app_panes");
        assert_eq!(f.message, "o/r has no app add-on (no app-panes/ folder). If it is an agmsg CLI plugin, it is installed from the CLI, not here.");
        let f = fail(d.path(), &addon("title = Main\nprotocol = 2\n", vec![]));
        assert_eq!((f.code, f.message.as_str()), ("protocol", "Made for a newer app (protocol 2). Update the app to use it."));
        let f = fail(d.path(), &addon("title = Main\nprotocol = 1\nmin_app = 9.0.0\n", vec![]));
        assert_eq!((f.code, f.message.as_str()), ("min_app", "Needs agmsg app 9.0.0 or newer; this is 0.5.0."));
        let f = fail(d.path(), &addon("title = Main\nprotocol = 1\npermissions = root\n", vec![]));
        assert_eq!(f.code, "invalid_conf");
        assert!(f.message.contains("app-panes/main/addon.conf line 3: unknown permission \"root\"."), "{}", f.message);
        let f = fail(d.path(), &addon("title = Main\nprotocol = 1\nentry = main.html\n", vec![]));
        assert_eq!(f.code, "entry_missing");
        assert!(f.message.contains("app-panes/main/web/main.html is missing. Add-ons must commit their built web/ folder."), "{}", f.message);
        let f = fail(d.path(), &addon(FILES_CONF, vec![json!({"path": "app-panes/main/web/l", "type": "symlink", "target": "/etc/hosts"})]));
        assert_eq!(f.code, "unsafe_entry");
        assert!(f.message.starts_with("Refused: the repository contains a symbolic link at app-panes/main/web/l."));
        let f = stage(d.path(), "o/r", SHA1, &addon(FILES_CONF, vec![json!({"path": "app-panes/main/web/big.bin", "type": "file", "size": 2_000_000})])[..], "0.5.0", Limits { file_bytes: 1_000_000, ..Limits::default() }).unwrap_err();
        assert_eq!(f.code, "too_large");
        let f = fail(d.path(), b"not an archive");
        assert_eq!(f.code, "archive");
        // every refusal leaves no staging folder behind
        let left: Vec<_> = fs::read_dir(staging_root(d.path())).map(|r| r.flatten().count()).into_iter().collect();
        assert_eq!(left, vec![0]);
        assert!(index::read(d.path()).is_empty());
    }

    #[test]
    fn version_comparison() {
        assert!(version_at_least("0.5.0", "0.5.0"));
        assert!(version_at_least("0.6.0-rc.1", "0.5.9"));
        assert!(version_at_least("1.0.0", "0.9.9"));
        assert!(!version_at_least("0.5.0", "0.5.1"));
        assert!(!version_at_least("0.5.0", "1.0.0"));
        assert!(!version_at_least("weird", "0.1.0"));
        assert!(!version_at_least("0.5.0", "0.5"));
    }

    #[test]
    fn activation_is_atomic_recorded_and_visible_to_the_catalog() {
        let d = tempfile::tempdir().unwrap();
        let s = stage_ok(d.path(), "o/r", SHA1, &addon(FILES_CONF, vec![]));
        let a = activate(d.path(), &s, "2026-10-23T00:00:00Z").unwrap();
        assert!(a.previous.is_none() && a.diff.is_none());
        let dir = d.path().join("o/r").join(SHA1);
        assert!(dir.join("app-panes/main/web/index.html").is_file());
        assert!(!s.root.exists(), "the staging folder is gone");
        let t = index::read(d.path());
        assert_eq!(t.len(), 1);
        assert_eq!((t[0].repo.as_str(), t[0].sha.as_str(), t[0].enabled), ("o/r", SHA1, true));
        assert_eq!(t[0].payload_digest, s.tree_digest);
        assert_eq!(t[0].permissions, vec!["files:read"]);
        let cat = Catalog::new(None, d.path().to_path_buf());
        let l = cat.list();
        assert_eq!(l.len(), 1);
        assert!(l[0].digest_ok && l[0].panes[0].name == "main");
        let r = cat.resolve("o/r", "main").unwrap();
        assert!(r.pinned.contains_key("index.html"));
    }

    #[test]
    fn activating_the_same_commit_twice_is_refused() {
        let d = tempfile::tempdir().unwrap();
        let tar = addon(FILES_CONF, vec![]);
        activate(d.path(), &stage_ok(d.path(), "o/r", SHA1, &tar), "t").unwrap();
        let again = stage_ok(d.path(), "o/r", SHA1, &tar);
        let e = activate(d.path(), &again, "t").unwrap_err();
        assert_eq!((e.code, e.message.as_str()), ("already_installed", "Already installed (1111111)."));
        assert!(!again.root.exists());
        assert_eq!(index::read(d.path()).len(), 1);
    }

    #[test]
    fn what_the_user_confirmed_is_what_is_activated() {
        let d = tempfile::tempdir().unwrap();
        let s = stage_ok(d.path(), "o/r", SHA1, &addon(FILES_CONF, vec![]));
        // someone edits the staged files after the dialog was shown
        fs::write(s.tree().join("app-panes/main/web/index.html"), "<script>evil()</script>").unwrap();
        let e = activate(d.path(), &s, "t").unwrap_err();
        assert_eq!(e.code, "changed");
        assert!(index::read(d.path()).is_empty());
        assert!(!d.path().join("o").exists(), "nothing reached the install folder");
        assert!(!s.root.exists());
        // and a file added to the staged tree changes the digest too
        let s2 = stage_ok(d.path(), "o/r", SHA1, &addon(FILES_CONF, vec![]));
        fs::write(s2.tree().join("app-panes/main/web/extra.js"), "x").unwrap();
        assert_eq!(activate(d.path(), &s2, "t").unwrap_err().code, "changed");
    }

    #[test]
    fn cancel_deletes_the_staging_folder() {
        let d = tempfile::tempdir().unwrap();
        let s = stage_ok(d.path(), "o/r", SHA1, &addon(FILES_CONF, vec![]));
        assert!(s.root.exists());
        discard(&s);
        assert!(!s.root.exists());
        assert!(index::read(d.path()).is_empty());
    }

    #[test]
    fn an_unreferenced_leftover_at_the_target_is_replaced() {
        let d = tempfile::tempdir().unwrap();
        let leftover = d.path().join("o/r").join(SHA1);
        fs::create_dir_all(leftover.join("junk")).unwrap();
        fs::write(leftover.join("junk/old"), "stale").unwrap();
        let s = stage_ok(d.path(), "o/r", SHA1, &addon(FILES_CONF, vec![]));
        activate(d.path(), &s, "t").unwrap();
        assert!(!leftover.join("junk").exists());
        assert!(leftover.join("app-panes/main/addon.conf").is_file());
    }

    fn grant(perm: &str, scope: &str) -> grants::SavedGrant {
        grants::SavedGrant { repo: "o/r".into(), sha: SHA1.into(), pane: "main".into(), permission: perm.into(), scope: scope.into(), granted_at: "t".into() }
    }

    #[test]
    fn an_update_with_equal_permissions_keeps_grants_and_removes_the_old_version() {
        let d = tempfile::tempdir().unwrap();
        activate(d.path(), &stage_ok(d.path(), "o/r", SHA1, &addon(FILES_CONF, vec![])), "t1").unwrap();
        grants::add(d.path(), grant("files:read", "/proj")).unwrap();
        let s2 = stage_ok(d.path(), "o/r", SHA2, &addon(FILES_CONF, vec![json!({"path": "app-panes/main/web/new.js", "type": "file", "text": "1"})]));
        let c = s2.confirm_data(index::read(d.path()).first());
        assert_eq!(c.previous_sha.as_deref(), Some(SHA1));
        assert!(!c.asks_again);
        let a = activate(d.path(), &s2, "t2").unwrap();
        assert_eq!(a.previous.unwrap().sha, SHA1);
        let g = grants::read(d.path());
        assert_eq!(g.len(), 1);
        assert_eq!(g[0].sha, SHA2, "the grant follows the new commit");
        assert!(!d.path().join("o/r").join(SHA1).exists(), "the old version is deleted");
        assert!(d.path().join("o/r").join(SHA2).is_dir());
        let t = index::read(d.path());
        assert_eq!((t.len(), t[0].sha.as_str(), t[0].installed_at.as_str()), (1, SHA2, "t2"));
    }

    #[test]
    fn an_update_that_adds_network_asks_again_and_clears_read_grants() {
        let d = tempfile::tempdir().unwrap();
        activate(d.path(), &stage_ok(d.path(), "o/r", SHA1, &addon(FILES_CONF, vec![])), "t1").unwrap();
        grants::add(d.path(), grant("files:read", "/proj")).unwrap();
        grants::add(d.path(), grant("messages:read", "team-a")).unwrap();
        let new_conf = "title = Main\nprotocol = 1\npermissions = files:read, network\nnetwork = https://x.test\nwhy.files:read = r\nwhy.network = n\n";
        let s2 = stage_ok(d.path(), "o/r", SHA2, &addon(new_conf, vec![]));
        let c = s2.confirm_data(index::read(d.path()).first());
        assert!(c.asks_again && c.added_permissions == vec!["network"] && c.network_newly_combined);
        activate(d.path(), &s2, "t2").unwrap();
        assert!(grants::read(d.path()).is_empty(), "remembered read grants are cleared when network joins them");
        // another add-on's grants are untouched
        let mut other = grant("files:read", "/p");
        other.repo = "x/y".into();
        grants::add(d.path(), other.clone()).unwrap();
        let s3 = stage_ok(d.path(), "o/r", "3333333333333333333333333333333333333333", &addon("title = Main\nprotocol = 1\npermissions = files:read, network\nnetwork = https://x.test, https://y.test\nwhy.files:read = r\nwhy.network = n\n", vec![]));
        activate(d.path(), &s3, "t3").unwrap();
        assert_eq!(grants::read(d.path()), vec![other]);
    }

    #[test]
    fn remove_forgets_everything_and_only_that_add_on() {
        let d = tempfile::tempdir().unwrap();
        activate(d.path(), &stage_ok(d.path(), "o/r", SHA1, &addon(FILES_CONF, vec![])), "t").unwrap();
        activate(d.path(), &stage_ok(d.path(), "o/other", SHA2, &addon(FILES_CONF, vec![])), "t").unwrap();
        grants::add(d.path(), grant("files:read", "/proj")).unwrap();
        remove(d.path(), "o/r").unwrap();
        assert!(!d.path().join("o/r").exists());
        assert!(d.path().join("o/other").join(SHA2).is_dir());
        assert_eq!(index::read(d.path()).len(), 1);
        assert!(grants::read(d.path()).is_empty());
        assert_eq!(remove(d.path(), "o/r").unwrap_err().code, "not_found");
    }

    #[test]
    fn gc_clears_abandoned_staging() {
        let d = tempfile::tempdir().unwrap();
        let s = stage_ok(d.path(), "o/r", SHA1, &addon(FILES_CONF, vec![]));
        assert!(s.root.exists());
        gc_staging(d.path());
        assert!(!s.root.exists());
    }

    #[test]
    fn download_size_is_capped_while_reading() {
        let mut tee = Tee { inner: &[0u8; 100][..], hash: Sha256::new(), bytes: 0, cap: 50 };
        let mut buf = [0u8; 100];
        assert!(tee.read(&mut buf).is_err());
    }
}
