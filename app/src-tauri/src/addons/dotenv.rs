//! Telling the person, when they allow a folder, that it holds a `.env` file.
//!
//! The rule itself is in `denylist` (`Denylist::with_env_files`): a pane that
//! declares `network` cannot read `.env` / `.env.*`, decided on every call. This
//! is only the notice: a bounded walk under the folder that was just allowed, so
//! the card can say "This folder has a .env file." (and, for a network pane, that
//! it will not be readable). The walk never follows a link, never enters a place
//! the denylist protects, and stops at a fixed number of folders and depth; when it
//! stops early it says so and the notice is worded as "may".

use serde::Serialize;
use std::fs;
use std::path::{Path, PathBuf};

use super::denylist::{is_env_file_name, Snapshot};

pub const MAX_DEPTH: usize = 4;
pub const MAX_ENTRIES: usize = 4000;
/// Folders that hold other people's files, not the person's project: not walked.
const SKIP: &[&str] = &[".git", "node_modules", "target", ".venv", "venv", "__pycache__"];

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvScan {
    /// A regular file named `.env` or `.env.*` was found.
    pub found: bool,
    /// The walk stopped at its limits before looking everywhere.
    pub truncated: bool,
}

pub fn scan_folder(root: &Path, deny: &Snapshot) -> EnvScan {
    let mut out = EnvScan::default();
    let mut seen = 0usize;
    let mut queue: Vec<(PathBuf, usize)> = vec![(root.to_path_buf(), 0)];
    while let Some((dir, depth)) = queue.pop() {
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        for entry in rd.flatten() {
            seen += 1;
            if seen > MAX_ENTRIES {
                out.truncated = true;
                return out;
            }
            let Ok(ft) = entry.file_type() else { continue };
            let name = entry.file_name().to_string_lossy().into_owned();
            if ft.is_file() && is_env_file_name(&name) {
                out.found = true;
                return out;
            }
            if ft.is_dir() && !ft.is_symlink() && !SKIP.contains(&name.as_str()) {
                if depth + 1 > MAX_DEPTH {
                    out.truncated = true;
                    continue;
                }
                let p = entry.path();
                if !deny.is_denied(&p) {
                    queue.push((p, depth + 1));
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::addons::denylist::Denylist;

    fn snap() -> Snapshot {
        Denylist::from_process_env(Vec::new()).snapshot()
    }

    #[test]
    fn finds_a_top_level_and_a_nested_env_file_and_says_nothing_otherwise() {
        let d = tempfile::tempdir().unwrap();
        let root = d.path().canonicalize().unwrap();
        fs::create_dir_all(root.join("a/b")).unwrap();
        fs::write(root.join("a/b/readme.md"), "x").unwrap();
        assert_eq!(scan_folder(&root, &snap()), EnvScan { found: false, truncated: false });
        fs::write(root.join("a/b/.env.local"), "S=1").unwrap();
        assert!(scan_folder(&root, &snap()).found);
        let top = tempfile::tempdir().unwrap();
        let top = top.path().canonicalize().unwrap();
        fs::write(top.join(".env"), "S=1").unwrap();
        assert!(scan_folder(&top, &snap()).found);
    }

    #[test]
    fn names_that_only_look_alike_and_env_folders_are_not_env_files() {
        let d = tempfile::tempdir().unwrap();
        let root = d.path().canonicalize().unwrap();
        for n in [".envrc", "env", "my.env", ".environment"] {
            fs::write(root.join(n), "x").unwrap();
        }
        fs::create_dir_all(root.join(".env.d")).unwrap();
        assert!(!scan_folder(&root, &snap()).found, "a folder named .env.d is not a file");
    }

    #[test]
    fn the_walk_skips_dependency_folders_and_does_not_follow_links() {
        let d = tempfile::tempdir().unwrap();
        let root = d.path().canonicalize().unwrap();
        fs::create_dir_all(root.join("node_modules/pkg")).unwrap();
        fs::write(root.join("node_modules/pkg/.env"), "S=1").unwrap();
        fs::create_dir_all(root.join(".git")).unwrap();
        fs::write(root.join(".git/.env"), "S=1").unwrap();
        #[cfg(unix)]
        {
            let outside = tempfile::tempdir().unwrap();
            fs::write(outside.path().join(".env"), "S=1").unwrap();
            std::os::unix::fs::symlink(outside.path(), root.join("link")).unwrap();
        }
        assert!(!scan_folder(&root, &snap()).found);
    }

    #[test]
    fn the_walk_is_bounded_and_says_when_it_stopped_early() {
        let d = tempfile::tempdir().unwrap();
        let root = d.path().canonicalize().unwrap();
        let mut deep = root.clone();
        for i in 0..MAX_DEPTH + 2 {
            deep = deep.join(format!("d{i}"));
        }
        fs::create_dir_all(&deep).unwrap();
        fs::write(deep.join(".env"), "S=1").unwrap();
        let r = scan_folder(&root, &snap());
        assert!(!r.found && r.truncated, "{r:?}");
    }
}
