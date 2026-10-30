//! Checked extraction of an add-on's GitHub tarball into a staging directory
//! (design 3.1). The whole archive is refused on the first unsafe entry; nothing
//! outside the staging directory is ever written; limits are enforced on the
//! bytes actually read, not on the sizes the archive claims.
//!
//! The same cases are exercised against the author check through the
//! shared corpus in `app/addon-kit/fixtures/install-cases.json`, so authors see
//! the refusal before pushing that the app shows after.

use std::collections::HashMap;
use std::fs;
use std::io::{self, Read, Write};
use std::path::Path;

use flate2::read::GzDecoder;
use tar::EntryType;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    pub total_bytes: u64,
    pub files: usize,
    pub file_bytes: u64,
}

impl Default for Limits {
    fn default() -> Limits {
        Limits { total_bytes: 200 * 1024 * 1024, files: 5000, file_bytes: 50 * 1024 * 1024 }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InstallErrorKind {
    UnsafeEntry,
    TooLarge,
    BadArchive,
    Io,
}

/// A refusal in the words the user sees (design 3.2).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallError {
    pub kind: InstallErrorKind,
    pub message: String,
}

impl InstallError {
    fn unsafe_entry(what: &str, path: &str) -> InstallError {
        InstallError {
            kind: InstallErrorKind::UnsafeEntry,
            message: format!("Refused: the repository contains {what} at {path}. Add-ons may contain only plain files."),
        }
    }
    fn too_large(msg: String) -> InstallError {
        InstallError { kind: InstallErrorKind::TooLarge, message: msg }
    }
    fn bad(msg: impl Into<String>) -> InstallError {
        InstallError { kind: InstallErrorKind::BadArchive, message: msg.into() }
    }
}

impl std::fmt::Display for InstallError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl From<io::Error> for InstallError {
    fn from(e: io::Error) -> Self {
        InstallError { kind: InstallErrorKind::Io, message: format!("Could not write the add-on's files: {e}") }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Extracted {
    /// `(relative path, size)` in archive order.
    pub files: Vec<(String, u64)>,
    pub total: u64,
}

pub fn mb(n: u64) -> String {
    format!("{:.1} MB", n as f64 / (1024.0 * 1024.0))
}

#[derive(Debug, PartialEq, Eq)]
pub enum PathProblem {
    /// absolute, `..`, backslash, drive or UNC prefix, NUL
    Outside,
    /// device names, alternate streams, trailing dot or space, characters Windows refuses
    Reserved,
}

/// A path inside the repository, already without the top-level folder.
pub fn classify_path(rel: &str) -> Result<(), PathProblem> {
    if rel.is_empty() || rel.starts_with('/') || rel.contains('\\') || rel.contains('\0') {
        return Err(PathProblem::Outside);
    }
    let b = rel.as_bytes();
    // `C:` drive prefix (also `C:foo`), caught before the generic ':' rule
    if b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':' {
        return Err(PathProblem::Outside);
    }
    for seg in rel.split('/') {
        if seg.is_empty() || seg == "." || seg == ".." {
            return Err(PathProblem::Outside);
        }
        if is_reserved_segment(seg) {
            return Err(PathProblem::Reserved);
        }
    }
    Ok(())
}

pub fn is_reserved_segment(seg: &str) -> bool {
    if seg.ends_with('.') || seg.ends_with(' ') {
        return true;
    }
    if seg.chars().any(|c| c.is_control() || matches!(c, ':' | '<' | '>' | '|' | '?' | '*' | '"')) {
        return true;
    }
    let stem = seg.split('.').next().unwrap_or("").trim_end().to_ascii_uppercase();
    matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$")
        || (stem.len() == 4 && (stem.starts_with("COM") || stem.starts_with("LPT")) && stem.as_bytes()[3].is_ascii_digit())
}

/// Extracts `reader` (a `.tar.gz`) into `dest` (which must exist and be empty).
/// GitHub wraps everything in one top-level folder (`owner-repo-sha/`); it is
/// stripped. On any error the caller deletes `dest`.
pub fn extract_tar_gz<R: Read>(reader: R, dest: &Path, limits: Limits) -> Result<Extracted, InstallError> {
    let mut archive = tar::Archive::new(GzDecoder::new(reader));
    archive.set_preserve_permissions(false);
    archive.set_unpack_xattrs(false);
    let entries = archive.entries().map_err(|e| InstallError::bad(format!("The download is not a readable archive: {e}")))?;

    let mut out = Extracted { files: Vec::new(), total: 0 };
    // every path prefix seen so far (folders and files), by lowercase, with its spelling and kind
    let mut seen: HashMap<String, (String, bool)> = HashMap::new();
    let mut largest: (String, u64) = (String::new(), 0);
    let mut top: Option<String> = None;

    for entry in entries {
        let mut entry = entry.map_err(|e| InstallError::bad(format!("The download is not a readable archive: {e}")))?;
        let ty = entry.header().entry_type();
        // metadata records of the archive format, not files
        if matches!(ty, EntryType::XGlobalHeader | EntryType::XHeader | EntryType::GNULongName | EntryType::GNULongLink) {
            continue;
        }
        let raw = entry.path_bytes().into_owned();
        let Ok(full) = String::from_utf8(raw) else {
            return Err(InstallError::unsafe_entry("a file name that is not valid text", "(unreadable name)"));
        };
        let full_trim = full.trim_end_matches('/');
        // The FULL path is judged before anything is stripped: an absolute path, a `..` or
        // a drive prefix cannot hide in the part that GitHub's top folder would have been.
        let (top_name, rel) = match full_trim.split_once('/') {
            Some((t, r)) => (t, r),
            None => (full_trim, ""),
        };
        let top_ok = !full_trim.starts_with('/') && !top_name.is_empty() && top_name != "." && top_name != ".." && !top_name.contains(['\\', ':', '\0']) && !is_reserved_segment(top_name);
        if !top_ok {
            return Err(InstallError::unsafe_entry("a path outside the folder", &full));
        }
        match &top {
            None => top = Some(top_name.to_string()),
            Some(t) if t == top_name => {}
            Some(_) => return Err(InstallError::unsafe_entry("a file outside the top-level folder", &full)),
        }
        if rel.is_empty() {
            // the top-level folder entry itself
            if matches!(ty, EntryType::Directory) {
                continue;
            }
            return Err(InstallError::unsafe_entry("a file outside the top-level folder", &full));
        }
        // type before path: a link entry is refused as a link whatever it is named
        match ty {
            EntryType::Symlink => return Err(InstallError::unsafe_entry("a symbolic link", rel)),
            EntryType::Link => return Err(InstallError::unsafe_entry("a hard link", rel)),
            EntryType::Char | EntryType::Block | EntryType::Fifo => return Err(InstallError::unsafe_entry("a device or pipe", rel)),
            EntryType::Regular | EntryType::Continuous | EntryType::Directory => {}
            _ => return Err(InstallError::unsafe_entry("a special file", rel)),
        }
        match classify_path(rel) {
            Ok(()) => {}
            Err(PathProblem::Outside) => return Err(InstallError::unsafe_entry("a path outside the folder", rel)),
            Err(PathProblem::Reserved) => return Err(InstallError::unsafe_entry("a reserved file name", rel)),
        }
        let is_dir = matches!(ty, EntryType::Directory);
        // folders and files share one namespace: case-only twins and "file here, folder there" are refused
        let comps: Vec<&str> = rel.split('/').collect();
        for i in 1..=comps.len() {
            let prefix = comps[..i].join("/");
            let leaf_is_file = i == comps.len() && !is_dir;
            let key = prefix.to_lowercase();
            match seen.get(&key) {
                Some((spelled, was_file)) => {
                    if *spelled != prefix {
                        return Err(InstallError { kind: InstallErrorKind::UnsafeEntry, message: format!("Refused: {prefix} and {spelled} differ only in case.") });
                    }
                    if i == comps.len() && leaf_is_file {
                        return Err(InstallError { kind: InstallErrorKind::UnsafeEntry, message: format!("Refused: {rel} appears twice in the archive.") });
                    }
                    if *was_file || leaf_is_file && i < comps.len() {
                        return Err(InstallError { kind: InstallErrorKind::UnsafeEntry, message: format!("Refused: {prefix} is both a file and a folder.") });
                    }
                }
                None => {
                    seen.insert(key, (prefix.clone(), leaf_is_file));
                }
            }
        }
        let target = dest.join(rel);
        if is_dir {
            fs::create_dir_all(&target)?;
            continue;
        }
        if out.files.len() + 1 > limits.files {
            return Err(InstallError::too_large(format!("Too large to install: more than {} files (limit {}).", limits.files, limits.files)));
        }
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        // never follow anything that is already there
        let mut file = create_new_file(&target)?;
        let mut size: u64 = 0;
        let mut buf = [0u8; 64 * 1024];
        loop {
            let n = entry.read(&mut buf).map_err(|e| InstallError::bad(format!("The download is damaged: {e}")))?;
            if n == 0 {
                break;
            }
            size += n as u64;
            if size > limits.file_bytes {
                return Err(InstallError::too_large(format!("Too large to install: {rel} is more than {} (limit {} per file).", mb(limits.file_bytes), mb(limits.file_bytes))));
            }
            if out.total + size > limits.total_bytes {
                if size > largest.1 {
                    largest = (rel.to_string(), size);
                }
                let measured = out.total + size;
                let (lf, ls) = if largest.1 > 0 { largest.clone() } else { (rel.to_string(), size) };
                return Err(InstallError::too_large(format!("Too large to install: more than {} (limit {}). Largest file so far: {lf} ({}).", mb(measured), mb(limits.total_bytes), mb(ls))));
            }
            file.write_all(&buf[..n])?;
        }
        file.flush()?;
        drop(file);
        if size > largest.1 {
            largest = (rel.to_string(), size);
        }
        out.total += size;
        out.files.push((rel.to_string(), size));
    }
    if out.files.is_empty() {
        return Err(InstallError::bad("The repository at that commit has no files."));
    }
    Ok(out)
}

/// Creates a file only if it does not exist (never follows or overwrites
/// anything already there), with plain permissions: archive modes (setuid,
/// executable) are never applied.
fn create_new_file(path: &Path) -> io::Result<fs::File> {
    let mut o = fs::OpenOptions::new();
    o.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o644);
    }
    o.open(path)
}

/// Removes a staging directory after a refusal or a cancel.
pub fn discard(dir: &Path) {
    let _ = fs::remove_dir_all(dir);
}

pub fn staging_is_empty(dir: &Path) -> bool {
    fs::read_dir(dir).map(|mut d| d.next().is_none()).unwrap_or(false)
}

