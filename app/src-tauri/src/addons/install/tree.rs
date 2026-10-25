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
        } else if has_hard_links(&md) {
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

#[cfg(unix)]
fn has_hard_links(md: &fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    md.nlink() > 1
}

#[cfg(windows)]
fn has_hard_links(_md: &fs::Metadata) -> bool {
    // std exposes the link count only on nightly, so a developer folder is not
    // checked for hard links on Windows yet (the archive path refuses them
    // outright). Add-ons stay off on Windows until this is closed.
    false
}
