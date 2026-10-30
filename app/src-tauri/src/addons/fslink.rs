//! How many names a file has. `std` exposes the link count only on Unix, so
//! Windows asks the file handle (`nNumberOfLinks`). A count that cannot be read
//! is reported as an error and callers treat it as "more than one".

use std::io;
use std::path::Path;

#[cfg(unix)]
pub fn link_count(path: &Path) -> io::Result<u64> {
    use std::os::unix::fs::MetadataExt;
    Ok(std::fs::symlink_metadata(path)?.nlink())
}

#[cfg(windows)]
pub fn link_count(path: &Path) -> io::Result<u64> {
    use std::os::windows::io::AsRawHandle;
    use windows::Win32::Foundation::HANDLE;
    use windows::Win32::Storage::FileSystem::{GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION};

    let file = std::fs::File::open(path)?;
    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    unsafe { GetFileInformationByHandle(HANDLE(file.as_raw_handle()), &mut info) }.map_err(|e| io::Error::other(e.to_string()))?;
    Ok(u64::from(info.nNumberOfLinks))
}

/// The plain spelling of a canonical Windows path for tools that do not take the
/// verbatim form: `\\?\C:\x` becomes `C:\x` and `\\?\UNC\h\s` becomes `\\h\s`. Any
/// other path is returned as it is.
pub fn plain(path: &Path) -> std::path::PathBuf {
    let s = path.to_string_lossy();
    if let Some(rest) = s.strip_prefix(r"\\?\UNC\") {
        return std::path::PathBuf::from(format!(r"\\{rest}"));
    }
    if let Some(rest) = s.strip_prefix(r"\\?\") {
        let b = rest.as_bytes();
        if b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':' {
            return std::path::PathBuf::from(rest);
        }
    }
    path.to_path_buf()
}

/// True when the file has more than one name, or when that cannot be told.
pub fn has_other_names(path: &Path) -> bool {
    link_count(path).map_or(true, |n| n > 1)
}

/// Test helpers shared by the Windows path tests.
#[cfg(all(test, windows))]
pub(crate) mod win_test {
    use std::path::{Path, PathBuf};

    /// The 8.3 alias of an existing path, or `None` when the volume has none.
    pub fn short_path(p: &Path) -> Option<PathBuf> {
        use std::os::windows::ffi::{OsStrExt, OsStringExt};
        use windows::core::PCWSTR;
        use windows::Win32::Storage::FileSystem::GetShortPathNameW;
        let wide: Vec<u16> = p.as_os_str().encode_wide().chain(Some(0)).collect();
        let n = unsafe { GetShortPathNameW(PCWSTR(wide.as_ptr()), None) };
        if n == 0 {
            return None;
        }
        let mut buf = vec![0u16; n as usize];
        let m = unsafe { GetShortPathNameW(PCWSTR(wide.as_ptr()), Some(&mut buf)) };
        if m == 0 || m as usize > buf.len() {
            return None;
        }
        let short = PathBuf::from(std::ffi::OsString::from_wide(&buf[..m as usize]));
        (short != p).then_some(short)
    }

    /// `mklink /J link target` (a junction needs no privilege).
    pub fn junction(link: &Path, target: &Path) {
        let out = std::process::Command::new("cmd").arg("/C").arg("mklink").arg("/J").arg(link).arg(target).output().unwrap();
        assert!(out.status.success(), "mklink /J failed: {}", String::from_utf8_lossy(&out.stdout));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_plain_file_has_one_name_and_a_hard_link_makes_two() {
        let d = tempfile::tempdir().unwrap();
        let a = d.path().join("a.txt");
        std::fs::write(&a, b"x").unwrap();
        assert_eq!(link_count(&a).unwrap(), 1);
        assert!(!has_other_names(&a));
        let b = d.path().join("b.txt");
        std::fs::hard_link(&a, &b).unwrap();
        assert_eq!(link_count(&a).unwrap(), 2);
        assert!(has_other_names(&a));
        assert!(has_other_names(&b));
    }

    #[test]
    fn the_verbatim_prefix_is_dropped_only_where_it_is_plain() {
        let p = |s: &str| plain(Path::new(s)).to_string_lossy().into_owned();
        assert_eq!(p(r"\\?\C:\Users\x\repo"), r"C:\Users\x\repo");
        assert_eq!(p(r"\\?\UNC\host\share\repo"), r"\\host\share\repo");
        assert_eq!(p(r"\\?\Volume{1234}\repo"), r"\\?\Volume{1234}\repo");
        assert_eq!(p("/home/x/repo"), "/home/x/repo");
        assert_eq!(p(r"C:\Users"), r"C:\Users");
    }

    #[test]
    fn a_missing_file_counts_as_not_safe() {
        let d = tempfile::tempdir().unwrap();
        assert!(has_other_names(&d.path().join("nope")));
    }
}
