//! The list of locations an add-on can never read (design: "Denied paths").
//!
//! There is no OS or industry list of "secret" places, so agmsg keeps its own.
//! Everything is matched on real paths: a path is resolved (symlinks, junctions,
//! `..`) before it is compared, case-insensitively on macOS and Windows. A path
//! that does not exist yet is resolved as far as it exists and the rest is
//! compared lexically, so an entry such as `~/.kube` protects a folder that is
//! created later.
//!
//! Entry kinds:
//! - `Subtree`: the path and every descendant.
//! - `File`: exactly that one file.
//! - `Glob`: one path component holds a `*`; the match and everything below it.
//! - `RootOnly` (`/`, `C:\`): refused as a granted root, nothing else. The paths
//!   below such a root (a project under `/Volumes/work`) are not denied by it.
//!
//! The home folder itself is not an entry: it can be granted, and its protected
//! children stay invisible inside it.

use std::ffi::OsStr;
use std::path::{Component, Path, PathBuf};
use std::sync::OnceLock;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MatchKind {
    Subtree,
    File,
    Glob,
    RootOnly,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Os {
    MacOs,
    Windows,
    Linux,
}

impl Os {
    pub fn host() -> Os {
        if cfg!(target_os = "macos") {
            Os::MacOs
        } else if cfg!(windows) {
            Os::Windows
        } else {
            Os::Linux
        }
    }

    fn case_insensitive(self) -> bool {
        matches!(self, Os::MacOs | Os::Windows)
    }
}

/// What the table is expanded with. Tests build one over a temporary home.
#[derive(Debug, Clone)]
pub struct DenyEnv {
    pub os: Os,
    /// `~`; USERPROFILE on Windows.
    pub home: Option<PathBuf>,
    pub appdata: Option<PathBuf>,
    pub local_appdata: Option<PathBuf>,
    pub system_drive: Option<String>,
    pub system_root: Option<PathBuf>,
    pub program_data: Option<PathBuf>,
    /// Further subtrees the app itself must protect: the agmsg home (stores,
    /// `addons/`), the app bundle or install directory, the app's data directory.
    pub extra_subtrees: Vec<PathBuf>,
}

impl DenyEnv {
    pub fn from_process(extra_subtrees: Vec<PathBuf>) -> DenyEnv {
        let var = |k: &str| {
            std::env::var_os(k)
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        };
        let os = Os::host();
        DenyEnv {
            os,
            home: if os == Os::Windows {
                var("USERPROFILE")
            } else {
                var("HOME")
            },
            appdata: var("APPDATA"),
            local_appdata: var("LOCALAPPDATA"),
            system_drive: std::env::var("SystemDrive").ok().filter(|v| !v.is_empty()),
            system_root: var("SystemRoot"),
            program_data: var("ProgramData"),
            extra_subtrees,
        }
    }
}

const COMMON: &[(MatchKind, &str)] = &[
    // keys and cloud credentials
    (MatchKind::Subtree, "~/.ssh"),
    (MatchKind::Subtree, "~/.gnupg"),
    (MatchKind::Subtree, "~/.aws"),
    (MatchKind::Subtree, "~/.azure"),
    (MatchKind::Subtree, "~/.config/gcloud"),
    (MatchKind::Subtree, "~/.kube"),
    (MatchKind::File, "~/.docker/config.json"),
    (MatchKind::Subtree, "~/.oci"),
    (MatchKind::Subtree, "~/.terraform.d"),
    (MatchKind::File, "~/.vault-token"),
    // tokens in dot files
    (MatchKind::File, "~/.netrc"),
    (MatchKind::File, "~/.git-credentials"),
    (MatchKind::File, "~/.npmrc"),
    (MatchKind::File, "~/.yarnrc.yml"),
    (MatchKind::File, "~/.pypirc"),
    (MatchKind::File, "~/.gem/credentials"),
    (MatchKind::Glob, "~/.cargo/credentials*"),
    (MatchKind::Subtree, "~/.config/gh"),
    (MatchKind::Subtree, "~/.config/hub"),
    (MatchKind::Subtree, "~/.password-store"),
    // agent secrets
    (MatchKind::Glob, "~/.claude*"),
    (MatchKind::Glob, "~/.codex*"),
    (MatchKind::Subtree, "~/.gemini"),
    (MatchKind::Subtree, "~/.config/claude"),
];

const MACOS: &[(MatchKind, &str)] = &[
    (MatchKind::RootOnly, "/"),
    (MatchKind::RootOnly, "/System"),
    (MatchKind::RootOnly, "/Library"),
    (MatchKind::RootOnly, "/private"),
    (MatchKind::RootOnly, "/Volumes"),
    (MatchKind::Subtree, "~/Library/Keychains"),
    (
        MatchKind::Subtree,
        "~/Library/Application Support/Google/Chrome",
    ),
    (MatchKind::Subtree, "~/Library/Application Support/Chromium"),
    (
        MatchKind::Subtree,
        "~/Library/Application Support/BraveSoftware",
    ),
    (
        MatchKind::Subtree,
        "~/Library/Application Support/Microsoft Edge",
    ),
    (MatchKind::Subtree, "~/Library/Application Support/Firefox"),
    (MatchKind::Subtree, "~/Library/Application Support/Arc"),
    (MatchKind::Subtree, "~/Library/Safari"),
    (MatchKind::Subtree, "~/Library/Cookies"),
    (MatchKind::Glob, "~/Library/Group Containers/*1password*"),
    (MatchKind::Subtree, "~/Library/Mail"),
    (MatchKind::Subtree, "~/Library/Messages"),
];

const WINDOWS: &[(MatchKind, &str)] = &[
    (MatchKind::RootOnly, "%SystemDrive%/"),
    (MatchKind::RootOnly, "%SystemRoot%"),
    (MatchKind::RootOnly, "%ProgramData%"),
    (MatchKind::Subtree, "%APPDATA%/GitHub CLI"),
    (MatchKind::Subtree, "%APPDATA%/Microsoft/Credentials"),
    (MatchKind::Subtree, "%LOCALAPPDATA%/Microsoft/Credentials"),
    (MatchKind::Subtree, "%APPDATA%/Microsoft/Protect"),
    (MatchKind::Subtree, "%APPDATA%/Microsoft/Crypto"),
    (MatchKind::Subtree, "%LOCALAPPDATA%/Google/Chrome/User Data"),
    (MatchKind::Subtree, "%LOCALAPPDATA%/Chromium/User Data"),
    (MatchKind::Subtree, "%LOCALAPPDATA%/BraveSoftware/User Data"),
    (
        MatchKind::Subtree,
        "%LOCALAPPDATA%/Microsoft/Edge/User Data",
    ),
    (MatchKind::Subtree, "%APPDATA%/Mozilla/Firefox/Profiles"),
    (MatchKind::Subtree, "%LOCALAPPDATA%/1Password"),
];

// UNREVIEWED: not in the written list. The same kinds of places on Linux; the app
// ships no Linux build, so nobody has checked this table.
const LINUX: &[(MatchKind, &str)] = &[
    (MatchKind::RootOnly, "/"),
    (MatchKind::Subtree, "~/.local/share/keyrings"),
    (MatchKind::Subtree, "~/.mozilla"),
    (MatchKind::Subtree, "~/.config/google-chrome"),
    (MatchKind::Subtree, "~/.config/chromium"),
    (MatchKind::Subtree, "~/.config/BraveSoftware"),
    (MatchKind::Subtree, "~/.config/microsoft-edge"),
    (MatchKind::Subtree, "~/.config/1Password"),
];

/// Expand `~` and `%VAR%` in the first component of a table pattern. `None` when
/// the variable is not known on this machine (the entry is then skipped; its
/// location does not exist here).
fn expand(pattern: &str, env: &DenyEnv) -> Option<PathBuf> {
    let mut parts = pattern.split('/');
    let first = parts.next()?;
    let mut base: PathBuf = if first.is_empty() {
        PathBuf::from("/")
    } else if first == "~" {
        env.home.clone()?
    } else if let Some(name) = first.strip_prefix('%').and_then(|s| s.strip_suffix('%')) {
        match name {
            "APPDATA" => env.appdata.clone()?,
            "LOCALAPPDATA" => env.local_appdata.clone()?,
            "SystemRoot" => env.system_root.clone()?,
            "ProgramData" => env.program_data.clone()?,
            "SystemDrive" => PathBuf::from(format!("{}\\", env.system_drive.as_deref()?)),
            _ => return None,
        }
    } else {
        return None;
    };
    for p in parts.filter(|p| !p.is_empty()) {
        base.push(p);
    }
    Some(base)
}

/// Lower-cased, verbatim-prefix-free components, for comparison.
fn components(path: &Path, fold: bool) -> Vec<String> {
    let mut out = Vec::new();
    for c in path.components() {
        let s = match c {
            Component::Prefix(p) => {
                let t = p.as_os_str().to_string_lossy().into_owned();
                t.strip_prefix(r"\\?\").unwrap_or(&t).to_string()
            }
            Component::RootDir => "/".to_string(),
            Component::CurDir => continue,
            Component::ParentDir => "..".to_string(),
            Component::Normal(s) => s.to_string_lossy().into_owned(),
        };
        out.push(if fold { s.to_lowercase() } else { s });
    }
    out
}

/// `*` matches any run of characters within one component.
fn wildcard(pattern: &str, text: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let t: Vec<char> = text.chars().collect();
    let (mut pi, mut ti, mut star, mut mark) = (0, 0, None, 0);
    while ti < t.len() {
        if pi < p.len() && p[pi] == '*' {
            star = Some(pi);
            mark = ti;
            pi += 1;
        } else if pi < p.len() && p[pi] == t[ti] {
            pi += 1;
            ti += 1;
        } else if let Some(s) = star {
            pi = s + 1;
            mark += 1;
            ti = mark;
        } else {
            return false;
        }
    }
    while pi < p.len() && p[pi] == '*' {
        pi += 1;
    }
    pi == p.len()
}

#[derive(Debug, Clone)]
struct Entry {
    kind: MatchKind,
    /// The entry as written: a lexical path under the canonical home. Its real
    /// places are worked out when the list is used, never kept: a parent can turn
    /// into a link, and a protected folder can be created, after the list is built.
    path: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reason {
    pub entry: PathBuf,
    pub kind: MatchKind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GrantCheck {
    Ok,
    Denied(Reason),
}

impl GrantCheck {
    pub fn is_ok(&self) -> bool {
        matches!(self, GrantCheck::Ok)
    }
}

/// `.env` or `.env.<anything>`, compared as the denylist compares (already folded where it folds).
fn is_env_name(component: &str) -> bool {
    component == ".env" || component.starts_with(".env.")
}

/// A `.env` file or folder by name, whatever the case: the ones the notice about a folder looks for.
pub fn is_env_file_name(name: &str) -> bool {
    let lower = name.to_lowercase();
    is_env_name(&lower)
}

/// The message shown when a path is refused.
pub fn refusal_message(path: &Path) -> String {
    if path.components().any(|c| c.as_os_str().to_str().is_some_and(is_env_file_name)) {
        return format!(
            "{} is an environment file (.env). Add-ons that use the network can't read it.",
            path.display()
        );
    }
    format!(
        "{} is on agmsg's list of protected locations (keys, credentials, browser data). Add-ons can't read it.",
        path.display()
    )
}

#[derive(Debug, Clone)]
pub struct Denylist {
    fold: bool,
    entries: Vec<Entry>,
    /// Also refuse `.env` / `.env.*` anywhere (see `with_env_files`). Off for the list every other caller uses.
    env_files: bool,
}

impl Denylist {
    pub fn new(env: &DenyEnv) -> Denylist {
        let fold = env.os.case_insensitive();
        let os_table = match env.os {
            Os::MacOs => MACOS,
            Os::Windows => WINDOWS,
            Os::Linux => LINUX,
        };
        // The home is compared in its real form, so entries under it follow it
        // even when it is reached through a link (/var -> /private/var).
        let real_home = env
            .home
            .as_ref()
            .map(|h| h.canonicalize().unwrap_or_else(|_| h.clone()));
        let env_real = DenyEnv {
            home: real_home,
            ..env.clone()
        };

        let mut entries = Vec::new();
        for (kind, pat) in COMMON.iter().chain(os_table.iter()) {
            if let Some(path) = expand(pat, &env_real) {
                entries.push(Entry { kind: *kind, path });
            }
        }
        for extra in &env.extra_subtrees {
            entries.push(Entry {
                kind: MatchKind::Subtree,
                path: extra.clone(),
            });
        }
        Denylist { fold, entries, env_files: false }
    }

    /// This list plus the rule for a pane that declares `network`: a file or folder
    /// named `.env` or `.env.*`, at any depth, is refused like a protected location
    /// (read, stat, listing, and git show/diff of the same path). It is decided on
    /// the resolved path and on the path as named, so a link to a `.env` is refused
    /// and a link named `.env` is too. Case is folded where the denylist folds it.
    pub fn with_env_files(&self) -> Denylist {
        Denylist { env_files: true, ..self.clone() }
    }

    /// Build from the process environment, plus the app's own protected folders.
    pub fn from_process_env(extra_subtrees: Vec<PathBuf>) -> Denylist {
        Denylist::new(&DenyEnv::from_process(extra_subtrees))
    }

    /// The list as it is on disk right now: every entry's real places, worked out
    /// from the longest existing prefix of its path (so a link above an entry, or
    /// an entry created later, is followed), and for a glob the real targets of
    /// the names that match. Take one for a batch of checks; take a new one for
    /// the next batch.
    pub fn snapshot(&self) -> Snapshot {
        let entries = self
            .entries
            .iter()
            .map(|e| (e.kind, e.path.clone(), entry_forms(e, self.fold)))
            .collect();
        Snapshot {
            fold: self.fold,
            entries,
            env_files: self.env_files,
        }
    }

    pub fn is_denied(&self, path: &Path) -> bool {
        self.snapshot().is_denied(path)
    }

    /// Is any segment of this relative path (as named, links not followed) a `.env` name that this list refuses?
    /// The path may be one a link would hide from the resolved form, so callers ask this before resolving.
    pub fn refuses_env_name(&self, rel: &str) -> bool {
        self.env_files
            && rel.split(['/', '\\']).any(|seg| {
                let seg = if self.fold { seg.to_lowercase() } else { seg.to_string() };
                is_env_name(&seg)
            })
    }

    pub fn check_grant_root(&self, path: &Path) -> GrantCheck {
        self.snapshot().check_grant_root(path)
    }

    pub fn filter_children<I, S>(&self, dir: &Path, names: I) -> Vec<S>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        self.snapshot().filter_children(dir, names)
    }

    pub fn is_denied_repo_path(&self, worktree_root: &Path, rel: &str) -> bool {
        self.snapshot().is_denied_repo_path(worktree_root, rel)
    }
}

/// Component forms to compare a path against: the lexical entry, its resolved
/// location, and (glob) the real target of each name that matches today.
fn entry_forms(e: &Entry, fold: bool) -> Vec<Vec<String>> {
    let mut forms = vec![components(&e.path, fold)];
    if e.kind == MatchKind::Glob {
        if let (Some(parent), Some(last)) = (e.path.parent(), e.path.file_name()) {
            let real_parent = resolve(parent);
            forms.push(components(&real_parent.join(last), fold));
            let pat = if fold {
                last.to_string_lossy().to_lowercase()
            } else {
                last.to_string_lossy().into_owned()
            };
            if let Ok(rd) = std::fs::read_dir(&real_parent) {
                for entry in rd.flatten() {
                    let name = entry.file_name().to_string_lossy().into_owned();
                    let cmp = if fold { name.to_lowercase() } else { name };
                    if wildcard(&pat, &cmp) {
                        if let Ok(real) = entry.path().canonicalize() {
                            forms.push(components(&real, fold));
                        }
                    }
                }
            }
        }
    } else {
        forms.push(components(&resolve(&e.path), fold));
    }
    forms.dedup();
    let mut seen = Vec::new();
    for f in forms {
        if !seen.contains(&f) {
            seen.push(f);
        }
    }
    seen
}

/// The list resolved against the disk at one moment (see `Denylist::snapshot`).
pub struct Snapshot {
    fold: bool,
    entries: Vec<(MatchKind, PathBuf, Vec<Vec<String>>)>,
    env_files: bool,
}

impl Snapshot {
    fn matches(kind: MatchKind, forms: &[Vec<String>], p: &[String]) -> bool {
        forms.iter().any(|e| match kind {
            MatchKind::Subtree => p.len() >= e.len() && p[..e.len()] == e[..],
            MatchKind::File | MatchKind::RootOnly => p == &e[..],
            MatchKind::Glob => {
                p.len() >= e.len()
                    && e.iter().zip(p).all(|(pat, comp)| {
                        if pat.contains('*') {
                            wildcard(pat, comp)
                        } else {
                            pat == comp
                        }
                    })
            }
        })
    }

    /// The first protected entry the path falls under (a root-only entry does not
    /// count here: it only refuses a root).
    fn find(&self, path: &Path, roots_too: bool) -> Option<Reason> {
        let lexical = absolute(path);
        let resolved = resolve(path);
        let candidates = [
            components(&resolved, self.fold),
            components(&lexical, self.fold),
        ];
        if self.env_files && candidates.iter().any(|c| c.iter().any(|comp| is_env_name(comp))) {
            return Some(Reason {
                entry: PathBuf::from(".env"),
                kind: MatchKind::File,
            });
        }
        for (kind, shown, forms) in &self.entries {
            if *kind == MatchKind::RootOnly && !roots_too {
                continue;
            }
            if candidates.iter().any(|c| Self::matches(*kind, forms, c)) {
                return Some(Reason {
                    entry: shown.clone(),
                    kind: *kind,
                });
            }
        }
        None
    }

    /// Is `path` (or anything above it that is protected) off limits?
    pub fn is_denied(&self, path: &Path) -> bool {
        self.find(path, false).is_some()
    }

    /// May `path` be granted as a root? Refused when it is protected, is inside a
    /// protected place (a single file in `~/.ssh`), or is a root-only entry.
    /// The home folder passes: its protected children are filtered later.
    pub fn check_grant_root(&self, path: &Path) -> GrantCheck {
        match self.find(path, true) {
            Some(r) => GrantCheck::Denied(r),
            None => GrantCheck::Ok,
        }
    }

    /// Keep the children of `dir` that are not protected. A child that is a
    /// symlink into a protected place is judged by where it leads.
    pub fn filter_children<I, S>(&self, dir: &Path, names: I) -> Vec<S>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<OsStr>,
    {
        let real_dir = resolve(dir);
        names
            .into_iter()
            .filter(|n| {
                let child = real_dir.join(n.as_ref());
                !self.is_denied(&child)
            })
            .collect()
    }

    /// For a path that came out of git history and may not exist on disk: `rel`
    /// is relative to the worktree root. Anything that is not a plain relative
    /// path is refused, and a path through a symlink that exists today is judged
    /// by where it leads.
    pub fn is_denied_repo_path(&self, worktree_root: &Path, rel: &str) -> bool {
        let rel_path = Path::new(rel);
        let plain = !rel.is_empty()
            && rel_path
                .components()
                .all(|c| matches!(c, Component::Normal(_) | Component::CurDir));
        if !plain {
            return true;
        }
        self.is_denied(&worktree_root.join(rel_path))
    }
}

fn absolute(path: &Path) -> PathBuf {
    std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf())
}

/// The real path: the longest existing prefix canonicalized, the rest appended
/// lexically (`.` dropped, `..` popped).
pub(crate) fn resolve(path: &Path) -> PathBuf {
    let abs = absolute(path);
    if let Ok(real) = abs.canonicalize() {
        return real;
    }
    let parts: Vec<Component> = abs.components().collect();
    for keep in (1..parts.len()).rev() {
        let prefix: PathBuf = parts[..keep].iter().collect();
        if let Ok(mut out) = prefix.canonicalize() {
            for part in &parts[keep..] {
                match part {
                    Component::ParentDir => {
                        out.pop();
                    }
                    Component::CurDir => {}
                    other => out.push(other.as_os_str()),
                }
            }
            return out;
        }
    }
    abs
}

// ---- process-wide list ----

static GLOBAL: OnceLock<Denylist> = OnceLock::new();

/// Install the list the free functions use (with the app's own folders). Only the
/// first call wins; call it at startup.
pub fn set_global(list: Denylist) -> Result<(), Denylist> {
    GLOBAL.set(list)
}

fn global() -> &'static Denylist {
    GLOBAL.get_or_init(|| Denylist::from_process_env(Vec::new()))
}

pub fn is_denied(path: &Path) -> bool {
    global().is_denied(path)
}

pub fn check_grant_root(path: &Path) -> GrantCheck {
    global().check_grant_root(path)
}

pub fn filter_children<I, S>(dir: &Path, names: I) -> Vec<S>
where
    I: IntoIterator<Item = S>,
    S: AsRef<OsStr>,
{
    global().filter_children(dir, names)
}

pub fn is_denied_repo_path(worktree_root: &Path, rel: &str) -> bool {
    global().is_denied_repo_path(worktree_root, rel)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    struct Home {
        _dir: tempfile::TempDir,
        home: PathBuf,
    }

    fn home() -> Home {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().canonicalize().unwrap().join("home");
        fs::create_dir_all(&home).unwrap();
        Home { _dir: dir, home }
    }

    fn env(h: &Home, os: Os) -> DenyEnv {
        DenyEnv {
            os,
            home: Some(h.home.clone()),
            appdata: Some(h.home.join("AppData/Roaming")),
            local_appdata: Some(h.home.join("AppData/Local")),
            system_drive: Some("C:".into()),
            system_root: Some(PathBuf::from("C:\\Windows")),
            program_data: Some(PathBuf::from("C:\\ProgramData")),
            extra_subtrees: Vec::new(),
        }
    }

    fn list(h: &Home, os: Os) -> Denylist {
        Denylist::new(&env(h, os))
    }

    #[test]
    fn expands_tilde_and_percent_variables() {
        let h = home();
        let e = env(&h, Os::Windows);
        assert_eq!(expand("~/.ssh", &e).unwrap(), h.home.join(".ssh"));
        assert_eq!(
            expand("%APPDATA%/GitHub CLI", &e).unwrap(),
            h.home.join("AppData/Roaming/GitHub CLI")
        );
        assert_eq!(expand("%SystemDrive%/", &e).unwrap(), PathBuf::from("C:\\"));
        assert_eq!(expand("%NOPE%/x", &e), None);
        let none = DenyEnv { home: None, ..e };
        assert_eq!(
            expand("~/.ssh", &none),
            None,
            "an unknown home skips the entry"
        );
    }

    #[test]
    fn wildcard_matches_inside_one_component() {
        assert!(wildcard(".claude*", ".claude"));
        assert!(wildcard(".claude*", ".claude-accounts"));
        assert!(!wildcard(".claude*", "claude"));
        assert!(wildcard("*1password*", "group.com.1password.x"));
        assert!(wildcard("credentials*", "credentials.toml"));
        assert!(!wildcard("credentials*", "config.toml"));
    }

    #[test]
    fn a_direct_file_grant_inside_a_protected_folder_is_refused() {
        let h = home();
        fs::create_dir_all(h.home.join(".ssh")).unwrap();
        fs::write(h.home.join(".ssh/id_ed25519"), "k").unwrap();
        let d = list(&h, Os::MacOs);
        assert!(!d.check_grant_root(&h.home.join(".ssh/id_ed25519")).is_ok());
        assert!(!d.check_grant_root(&h.home.join(".ssh")).is_ok());
        assert!(d.is_denied(&h.home.join(".ssh/id_ed25519")));
    }

    #[test]
    fn the_home_can_be_granted_and_hides_what_is_protected() {
        let h = home();
        for dir in [".ssh", ".aws", "proj", ".claude-accounts"] {
            fs::create_dir_all(h.home.join(dir)).unwrap();
        }
        fs::write(h.home.join(".netrc"), "x").unwrap();
        fs::write(h.home.join("notes.txt"), "x").unwrap();
        let d = list(&h, Os::MacOs);
        assert_eq!(d.check_grant_root(&h.home), GrantCheck::Ok);
        let names = [
            ".ssh",
            ".aws",
            "proj",
            ".claude-accounts",
            ".netrc",
            "notes.txt",
            ".gitconfig",
        ];
        assert_eq!(
            d.filter_children(&h.home, names),
            vec!["proj", "notes.txt", ".gitconfig"]
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_symlink_from_a_granted_root_into_a_protected_folder_is_denied() {
        let h = home();
        fs::create_dir_all(h.home.join(".ssh")).unwrap();
        fs::write(h.home.join(".ssh/id_rsa"), "k").unwrap();
        let proj = h.home.join("proj");
        fs::create_dir_all(&proj).unwrap();
        fs::write(proj.join("ok.txt"), "x").unwrap();
        std::os::unix::fs::symlink(h.home.join(".ssh"), proj.join("link")).unwrap();
        std::os::unix::fs::symlink(h.home.join(".ssh/id_rsa"), proj.join("key")).unwrap();
        let d = list(&h, Os::MacOs);
        assert_eq!(d.check_grant_root(&proj), GrantCheck::Ok);
        assert!(d.is_denied(&proj.join("link")));
        assert!(d.is_denied(&proj.join("link/id_rsa")));
        assert!(d.is_denied(&proj.join("key")));
        assert_eq!(
            d.filter_children(&proj, ["link", "key", "ok.txt"]),
            vec!["ok.txt"]
        );
        assert!(
            !d.check_grant_root(&proj.join("link")).is_ok(),
            "a granted root that is the link is refused too"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_protected_folder_that_is_itself_a_symlink_protects_its_target() {
        let h = home();
        let vault = h.home.join("vault-ssh");
        fs::create_dir_all(&vault).unwrap();
        fs::write(vault.join("id"), "k").unwrap();
        std::os::unix::fs::symlink(&vault, h.home.join(".ssh")).unwrap();
        let d = list(&h, Os::Linux);
        assert!(d.is_denied(&h.home.join(".ssh/id")));
        assert!(
            d.is_denied(&vault.join("id")),
            "the real location is protected as well"
        );
    }

    #[test]
    fn an_entry_that_does_not_exist_yet_is_matched_lexically_under_the_home() {
        let h = home();
        let d = list(&h, Os::Linux);
        assert!(!h.home.join(".kube").exists());
        assert!(d.is_denied(&h.home.join(".kube/config")));
        assert!(!d.check_grant_root(&h.home.join(".kube")).is_ok());
        assert!(d.is_denied(&h.home.join(".aws/credentials")));
        assert!(!d.is_denied(&h.home.join("kube/config")));
    }

    #[test]
    fn file_entries_match_only_that_file() {
        let h = home();
        let d = list(&h, Os::Linux);
        assert!(d.is_denied(&h.home.join(".docker/config.json")));
        assert!(!d.is_denied(&h.home.join(".docker/other.json")));
        assert!(!d.is_denied(&h.home.join(".docker")));
        assert!(d.is_denied(&h.home.join(".npmrc")));
        assert!(!d.is_denied(&h.home.join(".npmrc.bak")));
    }

    #[test]
    fn glob_entries_match_per_component_and_cover_what_is_below() {
        let h = home();
        let d = list(&h, Os::Linux);
        assert!(d.is_denied(&h.home.join(".cargo/credentials.toml")));
        assert!(d.is_denied(&h.home.join(".cargo/credentials")));
        assert!(!d.is_denied(&h.home.join(".cargo/config.toml")));
        assert!(d.is_denied(&h.home.join(".claude-accounts/a/b")));
        assert!(d.is_denied(&h.home.join(".claude.json")));
        assert!(d.is_denied(&h.home.join(".codex/auth.json")));
        assert!(!d.is_denied(&h.home.join("claude/notes")));
        let m = list(&h, Os::MacOs);
        assert!(m.is_denied(
            &h.home
                .join("Library/Group Containers/2BUA8C4S2C.com.1password/x")
        ));
        assert!(!m.is_denied(
            &h.home
                .join("Library/Group Containers/group.com.apple.notes/x")
        ));
    }

    #[test]
    fn root_only_entries_refuse_a_root_and_nothing_below_it() {
        let h = home();
        let d = list(&h, Os::MacOs);
        for r in ["/", "/System", "/Library", "/private", "/Volumes"] {
            assert!(!d.check_grant_root(Path::new(r)).is_ok(), "{r}");
            assert!(!d.is_denied(Path::new(r)), "{r} is only refused as a root");
        }
        assert!(!d.is_denied(Path::new("/Volumes/work/project/a.txt")));
        assert!(d
            .check_grant_root(Path::new("/Volumes/work/project"))
            .is_ok());
    }

    #[test]
    fn matching_is_case_insensitive_on_macos_and_windows_only() {
        let h = home();
        assert!(list(&h, Os::MacOs).is_denied(&h.home.join(".SSH/id")));
        assert!(list(&h, Os::MacOs).is_denied(&h.home.join(".Claude-Accounts")));
        assert!(list(&h, Os::Windows).is_denied(&h.home.join(".SSH/id")));
        assert!(!list(&h, Os::Linux).is_denied(&h.home.join(".SSH/id")));
    }

    #[test]
    fn the_windows_table_applies_its_own_places() {
        let h = home();
        let d = list(&h, Os::Windows);
        let roaming = h.home.join("AppData/Roaming");
        let local = h.home.join("AppData/Local");
        assert!(d.is_denied(&roaming.join("Microsoft/Credentials/abc")));
        assert!(d.is_denied(&roaming.join("GitHub CLI/hosts.yml")));
        assert!(d.is_denied(&local.join("Google/Chrome/User Data/Default/Cookies")));
        assert!(d.is_denied(&local.join("1Password/x")));
        assert!(!d.is_denied(&local.join("Programs/tool/a.txt")));
        // The macOS-only list is not applied on Windows.
        assert!(!d.is_denied(&h.home.join("Library/Keychains/login.keychain-db")));
        assert!(list(&h, Os::MacOs).is_denied(&h.home.join("Library/Keychains/login.keychain-db")));
    }

    #[test]
    fn the_apps_own_folders_are_protected() {
        let h = home();
        let base = h.home.join("agmsg-base");
        fs::create_dir_all(base.join("addons")).unwrap();
        let e = DenyEnv {
            extra_subtrees: vec![base.clone()],
            ..env(&h, Os::Linux)
        };
        let d = Denylist::new(&e);
        assert!(d.is_denied(&base.join("addons/x/web/index.html")));
        assert!(d.is_denied(&base.join("db/agmsg.db")));
        assert!(!d.is_denied(&h.home.join("agmsg-base-copy/x")));
    }

    #[test]
    fn git_history_paths_that_are_not_on_disk_are_judged_lexically() {
        let h = home();
        let proj = h.home.join("proj");
        fs::create_dir_all(&proj).unwrap();
        let d = list(&h, Os::MacOs);
        assert!(!d.is_denied_repo_path(&proj, "src/main.rs"));
        assert!(!d.is_denied_repo_path(&proj, "./src/main.rs"));
        // The repo is the home folder itself: its history may name .ssh/config.
        assert!(d.is_denied_repo_path(&h.home, ".ssh/config"));
        assert!(d.is_denied_repo_path(&h.home, ".AWS/credentials"));
        assert!(d.is_denied_repo_path(&h.home, ".claude-x/settings.json"));
        assert!(!d.is_denied_repo_path(&h.home, "proj/readme.md"));
        // Not a plain relative path: refused.
        assert!(d.is_denied_repo_path(&proj, "../.ssh/config"));
        assert!(d.is_denied_repo_path(&proj, "/etc/passwd"));
        assert!(d.is_denied_repo_path(&proj, ""));
    }

    #[cfg(unix)]
    #[test]
    fn a_history_path_through_a_symlink_that_exists_today_is_judged_by_where_it_leads() {
        let h = home();
        fs::create_dir_all(h.home.join(".ssh")).unwrap();
        let proj = h.home.join("proj");
        fs::create_dir_all(&proj).unwrap();
        std::os::unix::fs::symlink(h.home.join(".ssh"), proj.join("link")).unwrap();
        let d = list(&h, Os::Linux);
        assert!(
            d.is_denied_repo_path(&proj, "link/id_rsa"),
            "id_rsa need not exist"
        );
    }

    #[test]
    fn dotdot_in_a_missing_tail_is_resolved_lexically() {
        let h = home();
        let d = list(&h, Os::Linux);
        let p = h.home.join("proj/missing/../../.ssh/id");
        assert!(d.is_denied(&p));
    }

    #[cfg(unix)]
    #[test]
    fn a_link_above_an_entry_that_appears_later_still_protects_its_real_place() {
        // Case A: ~/.config is a link; the list is built before gcloud exists.
        let h = home();
        let target = h.home.join("elsewhere");
        fs::create_dir_all(&target).unwrap();
        std::os::unix::fs::symlink(&target, h.home.join(".config")).unwrap();
        let d = list(&h, Os::Linux);
        assert!(!target.join("gcloud").exists());
        fs::create_dir_all(target.join("gcloud")).unwrap();
        fs::write(target.join("gcloud/token"), "t").unwrap();
        // Through the home, and straight through the real target.
        assert!(d.is_denied(&h.home.join(".config/gcloud/token")));
        assert!(
            d.is_denied(&target.join("gcloud/token")),
            "a grant via the real target"
        );
        assert!(!d.check_grant_root(&target.join("gcloud")).is_ok());
        assert!(!d.is_denied(&target.join("other/file")));
        // The same, for history paths and for a repo whose root is the real target.
        assert!(d.is_denied_repo_path(&target, "gcloud/token"));
        assert!(d.is_denied_repo_path(&target, "gcloud/never-existed"));
        assert!(!d.is_denied_repo_path(&target, "src/main.rs"));
    }

    #[cfg(unix)]
    #[test]
    fn a_glob_match_that_is_a_link_protects_its_real_target() {
        // Case B: ~/.codex-work is a link to a profile folder.
        let h = home();
        let profile = h.home.join("profile-target");
        fs::create_dir_all(&profile).unwrap();
        fs::write(profile.join("auth.json"), "{}").unwrap();
        std::os::unix::fs::symlink(&profile, h.home.join(".codex-work")).unwrap();
        let d = list(&h, Os::Linux);
        assert!(d.is_denied(&h.home.join(".codex-work/auth.json")));
        assert!(
            d.is_denied(&profile.join("auth.json")),
            "a grant via the real target"
        );
        assert!(!d.check_grant_root(&profile).is_ok());
        assert!(d.is_denied_repo_path(&profile, "auth.json"));
        assert!(d.is_denied_repo_path(&profile, "nested/never-existed"));
        // A glob match created after the list was built is seen too.
        let later = h.home.join("later-target");
        fs::create_dir_all(&later).unwrap();
        std::os::unix::fs::symlink(&later, h.home.join(".claude-later")).unwrap();
        assert!(d.is_denied(&later.join("settings.json")));
        // ... and filter_children hides both the link and the folder it leads to.
        assert_eq!(
            d.filter_children(&h.home, [".codex-work", "profile-target", "plain"]),
            vec!["plain"]
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_protected_folder_linked_from_a_granted_repo_is_judged_by_its_target() {
        let h = home();
        let repo = h.home.join("repo");
        fs::create_dir_all(repo.join("sub")).unwrap();
        fs::create_dir_all(h.home.join(".aws")).unwrap();
        std::os::unix::fs::symlink(h.home.join(".aws"), repo.join("sub/creds")).unwrap();
        let d = list(&h, Os::Linux);
        assert!(d.is_denied_repo_path(&repo, "sub/creds/credentials"));
        assert!(!d.is_denied_repo_path(&repo, "sub/other"));
    }

    #[test]
    fn the_refusal_names_the_path_and_the_reason() {
        let m = refusal_message(Path::new("/h/.ssh"));
        assert!(m.starts_with("/h/.ssh is on agmsg's list of protected locations"));
        assert!(m.ends_with("Add-ons can't read it."));
    }

    #[test]
    fn the_env_rule_is_off_for_the_plain_list_and_on_for_a_network_pane() {
        let h = home();
        let plain = Denylist::new(&env(&h, Os::Linux));
        let net = plain.with_env_files();
        let proj = h.home.join("proj");
        fs::create_dir_all(&proj).unwrap();
        for n in [".env", ".env.local", ".env.production"] {
            assert!(!plain.is_denied(&proj.join(n)), "{n}: not refused for a pane without network");
            assert!(net.is_denied(&proj.join(n)), "{n}: refused for a network pane");
        }
        for n in [".envrc", "env", "x.env", ".environment"] {
            assert!(!net.is_denied(&proj.join(n)), "{n}");
        }
        // history may name a file that is gone from the disk
        assert!(net.is_denied_repo_path(&proj, "sub/dir/.env"));
        assert!(!plain.is_denied_repo_path(&proj, "sub/dir/.env"));
        assert!(net.refuses_env_name("a/.env.local") && !plain.refuses_env_name("a/.env.local"));
        assert!(!net.refuses_env_name("a/env"));
        // a case-sensitive list keeps .ENV a different name; a folding one does not
        assert!(!net.is_denied(&proj.join(".ENV")));
        let mac = Denylist::new(&env(&h, Os::MacOs)).with_env_files();
        assert!(mac.is_denied(&proj.join(".ENV")) && mac.refuses_env_name("x/.Env.Local"));
    }

    #[test]
    fn the_refusal_for_an_env_file_says_why() {
        let m = refusal_message(Path::new("/p/.env.local"));
        assert!(m.contains(".env") && m.contains("network") && !m.contains("keys, credentials"), "{m}");
        assert!(refusal_message(Path::new("/p/.ssh/id")).contains("protected locations"));
    }

    #[test]
    fn windows_matching_ignores_case() {
        let h = home();
        let d = list(&h, Os::Windows);
        for p in [".ssh", ".SSH", ".Ssh/id_rsa", ".AWS"] {
            assert!(!d.check_grant_root(&h.home.join(p)).is_ok(), "{p}");
            assert!(d.is_denied(&h.home.join(p)), "{p}");
        }
    }

    /// A protected folder reached through its other spellings on a real Windows volume.
    #[cfg(windows)]
    #[test]
    fn windows_aliases_of_a_protected_folder_are_denied() {
        let h = home();
        fs::create_dir_all(h.home.join(".ssh")).unwrap();
        fs::write(h.home.join(".ssh").join("id_ed25519"), "k").unwrap();
        let d = list(&h, Os::Windows);
        // another case
        let upper = PathBuf::from(h.home.join(".SSH").to_string_lossy().to_uppercase());
        assert!(!d.check_grant_root(&upper).is_ok(), "{upper:?}");
        // the 8.3 alias of the folder and of the file inside it
        match super::super::fslink::win_test::short_path(&h.home.join(".ssh").join("id_ed25519")) {
            Some(short) => {
                assert!(d.is_denied(&short), "{short:?}");
                assert!(!d.check_grant_root(&short).is_ok(), "{short:?}");
            }
            None => eprintln!("8.3 names are off on this volume; nothing to check"),
        }
        // a junction from a granted folder into the protected one
        let proj = h.home.join("proj");
        fs::create_dir_all(&proj).unwrap();
        super::super::fslink::win_test::junction(&proj.join("junc"), &h.home.join(".ssh"));
        assert!(d.is_denied(&proj.join("junc")));
        assert!(d.is_denied(&proj.join("junc").join("id_ed25519")));
    }
}
