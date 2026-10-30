//! Digest of an installed payload directory (design 3.1): sorted relative path
//! plus SHA-256 of every file. At each pane open the server hashes the pinned
//! directory and refuses to serve when it differs, so a half-written or partly
//! deleted directory never runs.

use sha2::{Digest, Sha256};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug)]
pub enum DigestError {
    Io(io::Error),
    /// A symlink, junction or special file inside the payload.
    NotPlain(PathBuf),
}

impl std::fmt::Display for DigestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DigestError::Io(e) => write!(f, "{e}"),
            DigestError::NotPlain(p) => write!(f, "{} is not a plain file or folder", p.display()),
        }
    }
}

impl From<io::Error> for DigestError {
    fn from(e: io::Error) -> Self {
        DigestError::Io(e)
    }
}

/// What the files of a payload hashed to when they were verified: one
/// `(sha256, size)` per relative path, and the digest of the whole tree. Both come
/// from the same reads, so whatever the tree digest vouched for is exactly what
/// the manifest pins, and the server can hold every file it serves to it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Manifest {
    pub files: std::collections::BTreeMap<String, (String, u64)>,
    pub digest: String,
}

impl Manifest {
    /// The entries under `prefix` (a folder, no trailing slash), keyed relative to it.
    pub fn under(&self, prefix: &str) -> std::collections::BTreeMap<String, (String, u64)> {
        let p = format!("{prefix}/");
        self.files.iter().filter_map(|(k, v)| k.strip_prefix(&p).map(|r| (r.to_string(), v.clone()))).collect()
    }
}

/// Hashes every file once and returns the manifest and the tree digest.
pub fn manifest(root: &Path) -> Result<Manifest, DigestError> {
    let mut files: Vec<(String, PathBuf)> = Vec::new();
    walk(root, root, &mut files)?;
    files.sort_by(|a, b| a.0.cmp(&b.0));
    let mut outer = Sha256::new();
    let mut m = std::collections::BTreeMap::new();
    for (rel, path) in files {
        let mut h = Sha256::new();
        let mut f = fs::File::open(&path)?;
        let size = io::copy(&mut f, &mut h)?;
        let fh = h.finalize();
        outer.update(rel.as_bytes());
        outer.update([0]);
        outer.update(fh);
        m.insert(rel, (hex(&fh), size));
    }
    Ok(Manifest { files: m, digest: hex(&outer.finalize()) })
}

/// Lowercase hex digest of the whole tree. Directories contribute nothing but
/// their files; an empty directory and a missing one hash the same, and the
/// caller checks the entry file separately.
pub fn payload_digest(root: &Path) -> Result<String, DigestError> {
    Ok(manifest(root)?.digest)
}

/// SHA-256 of bytes, lowercase hex.
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

fn walk(root: &Path, dir: &Path, out: &mut Vec<(String, PathBuf)>) -> Result<(), DigestError> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let meta = fs::symlink_metadata(&path)?;
        let ft = meta.file_type();
        if ft.is_symlink() {
            return Err(DigestError::NotPlain(path));
        }
        if ft.is_dir() {
            walk(root, &path, out)?;
        } else if ft.is_file() {
            let rel = path.strip_prefix(root).unwrap_or(&path);
            let rel: Vec<String> = rel.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
            out.push((rel.join("/"), path));
        } else {
            return Err(DigestError::NotPlain(path));
        }
    }
    Ok(())
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("agmsg-digest-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn same_tree_same_digest_and_any_change_differs() {
        let a = tmp("a");
        fs::create_dir_all(a.join("sub")).unwrap();
        fs::write(a.join("index.html"), "x").unwrap();
        fs::write(a.join("sub/f.js"), "y").unwrap();
        let d1 = payload_digest(&a).unwrap();
        assert_eq!(d1, payload_digest(&a).unwrap());
        assert_eq!(d1.len(), 64);
        fs::write(a.join("sub/f.js"), "z").unwrap();
        assert_ne!(d1, payload_digest(&a).unwrap());
        fs::write(a.join("sub/f.js"), "y").unwrap();
        assert_eq!(d1, payload_digest(&a).unwrap());
        fs::remove_file(a.join("sub/f.js")).unwrap();
        assert_ne!(d1, payload_digest(&a).unwrap());
        fs::write(a.join("extra"), "").unwrap();
        fs::write(a.join("sub/f.js"), "y").unwrap();
        assert_ne!(d1, payload_digest(&a).unwrap());
    }

    #[test]
    fn a_moved_file_changes_the_digest() {
        let a = tmp("moved");
        fs::write(a.join("a"), "same").unwrap();
        let d1 = payload_digest(&a).unwrap();
        fs::rename(a.join("a"), a.join("b")).unwrap();
        assert_ne!(d1, payload_digest(&a).unwrap());
    }

    #[test]
    fn the_manifest_pins_each_file_and_agrees_with_the_tree_digest() {
        let a = tmp("manifest");
        fs::create_dir_all(a.join("web")).unwrap();
        fs::write(a.join("addon.conf"), "c").unwrap();
        fs::write(a.join("web/index.html"), "hello").unwrap();
        let m = manifest(&a).unwrap();
        assert_eq!(m.digest, payload_digest(&a).unwrap());
        assert_eq!(m.files["web/index.html"], (sha256_hex(b"hello"), 5));
        assert_eq!(m.files["addon.conf"].1, 1);
        let web = m.under("web");
        assert_eq!(web.len(), 1);
        assert_eq!(web["index.html"].0, sha256_hex(b"hello"));
        assert!(m.under("nope").is_empty());
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_are_refused() {
        let a = tmp("link");
        fs::write(a.join("a"), "x").unwrap();
        std::os::unix::fs::symlink("/etc/hosts", a.join("l")).unwrap();
        assert!(matches!(payload_digest(&a), Err(DigestError::NotPlain(_))));
    }
}
