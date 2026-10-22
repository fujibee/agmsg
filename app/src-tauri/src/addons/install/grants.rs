//! `<base>/addons/grants.tsv`: the grants a user chose to remember (design 2, 3.1).
//! `repo, sha, pane, permission, scope, granted_at`. "Only this time" grants are
//! never written. `scope` is a stable team name for `messages:read` and the real
//! path of a folder for `files:read`. Replaced atomically; a line that does not
//! parse is not a grant (fail closed).

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SavedGrant {
    pub repo: String,
    pub sha: String,
    pub pane: String,
    pub permission: String,
    pub scope: String,
    pub granted_at: String,
}

const GRANTABLE: [&str; 2] = ["messages:read", "files:read"];

fn clean(s: &str) -> bool {
    !s.is_empty() && !s.contains(['\t', '\n', '\r', '\0'])
}

impl SavedGrant {
    fn valid(&self) -> bool {
        clean(&self.repo) && self.repo.contains('/') && clean(&self.sha) && clean(&self.pane) && GRANTABLE.contains(&self.permission.as_str()) && clean(&self.scope) && clean(&self.granted_at)
    }

    fn line(&self) -> Option<String> {
        self.valid().then(|| [&self.repo, &self.sha, &self.pane, &self.permission, &self.scope, &self.granted_at].iter().map(|s| s.as_str()).collect::<Vec<_>>().join("\t"))
    }

    fn parse(line: &str) -> Option<SavedGrant> {
        let c: Vec<&str> = line.split('\t').collect();
        if c.len() != 6 {
            return None;
        }
        let g = SavedGrant { repo: c[0].into(), sha: c[1].into(), pane: c[2].into(), permission: c[3].into(), scope: c[4].into(), granted_at: c[5].into() };
        g.valid().then_some(g)
    }

    fn same_grant(&self, o: &SavedGrant) -> bool {
        self.repo == o.repo && self.pane == o.pane && self.permission == o.permission && self.scope == o.scope
    }
}

pub fn path(addons: &Path) -> PathBuf {
    addons.join("grants.tsv")
}

pub fn read(addons: &Path) -> Vec<SavedGrant> {
    let Ok(text) = fs::read_to_string(path(addons)) else { return Vec::new() };
    text.lines().filter(|l| !l.trim().is_empty() && !l.starts_with('#')).filter_map(SavedGrant::parse).collect()
}

pub fn write(addons: &Path, grants: &[SavedGrant]) -> io::Result<()> {
    fs::create_dir_all(addons)?;
    let mut body = String::new();
    for g in grants {
        body.push_str(&g.line().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid grant"))?);
        body.push('\n');
    }
    let tmp = addons.join(format!(".grants.tsv.{}.tmp", std::process::id()));
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(body.as_bytes())?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path(addons))
}

/// Remembers one grant (replacing an equal one).
pub fn add(addons: &Path, g: SavedGrant) -> io::Result<()> {
    let mut all = read(addons);
    all.retain(|x| !x.same_grant(&g));
    all.push(g);
    write(addons, &all)
}

pub fn revoke(addons: &Path, repo: &str, pane: &str, permission: &str, scope: &str) -> io::Result<bool> {
    let mut all = read(addons);
    let before = all.len();
    all.retain(|g| !(g.repo == repo && g.pane == pane && g.permission == permission && g.scope == scope));
    let changed = all.len() != before;
    if changed {
        write(addons, &all)?;
    }
    Ok(changed)
}

/// Forgets everything remembered for an add-on (Remove).
pub fn remove_repo(addons: &Path, repo: &str) -> io::Result<usize> {
    let mut all = read(addons);
    let before = all.len();
    all.retain(|g| g.repo != repo);
    let n = before - all.len();
    if n > 0 {
        write(addons, &all)?;
    }
    Ok(n)
}

pub fn for_pane(addons: &Path, repo: &str, pane: &str) -> Vec<SavedGrant> {
    read(addons).into_iter().filter(|g| g.repo == repo && g.pane == pane).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn g(repo: &str, pane: &str, perm: &str, scope: &str) -> SavedGrant {
        SavedGrant { repo: repo.into(), sha: "a".repeat(40), pane: pane.into(), permission: perm.into(), scope: scope.into(), granted_at: "2026-10-23T00:00:00Z".into() }
    }

    #[test]
    fn add_replace_revoke_and_remove() {
        let d = tempfile::tempdir().unwrap();
        assert!(read(d.path()).is_empty());
        add(d.path(), g("o/r", "main", "files:read", "/home/me/proj")).unwrap();
        add(d.path(), g("o/r", "main", "messages:read", "team-a")).unwrap();
        add(d.path(), g("x/y", "main", "files:read", "/home/me/proj")).unwrap();
        assert_eq!(read(d.path()).len(), 3);
        // the same grant again replaces, not duplicates
        add(d.path(), SavedGrant { sha: "b".repeat(40), ..g("o/r", "main", "files:read", "/home/me/proj") }).unwrap();
        let all = read(d.path());
        assert_eq!(all.len(), 3);
        assert_eq!(for_pane(d.path(), "o/r", "main").len(), 2);
        assert!(revoke(d.path(), "o/r", "main", "files:read", "/home/me/proj").unwrap());
        assert!(!revoke(d.path(), "o/r", "main", "files:read", "/home/me/proj").unwrap());
        assert_eq!(for_pane(d.path(), "o/r", "main").len(), 1);
        assert_eq!(remove_repo(d.path(), "o/r").unwrap(), 1);
        assert_eq!(read(d.path()).len(), 1);
        assert_eq!(read(d.path())[0].repo, "x/y");
    }

    #[test]
    fn only_remembered_kinds_with_clean_fields_can_be_written() {
        let d = tempfile::tempdir().unwrap();
        for bad in [
            g("o/r", "main", "network", "x"),
            g("o/r", "main", "git:read", "x"),
            g("o/r", "main", "files:read", ""),
            g("o/r", "main", "files:read", "a\tb"),
            g("o/r", "main", "files:read", "a\nb"),
            g("nobar", "main", "files:read", "/x"),
        ] {
            assert!(add(d.path(), bad).is_err());
        }
        assert!(!path(d.path()).exists());
    }

    #[test]
    fn unparsable_lines_are_not_grants() {
        let d = tempfile::tempdir().unwrap();
        let good = g("o/r", "main", "files:read", "/p").line().unwrap();
        fs::write(path(d.path()), format!("# c\n{good}\njunk\n{}\n{}\n", good.replace("files:read", "network"), good.replacen("\t/p\t", "\t\t", 1))).unwrap();
        assert_eq!(read(d.path()).len(), 1);
    }

    #[test]
    fn writes_leave_no_temp_files() {
        let d = tempfile::tempdir().unwrap();
        add(d.path(), g("o/r", "main", "files:read", "/p")).unwrap();
        let names: Vec<_> = fs::read_dir(d.path()).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        assert_eq!(names, vec!["grants.tsv".to_string()]);
    }
}
