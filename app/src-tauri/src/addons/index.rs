//! `<base>/addons/index.tsv`: what is installed (design 3.1). One line per
//! add-on: `owner/repo`, commit SHA, archive SHA-256, payload digest, panes,
//! permissions, network, installed_at, enabled. Tab separated; a line that does
//! not parse is not an installed add-on (fail closed), and the file is replaced
//! atomically so a crash never leaves half a table.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndexEntry {
    /// `owner/repo`
    pub repo: String,
    pub sha: String,
    pub archive_sha256: String,
    pub payload_digest: String,
    pub panes: Vec<String>,
    pub permissions: Vec<String>,
    pub network: String,
    pub installed_at: String,
    pub enabled: bool,
}

const COLS: usize = 9;

fn clean(s: &str) -> bool {
    !s.contains(['\t', '\n', '\r'])
}

fn valid_repo(s: &str) -> bool {
    let mut it = s.split('/');
    let (Some(o), Some(r), None) = (it.next(), it.next(), it.next()) else { return false };
    let ok = |p: &str| !p.is_empty() && p.len() <= 100 && p != "." && p != ".." && p.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.');
    ok(o) && ok(r)
}

fn valid_sha(s: &str) -> bool {
    s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

fn valid_hex64(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

impl IndexEntry {
    pub fn to_line(&self) -> Option<String> {
        let fields = [&self.repo, &self.sha, &self.archive_sha256, &self.payload_digest, &self.panes.join(","), &self.permissions.join(","), &self.network, &self.installed_at, &(if self.enabled { "1" } else { "0" }).to_string()];
        if !fields.iter().all(|f| clean(f)) || !valid_repo(&self.repo) || !valid_sha(&self.sha) || !valid_hex64(&self.archive_sha256) || !valid_hex64(&self.payload_digest) {
            return None;
        }
        Some(fields.iter().map(|f| f.as_str()).collect::<Vec<_>>().join("\t"))
    }

    fn from_line(line: &str) -> Option<IndexEntry> {
        let c: Vec<&str> = line.split('\t').collect();
        if c.len() != COLS {
            return None;
        }
        let list = |s: &str| s.split(',').map(str::to_string).filter(|x| !x.is_empty()).collect::<Vec<_>>();
        let e = IndexEntry {
            repo: c[0].to_string(),
            sha: c[1].to_string(),
            archive_sha256: c[2].to_string(),
            payload_digest: c[3].to_string(),
            panes: list(c[4]),
            permissions: list(c[5]),
            network: c[6].to_string(),
            installed_at: c[7].to_string(),
            enabled: match c[8] {
                "1" => true,
                "0" => false,
                _ => return None,
            },
        };
        e.to_line().map(|_| e)
    }

    /// Where the files of this entry live under `<base>/addons`.
    pub fn dir(&self, addons: &Path) -> PathBuf {
        let (o, r) = self.repo.split_once('/').unwrap_or(("", ""));
        addons.join(o).join(r).join(&self.sha)
    }
}

pub fn index_path(addons: &Path) -> PathBuf {
    addons.join("index.tsv")
}

/// Reads the table. A missing file is an empty table; unparsable lines are skipped.
pub fn read(addons: &Path) -> Vec<IndexEntry> {
    let Ok(text) = fs::read_to_string(index_path(addons)) else { return Vec::new() };
    let mut out: Vec<IndexEntry> = Vec::new();
    for line in text.lines() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(e) = IndexEntry::from_line(line) {
            // one version of an add-on at a time: the last line for a repo wins
            out.retain(|x| x.repo != e.repo);
            out.push(e);
        }
    }
    out
}

/// Replaces the table atomically (write a sibling, then rename over it).
pub fn write(addons: &Path, entries: &[IndexEntry]) -> io::Result<()> {
    fs::create_dir_all(addons)?;
    let mut body = String::new();
    for e in entries {
        let line = e.to_line().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, format!("index entry for {} has invalid fields", e.repo)))?;
        body.push_str(&line);
        body.push('\n');
    }
    let tmp = addons.join(format!(".index.tsv.{}.tmp", std::process::id()));
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(body.as_bytes())?;
        f.sync_all()?;
    }
    fs::rename(&tmp, index_path(addons))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(repo: &str, sha_char: char) -> IndexEntry {
        IndexEntry {
            repo: repo.into(),
            sha: sha_char.to_string().repeat(40),
            archive_sha256: "a".repeat(64),
            payload_digest: "b".repeat(64),
            panes: vec!["one".into(), "two".into()],
            permissions: vec!["files:read".into(), "network".into()],
            network: "https://a.test".into(),
            installed_at: "2026-10-23T00:00:00Z".into(),
            enabled: true,
        }
    }

    #[test]
    fn round_trip_and_atomic_replace() {
        let d = tempfile::tempdir().unwrap();
        assert!(read(d.path()).is_empty());
        let v = vec![entry("o/r", '1'), entry("x/y", '2')];
        write(d.path(), &v).unwrap();
        assert_eq!(read(d.path()), v);
        let v2 = vec![entry("o/r", '3')];
        write(d.path(), &v2).unwrap();
        assert_eq!(read(d.path()), v2);
        let leftovers: Vec<_> = fs::read_dir(d.path()).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        assert_eq!(leftovers, vec!["index.tsv".to_string()], "no temp file is left behind");
    }

    #[test]
    fn bad_lines_are_not_installed_add_ons() {
        let d = tempfile::tempdir().unwrap();
        let good = entry("o/r", '1').to_line().unwrap();
        let text = format!(
            "# header\n{good}\nnot a line\n{}\n{}\n{}\n{}\n",
            good.replace("o/r", "o/../r"),
            entry("x/y", '2').to_line().unwrap().replace("\t1", "\tyes"),
            good.replacen(&"1".repeat(40), "XYZ", 1),
            good.replacen(&"a".repeat(64), &"A".repeat(64), 1),
        );
        fs::write(index_path(d.path()), text).unwrap();
        let got = read(d.path());
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].repo, "o/r");
    }

    #[test]
    fn invalid_fields_cannot_be_written() {
        let d = tempfile::tempdir().unwrap();
        for bad in [
            IndexEntry { repo: "o/r\tx".into(), ..entry("o/r", '1') },
            IndexEntry { repo: "../r".into(), ..entry("o/r", '1') },
            IndexEntry { repo: "o".into(), ..entry("o/r", '1') },
            IndexEntry { sha: "short".into(), ..entry("o/r", '1') },
            IndexEntry { network: "a\nb".into(), ..entry("o/r", '1') },
            IndexEntry { payload_digest: "z".repeat(64), ..entry("o/r", '1') },
        ] {
            assert!(write(d.path(), &[bad]).is_err());
        }
        assert!(!index_path(d.path()).exists());
    }

    #[test]
    fn the_last_line_for_a_repo_wins_and_dir_is_under_addons() {
        let d = tempfile::tempdir().unwrap();
        fs::write(index_path(d.path()), format!("{}\n{}\n", entry("o/r", '1').to_line().unwrap(), entry("o/r", '2').to_line().unwrap())).unwrap();
        let got = read(d.path());
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].sha, "2".repeat(40));
        assert_eq!(got[0].dir(d.path()), d.path().join("o").join("r").join("2".repeat(40)));
    }

    #[test]
    fn disabled_entries_stay_in_the_table() {
        let d = tempfile::tempdir().unwrap();
        let mut e = entry("o/r", '1');
        e.enabled = false;
        write(d.path(), &[e.clone()]).unwrap();
        assert_eq!(read(d.path()), vec![e]);
    }
}
