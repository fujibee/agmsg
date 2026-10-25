//! The same tree checks as the author check (`checkTree` in
//! `app/addon-kit/agmsg-addon-check.cjs`), on a directory: plain files only, no reserved names, no
//! case collisions, and the install limits. Used on a developer folder before
//! it is copied, and as a second line of defence on an extracted archive. The
//! wording is the shared one (design 3.2).

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use super::extract::{is_reserved_segment, mb, Limits};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TreeReport {
    pub errors: Vec<String>,
    pub total: u64,
    pub count: usize,
    pub largest: (String, u64),
}

fn walk(root: &Path, dir: &Path, out: &mut Vec<String>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    let mut names: Vec<_> = rd.flatten().collect();
    names.sort_by_key(|e| e.file_name());
    for e in names {
        let name = e.file_name().to_string_lossy().into_owned();
        if name == ".git" || name == "node_modules" {
            continue;
        }
        let path = e.path();
        let rel = path.strip_prefix(root).unwrap_or(&path).components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect::<Vec<_>>().join("/");
        match fs::symlink_metadata(&path) {
            Ok(m) if m.is_dir() => walk(root, &path, out),
            Ok(_) => out.push(rel),
            Err(_) => {}
        }
    }
}

/// Every file under `root` (symlinks and special files count as files here so
/// they can be refused by name), skipping `.git` and `node_modules`.
pub fn list_files(root: &Path) -> Vec<String> {
    let mut v = Vec::new();
    walk(root, root, &mut v);
    v
}

pub fn check_tree(root: &Path, files: &[String], limits: Limits) -> TreeReport {
    let mut errors = Vec::new();
    let mut total: u64 = 0;
    let mut largest: (String, u64) = (String::new(), 0);
    let mut lower: HashMap<String, String> = HashMap::new();
    for rel in files {
        let abs = root.join(rel);
        let Ok(md) = fs::symlink_metadata(&abs) else { continue };
        if md.file_type().is_symlink() {
            errors.push(format!("Refused: the repository contains a symbolic link at {rel}. Add-ons may contain only plain files."));
        } else if !md.is_file() {
            errors.push(format!("Refused: {rel} is not a plain file."));
        } else if super::super::fslink::has_other_names(&abs) {
            errors.push(format!("Refused: the repository contains a hard link at {rel}. Add-ons may contain only plain files."));
        }
        for part in rel.split('/') {
            if is_reserved_segment(part) {
                errors.push(format!("Refused: the repository contains a reserved file name at {rel}. Add-ons may contain only plain files."));
                break;
            }
        }
        let key = rel.to_lowercase();
        if let Some(prev) = lower.get(&key) {
            errors.push(format!("Refused: {rel} and {prev} differ only in case."));
        }
        lower.insert(key, rel.clone());
        let size = md.len();
        total += size;
        if size > largest.1 {
            largest = (rel.clone(), size);
        }
        if size > limits.file_bytes {
            errors.push(format!("Too large to install: {rel} is {} (limit {} per file).", mb(size), mb(limits.file_bytes)));
        }
    }
    if files.len() > limits.files {
        errors.push(format!("Too large to install: {} files (limit {}).", files.len(), limits.files));
    }
    if total > limits.total_bytes {
        errors.push(format!("Too large to install: {} (limit {}). Largest file: {} ({}).", mb(total), mb(limits.total_bytes), largest.0, mb(largest.1)));
    }
    TreeReport { errors, total, count: files.len(), largest }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check(root: &Path) -> Vec<String> {
        let files = list_files(root);
        check_tree(root, &files, Limits::default()).errors
    }

    fn folder() -> (tempfile::TempDir, std::path::PathBuf, std::path::PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let outside = d.path().join("outside.txt");
        fs::write(&outside, "x").unwrap();
        let root = d.path().join("addon");
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("index.html"), "<p>x</p>").unwrap();
        (d, root, outside)
    }

    #[test]
    fn a_plain_folder_passes() {
        let (_d, root, _o) = folder();
        assert_eq!(check(&root), Vec::<String>::new());
    }

    #[test]
    fn a_hard_link_is_refused() {
        let (_d, root, outside) = folder();
        fs::hard_link(&outside, root.join("hard.txt")).unwrap();
        let errors = check(&root);
        assert!(errors.iter().any(|e| e.contains("hard link at hard.txt")), "{errors:?}");
    }

    #[test]
    fn the_original_of_a_hard_link_made_inside_the_folder_is_refused_too() {
        let (_d, root, _o) = folder();
        fs::hard_link(root.join("index.html"), root.join("copy.html")).unwrap();
        let errors = check(&root);
        assert!(errors.iter().any(|e| e.contains("hard link at index.html")), "{errors:?}");
        assert!(errors.iter().any(|e| e.contains("hard link at copy.html")), "{errors:?}");
    }

    #[cfg(windows)]
    #[test]
    fn windows_symlinks_and_junctions_are_refused() {
        let (d, root, outside) = folder();
        let dir = d.path().join("elsewhere");
        fs::create_dir_all(&dir).unwrap();
        std::os::windows::fs::symlink_file(&outside, root.join("flink")).expect("create a file symlink (needs administrator or developer mode)");
        std::os::windows::fs::symlink_dir(&dir, root.join("dlink")).expect("create a directory symlink");
        super::super::super::fslink::win_test::junction(&root.join("junc"), &dir);
        let errors = check(&root);
        for name in ["flink", "dlink", "junc"] {
            assert!(errors.iter().any(|e| e.contains(&format!("symbolic link at {name}"))), "{name}: {errors:?}");
        }
    }
}
