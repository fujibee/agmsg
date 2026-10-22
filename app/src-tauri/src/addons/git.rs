//! The git side of the add-on broker (`git:read`).
//!
//! A path check on the granted root is not a boundary for git: repo config can
//! redirect it (`core.worktree`), pull objects from elsewhere (alternates), run
//! programs (fsmonitor, filters, textconv, hooks, transport helpers) or fetch a
//! missing object from a remote. So this module
//!
//! 1. validates the repository layout by *reading the files itself*, never by
//!    asking git, and requires every real path to stay under the granted root;
//! 2. runs git only with explicit `--git-dir` / `--work-tree`, a cleared
//!    environment and hardening flags, and only object and ref plumbing;
//! 3. computes status and diffs itself (blob vs blob, blob vs worktree file) with
//!    `addons::diff`, reading worktree files through checked reads;
//! 4. drops every path the denylist matches, in history too.
//!
//! Limits of version 1 (deliberate, not bugs):
//! - Worktree files are compared as they are on disk. `core.autocrlf`, clean
//!   filters and `.gitattributes` are not applied, so a repository that converts
//!   line endings shows those files as changed.
//! - Submodules are never entered; a submodule path is left out of status and diff.
//! - `log` returns the author name, an ISO date, the subject and the parents:
//!   no e-mail address and no message body.
//! - A single file is compared up to 2 MB, `show` reads up to 10 MB, a status or
//!   diff lists at most 5,000 files.
//! - Every git run has a time limit (`GitEnv::timeout`, 30 s by default); a run
//!   that exceeds it is killed and reported as `not_available`.
//! - Untracked files that are not ignored are listed as added.
//!
//! Errors carry the protocol codes: `outside_root`, `unsupported_repo`,
//! `not_found`, `bad_args`, `denied_path`, `too_large`, `not_available`.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde::{Deserialize, Deserializer, Serialize};
use sha1::{Digest, Sha1};

use super::denylist::{resolve, Denylist, Snapshot};
use super::diff::{
    diff_file, BaseRev, Context, DiffFile, DiffResult, DiffStatus, FileInput, HeadRev, Options,
    Relation,
};

// ---- errors ---------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrorCode {
    OutsideRoot,
    UnsupportedRepo,
    NotFound,
    BadArgs,
    DeniedPath,
    TooLarge,
    NotAvailable,
}

impl ErrorCode {
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::OutsideRoot => "outside_root",
            ErrorCode::UnsupportedRepo => "unsupported_repo",
            ErrorCode::NotFound => "not_found",
            ErrorCode::BadArgs => "bad_args",
            ErrorCode::DeniedPath => "denied_path",
            ErrorCode::TooLarge => "too_large",
            ErrorCode::NotAvailable => "not_available",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitError {
    pub code: ErrorCode,
    pub message: String,
}

impl GitError {
    fn new(code: ErrorCode, message: impl Into<String>) -> GitError {
        GitError {
            code,
            message: message.into(),
        }
    }
}

impl fmt::Display for GitError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} ({})", self.message, self.code.as_str())
    }
}

impl std::error::Error for GitError {}

type Res<T> = Result<T, GitError>;

fn outside(msg: impl Into<String>) -> GitError {
    GitError::new(ErrorCode::OutsideRoot, msg)
}
fn unsupported(msg: impl Into<String>) -> GitError {
    GitError::new(ErrorCode::UnsupportedRepo, msg)
}
fn not_found(msg: impl Into<String>) -> GitError {
    GitError::new(ErrorCode::NotFound, msg)
}
fn bad_args(msg: impl Into<String>) -> GitError {
    GitError::new(ErrorCode::BadArgs, msg)
}
fn unavailable(msg: impl Into<String>) -> GitError {
    GitError::new(ErrorCode::NotAvailable, msg)
}

// ---- layout validation (reads files; never asks git) ----------------------

/// The validated places of one repository, all real paths under the granted root.
#[derive(Debug, Clone)]
pub struct Layout {
    pub root: PathBuf,
    pub git_dir: PathBuf,
    pub common_dir: PathBuf,
}

const MAX_CONFIG_BYTES: u64 = 1024 * 1024;
const MAX_INCLUDE_DEPTH: usize = 10;
const MAX_ALTERNATE_DEPTH: usize = 5;
const MAX_GIT_DIR_ENTRIES: usize = 1_000_000;

fn is_under(root: &Path, p: &Path) -> bool {
    resolve(p).starts_with(root)
}

/// Read a small control file. Absent is `Ok(None)`; a file that cannot be read, or
/// is larger than the limit, is refused: an unscanned tail could hold the very
/// entry the scan is looking for.
fn read_small(p: &Path) -> Res<Option<String>> {
    let f = match fs::File::open(p) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => {
            return Err(unsupported(format!(
                "cannot read {} to check it: {e}",
                p.display()
            )))
        }
    };
    let mut s = Vec::new();
    f.take(MAX_CONFIG_BYTES + 1)
        .read_to_end(&mut s)
        .map_err(|e| unsupported(format!("cannot read {} to check it: {e}", p.display())))?;
    if s.len() as u64 > MAX_CONFIG_BYTES {
        return Err(unsupported(format!(
            "{} is larger than {MAX_CONFIG_BYTES} bytes and cannot be checked",
            p.display()
        )));
    }
    Ok(Some(String::from_utf8_lossy(&s).into_owned()))
}

/// Every link anywhere under `dir` must lead inside `root`. Git reads loose
/// objects, packs, refs and control files by following whatever is there, so a
/// link below `objects/` or `refs/` is as much a way out as one at the top.
/// Links are checked, not followed; a link that stays inside is allowed.
fn check_no_link_out(root: &Path, dir: &Path) -> Res<()> {
    let mut visited: BTreeSet<PathBuf> = BTreeSet::new();
    let start = resolve(dir);
    visited.insert(start.clone());
    let mut stack = vec![start];
    let mut seen = 0usize;
    while let Some(d) = stack.pop() {
        let Ok(rd) = fs::read_dir(&d) else { continue };
        for entry in rd.flatten() {
            seen += 1;
            if seen > MAX_GIT_DIR_ENTRIES {
                return Err(unsupported(
                    "the git directory of this repository has too many files to check",
                ));
            }
            let Ok(ft) = entry.file_type() else { continue };
            let path = entry.path();
            if ft.is_symlink() {
                let real = resolve(&path);
                if !real.starts_with(root) {
                    return Err(outside(format!(
                        "{} is a link that leads outside the granted folder",
                        path.strip_prefix(root).unwrap_or(&path).display()
                    )));
                }
                // A link to a folder inside the root is followed too: what it
                // holds can be a link out. Each real folder is walked once.
                if real.is_dir() && visited.insert(real.clone()) {
                    stack.push(real);
                }
            } else if ft.is_dir() {
                let real = resolve(&path);
                if visited.insert(real.clone()) {
                    stack.push(real);
                }
            }
        }
    }
    Ok(())
}

/// Validate the repository at `root` (the real path of the granted folder).
pub fn validate_layout(root: &Path) -> Res<Layout> {
    let root = root
        .canonicalize()
        .map_err(|e| not_found(format!("cannot read the folder: {e}")))?;
    let dotgit = root.join(".git");
    let meta = fs::metadata(&dotgit)
        .map_err(|_| unsupported("this folder is not the top of a git repository (no .git)"))?;
    if !is_under(&root, &dotgit) {
        return Err(outside(".git points outside the granted folder"));
    }
    let git_dir = if meta.is_dir() {
        dotgit
    } else {
        // A gitfile: "gitdir: <path>", relative to the folder holding it.
        let text = read_small(&dotgit)?.unwrap_or_default();
        let line = text.lines().next().unwrap_or("").trim();
        let target = line
            .strip_prefix("gitdir:")
            .map(str::trim)
            .filter(|t| !t.is_empty());
        let target = target
            .ok_or_else(|| unsupported(".git is a file that does not name a git directory"))?;
        let p = Path::new(target);
        let abs = if p.is_absolute() {
            p.to_path_buf()
        } else {
            root.join(p)
        };
        if !is_under(&root, &abs) {
            return Err(outside(
                "the gitdir of this repository is outside the granted folder",
            ));
        }
        resolve(&abs)
    };
    if !git_dir.join("HEAD").is_file() {
        return Err(unsupported("this folder is not a git repository (no HEAD)"));
    }
    let common_dir = match read_small(&git_dir.join("commondir"))? {
        Some(c) if !c.trim().is_empty() => {
            let p = Path::new(c.trim());
            let abs = if p.is_absolute() {
                p.to_path_buf()
            } else {
                git_dir.join(p)
            };
            if !is_under(&root, &abs) {
                return Err(outside(
                    "the common git directory of this repository is outside the granted folder",
                ));
            }
            resolve(&abs)
        }
        _ => git_dir.clone(),
    };
    let layout = Layout {
        root,
        git_dir,
        common_dir,
    };
    check_entries(&layout)?;
    check_alternates(&layout.root, &layout.common_dir.join("objects"), 0)?;
    check_config(&layout)?;
    Ok(layout)
}

/// Top-level files and folders of the git directories must not be links that
/// lead out, and a promisor pack means a partial clone.
fn check_entries(l: &Layout) -> Res<()> {
    for dir in [&l.git_dir, &l.common_dir] {
        for name in [
            "HEAD",
            "config",
            "config.worktree",
            "index",
            "packed-refs",
            "shallow",
            "objects",
            "refs",
            "info",
            "commondir",
        ] {
            let p = dir.join(name);
            if fs::symlink_metadata(&p).is_ok() && !is_under(&l.root, &p) {
                return Err(outside(format!(
                    "{name} of this repository leads outside the granted folder"
                )));
            }
        }
    }
    check_no_link_out(&l.root, &l.git_dir)?;
    if l.common_dir != l.git_dir {
        check_no_link_out(&l.root, &l.common_dir)?;
    }
    if let Ok(rd) = fs::read_dir(l.common_dir.join("objects/pack")) {
        for e in rd.flatten() {
            if e.file_name().to_string_lossy().ends_with(".promisor") {
                return Err(unsupported("this is a partial clone (promisor packs); reading a missing object would fetch it"));
            }
        }
    }
    Ok(())
}

fn check_alternates(root: &Path, objects: &Path, depth: usize) -> Res<()> {
    if depth > MAX_ALTERNATE_DEPTH {
        return Err(unsupported("object alternates are nested too deeply"));
    }
    for file in ["info/alternates", "info/http-alternates"] {
        let Some(text) = read_small(&objects.join(file))? else {
            continue;
        };
        for line in text.lines() {
            let line = line.trim().trim_matches('"');
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let p = Path::new(line);
            let abs = if p.is_absolute() {
                p.to_path_buf()
            } else {
                objects.join(p)
            };
            if !is_under(root, &abs) {
                return Err(outside(
                    "this repository borrows objects from outside the granted folder (alternates)",
                ));
            }
            if file == "info/alternates" {
                let alt = resolve(&abs);
                check_no_link_out(root, &alt)?;
                check_alternates(root, &alt, depth + 1)?;
            }
        }
    }
    Ok(())
}

fn check_config(l: &Layout) -> Res<()> {
    let mut files = vec![
        l.common_dir.join("config"),
        l.common_dir.join("config.worktree"),
    ];
    if l.git_dir != l.common_dir {
        files.push(l.git_dir.join("config"));
        files.push(l.git_dir.join("config.worktree"));
    }
    for f in files {
        scan_config(&l.root, &f, 0)?;
    }
    Ok(())
}

/// A lenient, conservative reader of git config syntax. It does not need to be
/// exact: it must never *miss* what git would read, so it looks at the key names
/// alone (any section) and refuses on any sign of a redirect or a partial clone.
fn scan_config(root: &Path, file: &Path, depth: usize) -> Res<()> {
    if depth > MAX_INCLUDE_DEPTH {
        return Err(unsupported("config includes are nested too deeply"));
    }
    if fs::symlink_metadata(file).is_err() {
        return Ok(()); // git ignores a missing config file
    }
    if !is_under(root, file) {
        return Err(outside(
            "a config file of this repository is outside the granted folder",
        ));
    }
    let Some(text) = read_small(file)? else {
        return Ok(());
    };
    let base = file.parent().unwrap_or(Path::new("."));
    let mut section = String::new();
    for raw in text.lines() {
        let mut line = raw.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if let Some(rest) = line.strip_prefix('[') {
            let Some(end) = rest.find(']') else { continue };
            let header = rest[..end].trim().to_lowercase();
            section = header
                .split(|c: char| c.is_whitespace() || c == '"' || c == '.')
                .next()
                .unwrap_or("")
                .to_string();
            line = rest[end + 1..].trim();
            if line.is_empty() {
                continue;
            }
        }
        let (key, value) = match line.split_once('=') {
            Some((k, v)) => (k.trim().to_lowercase(), clean_value(v)),
            None => (line.to_lowercase(), "true".to_string()),
        };
        match key.as_str() {
            "worktree" => {
                return Err(outside(
                    "this repository sets core.worktree; the work tree could be elsewhere",
                ));
            }
            "partialclone" => {
                return Err(unsupported(
                    "this is a partial clone (extensions.partialClone)",
                ))
            }
            "promisor"
                if !matches!(value.to_lowercase().as_str(), "false" | "no" | "off" | "0") =>
            {
                return Err(unsupported(
                    "this repository has a promisor remote; a missing object would be fetched",
                ));
            }
            "objectformat" if !value.eq_ignore_ascii_case("sha1") => {
                return Err(unsupported("only sha1 repositories are supported"));
            }
            "path" if section == "include" || section == "includeif" => {
                if value.starts_with('~') {
                    return Err(outside("a config include reaches into a home folder"));
                }
                let p = Path::new(&value);
                let abs = if p.is_absolute() {
                    p.to_path_buf()
                } else {
                    base.join(p)
                };
                if !is_under(root, &abs) {
                    return Err(outside("a config include is outside the granted folder"));
                }
                scan_config(root, &resolve(&abs), depth + 1)?;
            }
            _ => {}
        }
    }
    Ok(())
}

fn clean_value(v: &str) -> String {
    let v = v.trim();
    let mut out = String::new();
    let mut quoted = false;
    let mut prev_space = true;
    for c in v.chars() {
        match c {
            '"' => quoted = !quoted,
            '#' | ';' if !quoted && prev_space => break,
            _ => out.push(c),
        }
        prev_space = c.is_whitespace();
    }
    out.trim().to_string()
}

// ---- revisions and paths ----------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RevSpec {
    Plain(String),
    /// `merge-base:<ref>`: the merge base of <ref> and HEAD.
    MergeBase(String),
}

fn plain_rev_ok(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 255
        && !s.starts_with(['-', '/', '.'])
        && !s.ends_with(['/', '.'])
        && !s.contains("..")
        && !s.contains("//")
        && !s.ends_with(".lock")
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '/' | '+' | '-'))
}

/// A revision is a ref name, a SHA, HEAD or `merge-base:<ref>`. Anything that
/// could be an option, a pathspec, a range or a revision expression is refused.
pub fn validate_rev(rev: &str) -> Res<RevSpec> {
    if let Some(r) = rev.strip_prefix("merge-base:") {
        return if plain_rev_ok(r) {
            Ok(RevSpec::MergeBase(r.to_string()))
        } else {
            Err(bad_args(format!("not a usable revision: {rev}")))
        };
    }
    if plain_rev_ok(rev) {
        Ok(RevSpec::Plain(rev.to_string()))
    } else {
        Err(bad_args(format!("not a usable revision: {rev}")))
    }
}

/// A repo-relative path with plain components only.
fn validate_rel(path: &str) -> Res<String> {
    let p = Path::new(path);
    if path.is_empty()
        || path.contains('\0')
        || path.contains('\\')
        || !p
            .components()
            .all(|c| matches!(c, Component::Normal(_) | Component::CurDir))
    {
        return Err(bad_args(format!(
            "not a path inside the repository: {path}"
        )));
    }
    let parts: Vec<String> = p
        .components()
        .filter_map(|c| match c {
            Component::Normal(s) => Some(s.to_string_lossy().into_owned()),
            _ => None,
        })
        .collect();
    if parts.is_empty() {
        return Err(bad_args(format!(
            "not a path inside the repository: {path}"
        )));
    }
    Ok(parts.join("/"))
}

fn is_hex_oid(s: &str) -> bool {
    s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

// ---- the runner -------------------------------------------------------------

/// What the app supplies once: the git executable and a folder it owns where this
/// module keeps an empty hooks directory and an empty config file.
#[derive(Debug, Clone)]
pub struct GitEnv {
    pub git: PathBuf,
    pub empty_dir: PathBuf,
    pub empty_config: PathBuf,
    /// A git run (or one answer of the object reader) that takes longer is killed.
    pub timeout: Duration,
}

/// Default time limit of one git run.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

impl GitEnv {
    pub fn new(git: impl Into<PathBuf>, support_dir: &Path) -> std::io::Result<GitEnv> {
        let empty_dir = support_dir.join("empty-hooks");
        let empty_config = support_dir.join("empty-gitconfig");
        fs::create_dir_all(&empty_dir)?;
        if !empty_config.exists() {
            fs::write(&empty_config, b"")?;
        }
        Ok(GitEnv {
            git: git.into(),
            empty_dir,
            empty_config,
            timeout: DEFAULT_TIMEOUT,
        })
    }
}

struct Runner {
    env: GitEnv,
    git_dir: PathBuf,
    work_tree: PathBuf,
    ceiling: PathBuf,
}

const MAX_STDERR: u64 = 64 * 1024;

impl Runner {
    fn command(&self) -> Command {
        let mut c = Command::new(&self.env.git);
        c.env_clear();
        if let Some(p) = std::env::var_os("PATH") {
            c.env("PATH", p);
        }
        for k in ["SystemRoot", "ComSpec", "PATHEXT"] {
            if let Some(v) = std::env::var_os(k) {
                c.env(k, v);
            }
        }
        c.env("HOME", &self.env.empty_dir)
            .env("USERPROFILE", &self.env.empty_dir)
            .env("XDG_CONFIG_HOME", &self.env.empty_dir)
            .env("LC_ALL", "C")
            .env("LANG", "C")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", &self.env.empty_config)
            .env("GIT_NO_REPLACE_OBJECTS", "1")
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env("GIT_CEILING_DIRECTORIES", &self.ceiling)
            .env("GIT_NO_LAZY_FETCH", "1")
            .env("GIT_PROTOCOL_FROM_USER", "0")
            .env("GIT_TERMINAL_PROMPT", "0");
        c.arg("--git-dir")
            .arg(&self.git_dir)
            .arg("--work-tree")
            .arg(&self.work_tree);
        c.args([
            "--no-pager",
            "--no-optional-locks",
            "--no-replace-objects",
            "--literal-pathspecs",
        ]);
        c.args([
            "-c",
            "core.fsmonitor=false",
            "-c",
            "protocol.allow=never",
            "-c",
            "gc.auto=0",
            "-c",
            "log.showSignature=false",
        ]);
        c.arg("-c")
            .arg(format!("core.hooksPath={}", self.env.empty_dir.display()));
        c
    }

    /// Run to completion. Returns (success, stdout, stderr).
    fn run_raw(
        &self,
        args: &[&str],
        stdin: Option<&[u8]>,
        cap: usize,
    ) -> Res<(bool, Vec<u8>, String)> {
        let mut c = self.command();
        c.args(args)
            .stdin(if stdin.is_some() {
                Stdio::piped()
            } else {
                Stdio::null()
            })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = c
            .spawn()
            .map_err(|e| unavailable(format!("cannot start git: {e}")))?;
        let mut err = child.stderr.take().expect("piped");
        let err_thread = thread::spawn(move || {
            let mut v = Vec::new();
            let _ = (&mut err).take(MAX_STDERR).read_to_end(&mut v);
            v
        });
        let in_thread = stdin.map(|d| {
            let mut si = child.stdin.take().expect("piped");
            let d = d.to_vec();
            thread::spawn(move || {
                let _ = si.write_all(&d);
            })
        });
        let exceeded = Arc::new(AtomicBool::new(false));
        let mut so = child.stdout.take().expect("piped");
        let flag = exceeded.clone();
        let out_thread = thread::spawn(move || {
            let mut v = Vec::new();
            let _ = (&mut so).take(cap as u64 + 1).read_to_end(&mut v);
            if v.len() > cap {
                flag.store(true, Ordering::SeqCst);
            }
            v
        });
        let deadline = Instant::now() + self.env.timeout;
        let mut timed_out = false;
        let status = loop {
            match child.try_wait() {
                Ok(Some(st)) => break Some(st),
                Ok(None) => {}
                Err(e) => return Err(unavailable(format!("git did not finish: {e}"))),
            }
            if exceeded.load(Ordering::SeqCst) {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            if Instant::now() >= deadline {
                timed_out = true;
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            thread::sleep(Duration::from_millis(2));
        };
        let out = out_thread.join().unwrap_or_default();
        if let Some(t) = in_thread {
            let _ = t.join();
        }
        let stderr = String::from_utf8_lossy(&err_thread.join().unwrap_or_default())
            .trim()
            .to_string();
        if timed_out {
            return Err(unavailable(format!(
                "git did not answer within {} s and was stopped",
                self.env.timeout.as_secs_f32()
            )));
        }
        let Some(status) = status else {
            return Err(GitError::new(
                ErrorCode::TooLarge,
                "git produced more output than the broker allows",
            ));
        };
        Ok((status.success(), out, stderr))
    }

    fn run(&self, args: &[&str], stdin: Option<&[u8]>, cap: usize) -> Res<Vec<u8>> {
        let (ok, out, err) = self.run_raw(args, stdin, cap)?;
        if ok {
            Ok(out)
        } else {
            Err(unavailable(format!(
                "git {} failed: {}",
                args.first().unwrap_or(&""),
                first_line(&err)
            )))
        }
    }

    fn batch(&self) -> Res<Batch> {
        let mut c = self.command();
        c.args(["cat-file", "--batch"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = c
            .spawn()
            .map_err(|e| unavailable(format!("cannot start git: {e}")))?;
        let stdin = child.stdin.take().expect("piped");
        let stdout = BufReader::new(child.stdout.take().expect("piped"));
        Ok(Batch {
            child: Arc::new(Mutex::new(child)),
            stdin,
            stdout,
            timeout: self.env.timeout,
        })
    }
}

fn first_line(s: &str) -> &str {
    s.lines().next().unwrap_or("")
}

/// One `cat-file --batch` process for many objects.
struct Batch {
    child: Arc<Mutex<Child>>,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    timeout: Duration,
}

impl Drop for Batch {
    fn drop(&mut self) {
        if let Ok(mut c) = self.child.lock() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

impl Batch {
    fn kill(&self) {
        if let Ok(mut c) = self.child.lock() {
            let _ = c.kill();
        }
    }

    /// The content of a blob, at most `cap` bytes. One answer must arrive within
    /// the time limit, or the process is killed.
    fn blob(&mut self, oid: &str, cap: u64) -> Res<Vec<u8>> {
        if !is_hex_oid(oid) {
            return Err(bad_args("not an object id"));
        }
        let (done, wait) = mpsc::channel::<()>();
        let timed_out = Arc::new(AtomicBool::new(false));
        let (flag, child, limit) = (timed_out.clone(), self.child.clone(), self.timeout);
        let dog = thread::spawn(move || {
            if wait.recv_timeout(limit) == Err(mpsc::RecvTimeoutError::Timeout) {
                flag.store(true, Ordering::SeqCst);
                if let Ok(mut c) = child.lock() {
                    let _ = c.kill();
                }
            }
        });
        let result = self.read_blob(oid, cap);
        drop(done);
        let _ = dog.join();
        if timed_out.load(Ordering::SeqCst) {
            return Err(unavailable(format!(
                "git did not answer within {} s and was stopped",
                self.timeout.as_secs_f32()
            )));
        }
        result
    }

    fn read_blob(&mut self, oid: &str, cap: u64) -> Res<Vec<u8>> {
        writeln!(self.stdin, "{oid}")
            .and_then(|_| self.stdin.flush())
            .map_err(|e| unavailable(format!("git stopped: {e}")))?;
        let mut header = String::new();
        self.stdout
            .read_line(&mut header)
            .map_err(|e| unavailable(format!("git stopped: {e}")))?;
        let parts: Vec<&str> = header.split_whitespace().collect();
        match parts.as_slice() {
            [_, "missing"] => Err(not_found("object not found")),
            [_, kind, size] => {
                if *kind != "blob" {
                    return Err(bad_args("not a file"));
                }
                let size: u64 = size
                    .parse()
                    .map_err(|_| unavailable("unreadable git answer"))?;
                if size > cap {
                    // The rest of the answer is still in the pipe; this process is done.
                    self.kill();
                    return Err(GitError::new(
                        ErrorCode::TooLarge,
                        format!("the file is {size} bytes (limit {cap})"),
                    ));
                }
                let mut data = vec![0u8; size as usize];
                self.stdout
                    .read_exact(&mut data)
                    .map_err(|e| unavailable(format!("git stopped: {e}")))?;
                let mut nl = [0u8; 1];
                let _ = self.stdout.read_exact(&mut nl);
                Ok(data)
            }
            _ => Err(unavailable("unreadable git answer")),
        }
    }
}

// ---- requests and results -----------------------------------------------------

fn de_context<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Context>, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Raw {
        N(usize),
        S(String),
    }
    match Option::<Raw>::deserialize(d)? {
        None => Ok(None),
        Some(Raw::N(n)) => Ok(Some(Context::Lines(n))),
        Some(Raw::S(s)) if s == "all" => Ok(Some(Context::All)),
        Some(Raw::S(s)) => Err(serde::de::Error::custom(format!(
            "context must be a number or \"all\", got {s:?}"
        ))),
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffRequest {
    pub base: Option<String>,
    pub head: Option<String>,
    pub path: Option<String>,
    #[serde(default, deserialize_with = "de_context")]
    pub context: Option<Context>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogRequest {
    pub rev: Option<String>,
    pub path: Option<String>,
    pub limit: Option<usize>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Commit {
    pub sha: String,
    pub parents: Vec<String>,
    pub author: String,
    /// ISO 8601.
    pub date: String,
    pub subject: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum TreeKind {
    File,
    Dir,
    Symlink,
    Submodule,
}

/// A tree entry. There is no object id here on purpose: ids are never handed out.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TreeEntry {
    pub path: String,
    pub kind: TreeKind,
    pub mode: String,
    pub size: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct StatusEntry {
    pub path: String,
    pub status: DiffStatus,
    #[serde(rename = "oldPath", skip_serializing_if = "Option::is_none")]
    pub old_path: Option<String>,
}

#[derive(Debug)]
pub struct ShowResult {
    pub bytes: Vec<u8>,
    pub size: u64,
}

pub const MAX_SHOW_BYTES: u64 = 10 * 1024 * 1024;
const MAX_LIST_BYTES: usize = 64 * 1024 * 1024;
const MAX_FILES: usize = 5000;
const MAX_LOG: usize = 500;
const EMPTY_TREE: &str = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";
/// Worktree files larger than this are not hashed; they count as changed.
const HASH_CAP: u64 = 64 * 1024 * 1024;

// ---- the broker ---------------------------------------------------------------

pub struct GitBroker {
    runner: Runner,
    layout: Layout,
    deny: Arc<Denylist>,
}

/// One side of a file comparison.
#[derive(Debug, Clone)]
struct Side {
    mode: String,
    oid: String, // empty: not computed (too large to hash)
    size: u64,
    src: Src,
}

#[derive(Debug, Clone)]
enum Src {
    Blob(String),
    Worktree(String),
}

struct Change {
    path: String,
    old: Option<Side>,
    new: Option<Side>,
    renamed_from: Option<String>,
}

impl GitBroker {
    /// Validate the layout of the repository at `root` and prepare a runner.
    pub fn open(env: &GitEnv, root: &Path, deny: Arc<Denylist>) -> Res<GitBroker> {
        let layout = validate_layout(root)?;
        let ceiling = layout
            .root
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| layout.root.clone());
        let runner = Runner {
            env: env.clone(),
            git_dir: layout.git_dir.clone(),
            work_tree: layout.root.clone(),
            ceiling,
        };
        Ok(GitBroker {
            runner,
            layout,
            deny,
        })
    }

    pub fn layout(&self) -> &Layout {
        &self.layout
    }

    fn hidden(&self, snap: &Snapshot, rel: &str) -> bool {
        snap.is_denied_repo_path(&self.layout.root, rel)
    }

    fn check_path(&self, snap: &Snapshot, rel: &str) -> Res<String> {
        let p = validate_rel(rel)?;
        if self.hidden(snap, &p) {
            return Err(GitError::new(
                ErrorCode::DeniedPath,
                super::denylist::refusal_message(Path::new(&p)),
            ));
        }
        Ok(p)
    }

    // -- revisions

    /// The commit a revision names. `HEAD` of a repository with no commit yet is
    /// `Ok(None)`.
    fn commit_of(&self, rev: &RevSpec) -> Res<Option<String>> {
        match rev {
            RevSpec::Plain(r) => {
                let spec = format!("{r}^{{commit}}");
                let (ok, out, _) = self.runner.run_raw(
                    &[
                        "rev-parse",
                        "--verify",
                        "--quiet",
                        "--end-of-options",
                        &spec,
                    ],
                    None,
                    1024,
                )?;
                let sha = String::from_utf8_lossy(&out).trim().to_string();
                if ok && is_hex_oid(&sha) {
                    return Ok(Some(sha));
                }
                if r == "HEAD" && self.is_unborn()? {
                    return Ok(None);
                }
                Err(not_found(format!("no commit named {r}")))
            }
            RevSpec::MergeBase(other) => {
                let a = self
                    .commit_of(&RevSpec::Plain("HEAD".into()))?
                    .ok_or_else(|| not_found("no commits yet"))?;
                let b = self
                    .commit_of(&RevSpec::Plain(other.clone()))?
                    .ok_or_else(|| not_found("no such commit"))?;
                let (ok, out, _) = self.runner.run_raw(&["merge-base", &a, &b], None, 1024)?;
                let sha = String::from_utf8_lossy(&out).trim().to_string();
                if ok && is_hex_oid(&sha) {
                    Ok(Some(sha))
                } else {
                    Err(not_found(format!("no common ancestor with {other}")))
                }
            }
        }
    }

    fn is_unborn(&self) -> Res<bool> {
        let (ok, out, _) = self
            .runner
            .run_raw(&["symbolic-ref", "--quiet", "HEAD"], None, 1024)?;
        if !ok {
            return Ok(false); // detached HEAD that does not resolve
        }
        let r = String::from_utf8_lossy(&out).trim().to_string();
        let (found, _, _) = self.runner.run_raw(
            &["rev-parse", "--verify", "--quiet", "--end-of-options", &r],
            None,
            1024,
        )?;
        Ok(!found)
    }

    /// The commit sha for a revision string.
    pub fn resolve_rev(&self, rev: &str) -> Res<String> {
        self.commit_of(&validate_rev(rev)?)?
            .ok_or_else(|| not_found("no commits yet"))
    }

    // -- log

    pub fn log(&self, req: &LogRequest) -> Res<Vec<Commit>> {
        let rev = req.rev.as_deref().unwrap_or("HEAD");
        let Some(sha) = self.commit_of(&validate_rev(rev)?)? else {
            return Ok(Vec::new());
        };
        let limit = req.limit.unwrap_or(50).clamp(1, MAX_LOG).to_string();
        let snap = self.deny.snapshot();
        let path = match &req.path {
            Some(p) => Some(self.check_path(&snap, p)?),
            None => None,
        };
        let mut args = vec![
            "log",
            "-z",
            "--no-show-signature",
            "--no-notes",
            "--format=%H%x1f%P%x1f%an%x1f%aI%x1f%s",
            "-n",
            &limit,
            &sha,
        ];
        if let Some(p) = &path {
            args.push("--");
            args.push(p);
        }
        let out = self.runner.run(&args, None, MAX_LIST_BYTES)?;
        let mut commits = Vec::new();
        for rec in out.split(|&b| b == 0).filter(|r| !r.is_empty()) {
            let text = String::from_utf8_lossy(rec);
            let f: Vec<&str> = text.trim_start_matches('\n').split('\x1f').collect();
            if f.len() == 5 {
                commits.push(Commit {
                    sha: f[0].to_string(),
                    parents: f[1].split_whitespace().map(String::from).collect(),
                    author: f[2].to_string(),
                    date: f[3].to_string(),
                    subject: f[4].to_string(),
                });
            }
        }
        Ok(commits)
    }

    // -- trees

    /// Parse `ls-tree -z -l` output.
    fn parse_tree(&self, out: &[u8]) -> Vec<(String, String, String, Option<u64>, String)> {
        // (mode, type, oid, size, path)
        let mut v = Vec::new();
        for rec in out.split(|&b| b == 0).filter(|r| !r.is_empty()) {
            let Some(tab) = rec.iter().position(|&b| b == b'\t') else {
                continue;
            };
            let meta = String::from_utf8_lossy(&rec[..tab]).into_owned();
            let path = String::from_utf8_lossy(&rec[tab + 1..]).into_owned();
            let f: Vec<&str> = meta.split_whitespace().collect();
            if f.len() == 4 {
                v.push((
                    f[0].to_string(),
                    f[1].to_string(),
                    f[2].to_string(),
                    f[3].parse().ok(),
                    path,
                ));
            }
        }
        v
    }

    /// Entries of one folder of a revision (`dir` empty: the top).
    pub fn ls_tree(&self, rev: &str, dir: &str) -> Res<Vec<TreeEntry>> {
        let sha = self.resolve_rev(rev)?;
        let snap = self.deny.snapshot();
        let dir = if dir.is_empty() || dir == "." {
            String::new()
        } else {
            self.check_path(&snap, dir)?
        };
        let mut args = vec!["ls-tree", "-z", "-l", &sha];
        let spec = format!("{dir}/");
        if !dir.is_empty() {
            args.push("--");
            args.push(&spec);
        }
        let out = self.runner.run(&args, None, MAX_LIST_BYTES)?;
        let mut entries = Vec::new();
        for (mode, kind, _oid, size, path) in self.parse_tree(&out) {
            if self.hidden(&snap, &path) {
                continue;
            }
            let kind = match (kind.as_str(), mode.as_str()) {
                ("tree", _) => TreeKind::Dir,
                ("commit", _) => TreeKind::Submodule,
                (_, "120000") => TreeKind::Symlink,
                _ => TreeKind::File,
            };
            entries.push(TreeEntry {
                path,
                kind,
                mode,
                size,
            });
        }
        Ok(entries)
    }

    /// Every file of a commit (recursive), without folders, hidden paths removed.
    fn tree_files(&self, snap: &Snapshot, sha: &str) -> Res<BTreeMap<String, Side>> {
        let out = self.runner.run(
            &["ls-tree", "-r", "-z", "-l", "--full-tree", sha],
            None,
            MAX_LIST_BYTES,
        )?;
        let mut m = BTreeMap::new();
        for (mode, kind, oid, size, path) in self.parse_tree(&out) {
            if kind != "blob" || self.hidden(snap, &path) {
                continue; // submodules are never entered
            }
            m.insert(
                path,
                Side {
                    mode,
                    oid: oid.clone(),
                    size: size.unwrap_or(0),
                    src: Src::Blob(oid),
                },
            );
        }
        Ok(m)
    }

    /// A file at a revision. The path is resolved in that revision's tree first,
    /// checked against the denylist, and only then is the blob read. A bare object
    /// id is never accepted.
    pub fn show(&self, rev: &str, path: Option<&str>) -> Res<ShowResult> {
        let path = match path {
            Some(p) if !p.is_empty() => p,
            _ => return Err(bad_args("git.show needs a revision and a path")),
        };
        let sha = self.resolve_rev(rev)?;
        let snap = self.deny.snapshot();
        let rel = self.check_path(&snap, path)?;
        let out = self.runner.run(
            &["ls-tree", "-z", "-l", &sha, "--", &rel],
            None,
            MAX_LIST_BYTES,
        )?;
        let entry = self
            .parse_tree(&out)
            .into_iter()
            .find(|(_, _, _, _, p)| *p == rel)
            .ok_or_else(|| not_found(format!("{rel} does not exist in {rev}")))?;
        if entry.1 != "blob" {
            return Err(bad_args(format!("{rel} is not a file in {rev}")));
        }
        if entry.3.unwrap_or(0) > MAX_SHOW_BYTES {
            return Err(GitError::new(
                ErrorCode::TooLarge,
                format!("{rel} is larger than {MAX_SHOW_BYTES} bytes"),
            ));
        }
        let mut batch = self.runner.batch()?;
        let bytes = batch.blob(&entry.2, MAX_SHOW_BYTES)?;
        let size = bytes.len() as u64;
        Ok(ShowResult { bytes, size })
    }

    // -- worktree reads (checked)

    /// The worktree file at `rel`: mode, size and blob id, or `None` when it is
    /// absent, not a regular file or link, or hidden by the denylist. Symlinks are
    /// never followed: their target text is the content, as in git.
    fn wt_side(
        &self,
        snap: &Snapshot,
        rel: &str,
        fallback_mode: Option<&str>,
    ) -> Res<Option<Side>> {
        let full = self.layout.root.join(rel);
        let (Some(parent), Some(name)) = (full.parent(), full.file_name()) else {
            return Ok(None);
        };
        let real_parent = resolve(parent);
        if !real_parent.starts_with(&self.layout.root) {
            return Err(outside(format!("{rel} leads outside the granted folder")));
        }
        let target = real_parent.join(name);
        if snap.is_denied(&target) {
            return Ok(None);
        }
        let meta = match fs::symlink_metadata(&target) {
            Ok(m) => m,
            Err(_) => return Ok(None),
        };
        if meta.file_type().is_symlink() {
            let t = fs::read_link(&target)
                .map_err(|e| unavailable(format!("cannot read link {rel}: {e}")))?;
            let bytes = t.to_string_lossy().into_owned().into_bytes();
            return Ok(Some(Side {
                mode: "120000".into(),
                oid: blob_oid(&bytes),
                size: bytes.len() as u64,
                src: Src::Worktree(rel.to_string()),
            }));
        }
        if !meta.is_file() {
            return Ok(None);
        }
        let mode = exec_mode(&meta, fallback_mode);
        let oid = if meta.len() <= HASH_CAP {
            hash_file(&target, meta.len()).unwrap_or_default()
        } else {
            String::new()
        };
        Ok(Some(Side {
            mode,
            oid,
            size: meta.len(),
            src: Src::Worktree(rel.to_string()),
        }))
    }

    fn side_bytes(&self, side: &Side, batch: &mut Batch, cap: u64) -> Res<Vec<u8>> {
        match &side.src {
            Src::Blob(oid) => batch.blob(oid, cap),
            Src::Worktree(rel) => {
                // The folder holding the file must still be inside the root; a link
                // itself is never followed (its target text is the content).
                let full = self.layout.root.join(rel);
                let parent = full
                    .parent()
                    .map(resolve)
                    .unwrap_or_else(|| self.layout.root.clone());
                if !parent.starts_with(&self.layout.root) {
                    return Err(outside(format!("{rel} leads outside the granted folder")));
                }
                if side.mode == "120000" {
                    let t = fs::read_link(&full)
                        .map_err(|e| unavailable(format!("cannot read link {rel}: {e}")))?;
                    return Ok(t.to_string_lossy().into_owned().into_bytes());
                }
                let f = fs::File::open(&full)
                    .map_err(|e| unavailable(format!("cannot read {rel}: {e}")))?;
                let mut v = Vec::new();
                f.take(cap + 1)
                    .read_to_end(&mut v)
                    .map_err(|e| unavailable(format!("cannot read {rel}: {e}")))?;
                if v.len() as u64 > cap {
                    return Err(GitError::new(
                        ErrorCode::TooLarge,
                        format!("{rel} is larger than {cap} bytes"),
                    ));
                }
                Ok(v)
            }
        }
    }

    /// Stage-0 entries of the index: the tracked paths of the work tree.
    fn index_files(&self, snap: &Snapshot) -> Res<BTreeMap<String, String>> {
        let out = self
            .runner
            .run(&["ls-files", "--stage", "-z"], None, MAX_LIST_BYTES)?;
        let mut m = BTreeMap::new();
        for rec in out.split(|&b| b == 0).filter(|r| !r.is_empty()) {
            let Some(tab) = rec.iter().position(|&b| b == b'\t') else {
                continue;
            };
            let meta = String::from_utf8_lossy(&rec[..tab]).into_owned();
            let path = String::from_utf8_lossy(&rec[tab + 1..]).into_owned();
            let f: Vec<&str> = meta.split_whitespace().collect();
            if f.len() == 3 && f[0] != "160000" && !self.hidden(snap, &path) {
                m.entry(path).or_insert_with(|| f[0].to_string());
            }
        }
        Ok(m)
    }

    // -- changes, status, diff

    /// Files that are not tracked and not ignored. Nested repositories (listed with
    /// a trailing slash) are not entered.
    fn untracked_files(&self, snap: &Snapshot) -> Res<Vec<String>> {
        let out = self.runner.run(
            &["ls-files", "--others", "--exclude-standard", "-z"],
            None,
            MAX_LIST_BYTES,
        )?;
        Ok(out
            .split(|&b| b == 0)
            .filter(|r| !r.is_empty())
            .map(|r| String::from_utf8_lossy(r).into_owned())
            .filter(|p| !p.ends_with('/') && !self.hidden(snap, p))
            .collect())
    }

    fn base_tree(
        &self,
        snap: &Snapshot,
        base: Option<&str>,
    ) -> Res<(String, Option<String>, BTreeMap<String, Side>)> {
        let rev = base.unwrap_or("HEAD").to_string();
        let sha = self.commit_of(&validate_rev(&rev)?)?;
        match sha {
            Some(s) => {
                let files = self.tree_files(snap, &s)?;
                Ok((rev, Some(s), files))
            }
            None => Ok((rev, None, BTreeMap::new())), // no commit yet: an empty base
        }
    }

    fn changes(
        &self,
        snap: &Snapshot,
        req: &DiffRequest,
    ) -> Res<(BaseRev, HeadRev, Vec<Change>, bool)> {
        let filter = match &req.path {
            Some(p) => Some(self.check_path(snap, p)?),
            None => None,
        };
        let in_filter = |p: &str| match &filter {
            None => true,
            Some(f) => {
                p == f
                    || p.strip_prefix(f.as_str())
                        .is_some_and(|r| r.starts_with('/'))
            }
        };
        let (base_rev, base_sha, base_files) = self.base_tree(snap, req.base.as_deref())?;
        let base = BaseRev {
            rev: base_rev,
            sha: base_sha.unwrap_or_else(|| EMPTY_TREE.to_string()),
        };

        let (head, new_files): (HeadRev, BTreeMap<String, Option<Side>>) = match &req.head {
            Some(h) => {
                let sha = self
                    .commit_of(&validate_rev(h)?)?
                    .ok_or_else(|| not_found("no commits yet"))?;
                let files = self.tree_files(snap, &sha)?;
                (
                    HeadRev {
                        rev: Some(h.clone()),
                        sha: Some(sha),
                        worktree: false,
                    },
                    files.into_iter().map(|(k, v)| (k, Some(v))).collect(),
                )
            }
            None => {
                // Tracked paths: those of the base commit and of the index.
                let mut paths: BTreeSet<String> = base_files.keys().cloned().collect();
                let idx = self.index_files(snap)?;
                paths.extend(idx.keys().cloned());
                paths.extend(self.untracked_files(snap)?);
                let mut m = BTreeMap::new();
                for p in paths.into_iter().filter(|p| in_filter(p)) {
                    let fallback = base_files
                        .get(&p)
                        .map(|s| s.mode.clone())
                        .or_else(|| idx.get(&p).cloned());
                    m.insert(p.clone(), self.wt_side(snap, &p, fallback.as_deref())?);
                }
                (
                    HeadRev {
                        rev: None,
                        sha: None,
                        worktree: true,
                    },
                    m,
                )
            }
        };

        let mut changes: Vec<Change> = Vec::new();
        let mut all: BTreeSet<&String> = base_files.keys().collect();
        all.extend(new_files.keys());
        for p in all.into_iter().filter(|p| in_filter(p)) {
            let old = base_files.get(p).cloned();
            let new = new_files.get(p).cloned().flatten();
            let same = match (&old, &new) {
                (None, None) => true,
                (Some(a), Some(b)) => !a.oid.is_empty() && a.oid == b.oid && a.mode == b.mode,
                _ => false,
            };
            if !same {
                changes.push(Change {
                    path: p.clone(),
                    old,
                    new,
                    renamed_from: None,
                });
            }
        }
        pair_renames(&mut changes);
        let truncated = changes.len() > MAX_FILES;
        changes.truncate(MAX_FILES);
        Ok((base, head, changes, truncated))
    }

    pub fn status(&self) -> Res<Vec<StatusEntry>> {
        let snap = self.deny.snapshot();
        let (_, _, changes, _) = self.changes(&snap, &DiffRequest::default())?;
        Ok(changes
            .into_iter()
            .map(|c| StatusEntry {
                status: status_of(&c),
                old_path: c.renamed_from.clone(),
                path: c.path,
            })
            .collect())
    }

    pub fn diff(&self, req: &DiffRequest) -> Res<DiffResult> {
        let snap = self.deny.snapshot();
        let (base, head, changes, truncated) = self.changes(&snap, req)?;
        let opts = Options {
            context: req.context.unwrap_or_default(),
            ..Options::default()
        };
        let cap = opts.max_file_bytes as u64;
        let mut batch = self.runner.batch()?;
        let mut files = Vec::new();
        for c in &changes {
            let too_big = c.old.as_ref().is_some_and(|s| s.size > cap)
                || c.new.as_ref().is_some_and(|s| s.size > cap);
            if too_big {
                files.push(DiffFile {
                    path: c.path.clone(),
                    old_path: c.renamed_from.clone(),
                    status: status_of(c),
                    binary: false,
                    additions: 0,
                    deletions: 0,
                    similarity: c.renamed_from.as_ref().map(|_| 100),
                    old_mode: c.old.as_ref().map(|s| s.mode.clone()),
                    new_mode: c.new.as_ref().map(|s| s.mode.clone()),
                    too_large: true,
                    hunks: Vec::new(),
                });
                continue;
            }
            let old_bytes = match &c.old {
                Some(s) => Some(self.side_bytes(s, &mut batch, cap)?),
                None => None,
            };
            let new_bytes = match &c.new {
                Some(s) => Some(self.side_bytes(s, &mut batch, cap)?),
                None => None,
            };
            let input = FileInput {
                path: c.path.clone(),
                old_path: c.renamed_from.clone(),
                relation: c.renamed_from.as_ref().map(|_| Relation::Renamed),
                similarity: c.renamed_from.as_ref().map(|_| 100),
                old: old_bytes.as_deref(),
                new: new_bytes.as_deref(),
                old_mode: c.old.as_ref().map(|s| s.mode.clone()),
                new_mode: c.new.as_ref().map(|s| s.mode.clone()),
            };
            files.push(diff_file(&input, &opts));
        }
        Ok(DiffResult::new(base, head, files, truncated))
    }
}

fn status_of(c: &Change) -> DiffStatus {
    match (&c.old, &c.new) {
        (None, _) => DiffStatus::Added,
        (_, None) => DiffStatus::Deleted,
        _ if c.renamed_from.is_some() => DiffStatus::Renamed,
        (Some(a), Some(b)) if a.mode.get(..3) != b.mode.get(..3) => DiffStatus::Typechange,
        _ => DiffStatus::Modified,
    }
}

/// Exact renames: a deleted and an added file with the same non-empty content.
/// Both sides have already been through the denylist, so a protected old path
/// can never show up as the source of a rename.
fn pair_renames(changes: &mut Vec<Change>) {
    let mut deleted: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    for (i, c) in changes.iter().enumerate() {
        if let (Some(old), None) = (&c.old, &c.new) {
            if !old.oid.is_empty() && old.size > 0 {
                deleted.entry(old.oid.clone()).or_default().push(i);
            }
        }
    }
    let mut drop = BTreeSet::new();
    let mut moves: Vec<(usize, String, Side)> = Vec::new();
    for (i, c) in changes.iter().enumerate() {
        if let (None, Some(new)) = (&c.old, &c.new) {
            if new.oid.is_empty() || new.size == 0 {
                continue;
            }
            if let Some(list) = deleted.get_mut(&new.oid) {
                if let Some(j) = list.pop() {
                    let from = changes[j].old.clone().expect("deleted has an old side");
                    moves.push((i, changes[j].path.clone(), from));
                    drop.insert(j);
                }
            }
        }
    }
    for (i, from_path, from) in moves {
        changes[i].old = Some(from);
        changes[i].renamed_from = Some(from_path);
    }
    let mut idx = 0;
    changes.retain(|_| {
        let keep = !drop.contains(&idx);
        idx += 1;
        keep
    });
}

fn blob_oid(bytes: &[u8]) -> String {
    let mut h = Sha1::new();
    h.update(format!("blob {}\0", bytes.len()).as_bytes());
    h.update(bytes);
    hex(&h.finalize())
}

fn hash_file(path: &Path, len: u64) -> std::io::Result<String> {
    let mut h = Sha1::new();
    h.update(format!("blob {len}\0").as_bytes());
    let mut f = fs::File::open(path)?;
    let mut buf = vec![0u8; 64 * 1024];
    let mut seen = 0u64;
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        seen += n as u64;
        h.update(&buf[..n]);
    }
    if seen != len {
        return Ok(String::new()); // changed while reading: treat as unknown
    }
    Ok(hex(&h.finalize()))
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

#[cfg(unix)]
fn exec_mode(meta: &fs::Metadata, _fallback: Option<&str>) -> String {
    use std::os::unix::fs::PermissionsExt;
    if meta.permissions().mode() & 0o111 != 0 {
        "100755"
    } else {
        "100644"
    }
    .to_string()
}

#[cfg(not(unix))]
fn exec_mode(_meta: &fs::Metadata, fallback: Option<&str>) -> String {
    // No exec bit to read: keep what git recorded.
    fallback
        .filter(|m| m.starts_with("100"))
        .unwrap_or("100644")
        .to_string()
}

// ---- the lazy-fetch measurement -----------------------------------------------

/// Measure that the git found on this machine honours `GIT_NO_LAZY_FETCH`: a
/// repository set up like a partial clone whose remote is an `ext::` helper must
/// not start the helper when a missing object is read. The app runs this once
/// per git it finds; on failure `git:read` stays off, with the message as the
/// reason shown to the user.
#[cfg(unix)]
pub fn probe_no_lazy_fetch(env: &GitEnv, scratch: &Path) -> Res<()> {
    use std::os::unix::fs::PermissionsExt;
    let dir = scratch.join("lazy-fetch-probe");
    fs::create_dir_all(&dir)
        .map_err(|e| unavailable(format!("cannot prepare the git probe: {e}")))?;
    let repo = dir.join("repo");
    let sentinel = dir.join("helper-ran");
    let helper = dir.join("helper");
    let _ = fs::remove_file(&sentinel);
    fs::write(
        &helper,
        format!("#!/bin/sh\nprintf ran > '{}'\nexit 1\n", sentinel.display()),
    )
    .map_err(|e| unavailable(format!("cannot prepare the git probe: {e}")))?;
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o755))
        .map_err(|e| unavailable(e.to_string()))?;
    fs::create_dir_all(&repo).map_err(|e| unavailable(e.to_string()))?;
    let init = Runner {
        env: env.clone(),
        git_dir: repo.join(".git"),
        work_tree: repo.clone(),
        ceiling: dir.clone(),
    };
    let (ok, _, err) = {
        let mut c = init.command();
        let _ = &mut c;
        // `init` must not receive --git-dir, so build it by hand.
        let out = Command::new(&env.git)
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("HOME", &env.empty_dir)
            .env("GIT_CONFIG_GLOBAL", &env.empty_config)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .args(["init", "-q"])
            .arg(&repo)
            .output()
            .map_err(|e| unavailable(format!("cannot start git: {e}")))?;
        (
            out.status.success(),
            out.stdout,
            String::from_utf8_lossy(&out.stderr).into_owned(),
        )
    };
    if !ok {
        return Err(unavailable(format!(
            "git init failed in the probe: {}",
            first_line(&err)
        )));
    }
    let cfg = format!(
        "[core]\n\trepositoryformatversion = 1\n[extensions]\n\tpartialClone = origin\n[remote \"origin\"]\n\tpromisor = true\n\turl = ext::{}\n[protocol \"ext\"]\n\tallow = always\n",
        helper.display()
    );
    fs::write(repo.join(".git/config"), cfg).map_err(|e| unavailable(e.to_string()))?;
    let r = Runner {
        env: env.clone(),
        git_dir: repo.join(".git"),
        work_tree: repo.clone(),
        ceiling: dir.clone(),
    };
    let _ = r.run_raw(
        &["cat-file", "-p", "1234567890123456789012345678901234567890"],
        None,
        4096,
    )?;
    if sentinel.exists() {
        return Err(unavailable("this git starts a transport helper for a missing object (GIT_NO_LAZY_FETCH is not honoured); git:read is off"));
    }
    Ok(())
}

#[cfg(not(unix))]
pub fn probe_no_lazy_fetch(_env: &GitEnv, _scratch: &Path) -> Res<()> {
    Err(unavailable(
        "the lazy-fetch measurement is not implemented on this OS yet; git:read is off",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::addons::denylist::{DenyEnv, Os};
    use std::process::Command;

    struct Fx {
        _tmp: tempfile::TempDir,
        root: PathBuf,
        support: PathBuf,
    }

    fn fx() -> Fx {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().canonicalize().unwrap();
        let support = root.join("support");
        fs::create_dir_all(&support).unwrap();
        Fx {
            _tmp: tmp,
            root,
            support,
        }
    }

    fn git_in(dir: &Path, args: &[&str]) -> String {
        // A cleared environment: another test sets GIT_* variables in this process.
        let out = Command::new("git")
            .current_dir(dir)
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_AUTHOR_DATE", "2026-10-22T09:00:00Z")
            .env("GIT_COMMITTER_DATE", "2026-10-22T09:00:00Z")
            .args([
                "-c",
                "user.name=Tester",
                "-c",
                "user.email=t@example.com",
                "-c",
                "commit.gpgsign=false",
            ])
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8_lossy(&out.stdout).trim().to_string()
    }

    fn write(path: &Path, text: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }

    fn init(dir: &Path) {
        fs::create_dir_all(dir).unwrap();
        git_in(dir, &["init", "-q", "-b", "main"]);
    }

    fn commit_all(dir: &Path, msg: &str) -> String {
        git_in(dir, &["add", "-A"]);
        git_in(dir, &["commit", "-q", "-m", msg]);
        git_in(dir, &["rev-parse", "HEAD"])
    }

    fn deny_for(home: &Path) -> Arc<Denylist> {
        Arc::new(Denylist::new(&DenyEnv {
            os: Os::Linux,
            home: Some(home.to_path_buf()),
            appdata: None,
            local_appdata: None,
            system_drive: None,
            system_root: None,
            program_data: None,
            extra_subtrees: Vec::new(),
        }))
    }

    fn open_at(f: &Fx, repo: &Path) -> Res<GitBroker> {
        let env = GitEnv::new("git", &f.support).unwrap();
        GitBroker::open(&env, repo, deny_for(&f.root.join("home")))
    }

    fn code<T>(r: Res<T>) -> ErrorCode {
        match r {
            Err(e) => e.code,
            Ok(_) => panic!("expected an error"),
        }
    }

    /// A repository with a few files and one commit.
    fn basic(f: &Fx) -> PathBuf {
        let repo = f.root.join("repo");
        init(&repo);
        write(&repo.join("a.txt"), "one\ntwo\nthree\n");
        write(&repo.join("dir/b.txt"), "bee\n");
        write(&repo.join("run.sh"), "#!/bin/sh\necho hi\n");
        commit_all(&repo, "first");
        repo
    }

    // -- the positive control

    #[test]
    fn a_normal_repository_works_end_to_end() {
        let f = fx();
        let repo = basic(&f);
        write(&repo.join("a.txt"), "one\n2\nthree\n");
        fs::remove_file(repo.join("dir/b.txt")).unwrap();
        write(&repo.join("c.txt"), "new\n");
        git_in(&repo, &["add", "c.txt"]);
        let g = open_at(&f, &repo).unwrap();

        let d = g.diff(&DiffRequest::default()).unwrap();
        assert_eq!(d.base.rev, "HEAD");
        assert!(d.head.worktree);
        let by: BTreeMap<_, _> = d.files.iter().map(|x| (x.path.as_str(), x)).collect();
        assert_eq!(by["a.txt"].status, DiffStatus::Modified);
        assert_eq!((by["a.txt"].additions, by["a.txt"].deletions), (1, 1));
        assert_eq!(by["dir/b.txt"].status, DiffStatus::Deleted);
        assert_eq!(by["c.txt"].status, DiffStatus::Added);
        assert_eq!(d.files.len(), 3, "run.sh did not change");

        let st = g.status().unwrap();
        assert_eq!(st.len(), 3);

        let log = g.log(&LogRequest::default()).unwrap();
        assert_eq!(log.len(), 1);
        assert_eq!(log[0].subject, "first");
        assert_eq!(log[0].author, "Tester");
        assert!(is_hex_oid(&log[0].sha));

        let top = g.ls_tree("HEAD", "").unwrap();
        let names: Vec<_> = top
            .iter()
            .map(|e| (e.path.as_str(), e.kind.clone()))
            .collect();
        assert_eq!(
            names,
            vec![
                ("a.txt", TreeKind::File),
                ("dir", TreeKind::Dir),
                ("run.sh", TreeKind::File)
            ]
        );
        let sub = g.ls_tree("HEAD", "dir").unwrap();
        assert_eq!(sub.len(), 1);
        assert_eq!(sub[0].path, "dir/b.txt");
        assert_eq!(sub[0].size, Some(4));

        let shown = g.show("HEAD", Some("a.txt")).unwrap();
        assert_eq!(shown.bytes, b"one\ntwo\nthree\n");
        assert_eq!(shown.size, 14);
    }

    #[test]
    fn diff_between_commits_pairs_an_exact_rename_and_follows_merge_base() {
        let f = fx();
        let repo = basic(&f);
        let first = git_in(&repo, &["rev-parse", "HEAD"]);
        git_in(&repo, &["checkout", "-q", "-b", "feature"]);
        git_in(&repo, &["mv", "dir/b.txt", "dir/renamed.txt"]);
        write(&repo.join("a.txt"), "one\ntwo\nTHREE\n");
        commit_all(&repo, "second");
        let g = open_at(&f, &repo).unwrap();

        let d = g
            .diff(&DiffRequest {
                base: Some(first.clone()),
                head: Some("HEAD".into()),
                ..Default::default()
            })
            .unwrap();
        assert!(!d.head.worktree);
        assert_eq!(d.base.sha, first);
        let by: BTreeMap<_, _> = d.files.iter().map(|x| (x.path.as_str(), x)).collect();
        assert_eq!(by["dir/renamed.txt"].status, DiffStatus::Renamed);
        assert_eq!(by["dir/renamed.txt"].old_path.as_deref(), Some("dir/b.txt"));
        assert_eq!(by["a.txt"].status, DiffStatus::Modified);
        assert_eq!(d.files.len(), 2);

        let m = g
            .diff(&DiffRequest {
                base: Some("merge-base:main".into()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(
            m.base.sha, first,
            "the merge base of main and feature is the first commit"
        );
        assert!(m.files.iter().any(|x| x.path == "a.txt"));

        let only = g
            .diff(&DiffRequest {
                base: Some(first),
                head: Some("HEAD".into()),
                path: Some("a.txt".into()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(only.files.len(), 1);
        let all = g
            .diff(&DiffRequest {
                path: Some("a.txt".into()),
                context: Some(Context::All),
                ..Default::default()
            })
            .unwrap();
        assert!(all.files.is_empty(), "the worktree matches HEAD");
    }

    #[test]
    fn a_repository_without_commits_diffs_against_an_empty_tree() {
        let f = fx();
        let repo = f.root.join("repo");
        init(&repo);
        write(&repo.join("x.txt"), "x\n");
        git_in(&repo, &["add", "x.txt"]);
        let g = open_at(&f, &repo).unwrap();
        assert!(g.log(&LogRequest::default()).unwrap().is_empty());
        let d = g.diff(&DiffRequest::default()).unwrap();
        assert_eq!(d.files.len(), 1);
        assert_eq!(d.files[0].status, DiffStatus::Added);
        assert_eq!(d.base.sha, EMPTY_TREE);
    }

    #[test]
    fn oversized_worktree_files_are_marked_too_large_not_read() {
        let f = fx();
        let repo = basic(&f);
        write(&repo.join("big.txt"), &"x\n".repeat(1_100_000));
        git_in(&repo, &["add", "big.txt"]);
        let d = open_at(&f, &repo)
            .unwrap()
            .diff(&DiffRequest::default())
            .unwrap();
        let big = d.files.iter().find(|x| x.path == "big.txt").unwrap();
        assert!(big.too_large);
        assert!(big.hunks.is_empty());
    }

    // -- revision and path arguments

    #[test]
    fn revisions_that_could_be_options_ranges_or_expressions_are_refused() {
        for bad in [
            "",
            "--output=/tmp/x",
            "-h",
            "-",
            "HEAD:a.txt",
            "a..b",
            "a...b",
            "HEAD~1",
            "HEAD^",
            "@{u}",
            "a b",
            "a\nb",
            "/x",
            "x/",
            ".hidden",
            "x.lock",
            ":/msg",
            "merge-base:",
            "merge-base:--x",
            "merge-base:a..b",
            "a?b",
            "a*b",
            "a[b",
            "a\\b",
        ] {
            assert_eq!(
                validate_rev(bad).unwrap_err().code,
                ErrorCode::BadArgs,
                "{bad:?}"
            );
        }
        for ok in [
            "HEAD",
            "main",
            "feature/x-1",
            "v1.2.3",
            "origin/main",
            "9f3e1b0c2a7d4e8f6b5a1c3d2e4f5a6b7c8d9e0f",
            "abc123",
        ] {
            assert!(validate_rev(ok).is_ok(), "{ok}");
        }
        assert_eq!(
            validate_rev("merge-base:main").unwrap(),
            RevSpec::MergeBase("main".into())
        );
    }

    #[test]
    fn bad_revisions_never_reach_git() {
        let f = fx();
        let repo = basic(&f);
        let g = open_at(&f, &repo).unwrap();
        let marker = f.root.join("output-written");
        let opt = format!("--output={}", marker.display());
        assert_eq!(code(g.resolve_rev(&opt)), ErrorCode::BadArgs);
        assert_eq!(
            code(g.log(&LogRequest {
                rev: Some(opt.clone()),
                ..Default::default()
            })),
            ErrorCode::BadArgs
        );
        assert_eq!(
            code(g.diff(&DiffRequest {
                base: Some(opt),
                ..Default::default()
            })),
            ErrorCode::BadArgs
        );
        assert!(!marker.exists());
        assert_eq!(code(g.resolve_rev("nosuchbranch")), ErrorCode::NotFound);
    }

    #[test]
    fn paths_must_be_plain_and_relative() {
        let f = fx();
        let repo = basic(&f);
        let g = open_at(&f, &repo).unwrap();
        for bad in ["../x", "/etc/passwd", "a/../b", "", "a\\b", ":(top)a.txt"] {
            let r = g.show("HEAD", Some(bad));
            if bad == ":(top)a.txt" {
                // Not a path component trick: pathspec magic is literal and simply absent.
                assert_eq!(code(r), ErrorCode::NotFound);
            } else {
                assert_eq!(code(r), ErrorCode::BadArgs, "{bad:?}");
            }
        }
        assert_eq!(code(g.show("HEAD", Some("nope.txt"))), ErrorCode::NotFound);
        assert_eq!(
            code(g.show("HEAD", Some("dir"))),
            ErrorCode::BadArgs,
            "a folder is not a file"
        );
    }

    #[test]
    fn a_bare_object_id_is_never_a_request() {
        let f = fx();
        let repo = basic(&f);
        let g = open_at(&f, &repo).unwrap();
        let blob = git_in(&repo, &["rev-parse", "HEAD:a.txt"]);
        let tree = git_in(&repo, &["rev-parse", "HEAD^{tree}"]);
        assert_eq!(code(g.show(&blob, None)), ErrorCode::BadArgs);
        assert_eq!(code(g.show(&blob, Some(""))), ErrorCode::BadArgs);
        assert_eq!(code(g.show("HEAD", None)), ErrorCode::BadArgs);
        // An id in the revision slot is not a commit: no blob or tree is read.
        assert_eq!(code(g.show(&blob, Some("a.txt"))), ErrorCode::NotFound);
        assert_eq!(code(g.show(&tree, Some("a.txt"))), ErrorCode::NotFound);
        assert_eq!(code(g.ls_tree(&blob, "")), ErrorCode::NotFound);
    }

    #[test]
    fn requests_decode_from_json() {
        let r: DiffRequest =
            serde_json::from_str(r#"{"base":"main","context":"all","path":"a"}"#).unwrap();
        assert_eq!(
            (r.base.as_deref(), r.context, r.path.as_deref()),
            (Some("main"), Some(Context::All), Some("a"))
        );
        let r: DiffRequest = serde_json::from_str(r#"{"context":0}"#).unwrap();
        assert_eq!(r.context, Some(Context::Lines(0)));
        assert!(serde_json::from_str::<DiffRequest>(r#"{"context":"lots"}"#).is_err());
        assert!(serde_json::from_str::<DiffRequest>("{}")
            .unwrap()
            .context
            .is_none());
    }

    // -- layout: nothing may lead outside the granted folder

    fn outside_dir(f: &Fx) -> PathBuf {
        let d = f.root.join("outside");
        fs::create_dir_all(&d).unwrap();
        write(&d.join("sentinel.txt"), "OUTSIDE-SECRET");
        d
    }

    #[test]
    fn core_worktree_in_repo_config_is_refused() {
        let f = fx();
        let repo = basic(&f);
        let out = outside_dir(&f);
        git_in(&repo, &["config", "core.worktree", out.to_str().unwrap()]);
        assert_eq!(code(open_at(&f, &repo)), ErrorCode::OutsideRoot);
    }

    #[test]
    fn core_worktree_in_any_spelling_or_included_file_is_refused() {
        let f = fx();
        let out = outside_dir(&f);
        let cases: Vec<(&str, String)> = vec![
            (
                "mixed case",
                format!("[core]\n\tWorkTree = {}\n", out.display()),
            ),
            (
                "same line",
                format!("[core] worktree = {}\n", out.display()),
            ),
            (
                "quoted",
                format!("[core]\n\tworktree = \"{}\"\n", out.display()),
            ),
            ("include", "[include]\n\tpath = extra.cfg\n".to_string()),
            (
                "includeIf",
                "[includeIf \"gitdir:**\"]\n\tpath = extra.cfg\n".to_string(),
            ),
            (
                "includeif lower",
                "[includeif \"gitdir:**\"]\n\tPATH = extra.cfg\n".to_string(),
            ),
        ];
        for (name, cfg) in cases {
            let repo = f.root.join(format!("repo-{}", name.replace(' ', "-")));
            init(&repo);
            write(&repo.join("a.txt"), "a\n");
            commit_all(&repo, "c");
            write(
                &repo.join(".git/extra.cfg"),
                &format!("[core]\n\tworktree = {}\n", out.display()),
            );
            let mut c = fs::read_to_string(repo.join(".git/config")).unwrap();
            c.push_str(&cfg);
            fs::write(repo.join(".git/config"), c).unwrap();
            assert_eq!(code(open_at(&f, &repo)), ErrorCode::OutsideRoot, "{name}");
        }
    }

    #[test]
    fn a_config_include_that_leaves_the_folder_is_refused_even_if_harmless() {
        let f = fx();
        let repo = basic(&f);
        let elsewhere = f.root.join("shared.cfg");
        write(&elsewhere, "[user]\n\tname = x\n");
        let mut c = fs::read_to_string(repo.join(".git/config")).unwrap();
        c.push_str(&format!("[include]\n\tpath = {}\n", elsewhere.display()));
        fs::write(repo.join(".git/config"), c).unwrap();
        assert_eq!(code(open_at(&f, &repo)), ErrorCode::OutsideRoot);
        // A home-relative include is refused as well.
        let repo2 = f.root.join("repo2");
        init(&repo2);
        write(&repo2.join("a"), "a");
        commit_all(&repo2, "c");
        let mut c = fs::read_to_string(repo2.join(".git/config")).unwrap();
        c.push_str("[include]\n\tpath = ~/.gitconfig-extra\n");
        fs::write(repo2.join(".git/config"), c).unwrap();
        assert_eq!(code(open_at(&f, &repo2)), ErrorCode::OutsideRoot);
    }

    #[test]
    fn an_include_inside_the_folder_is_read_and_allowed() {
        let f = fx();
        let repo = basic(&f);
        write(&repo.join(".git/inner.cfg"), "[user]\n\tname = inner\n");
        let mut c = fs::read_to_string(repo.join(".git/config")).unwrap();
        c.push_str("[include]\n\tpath = inner.cfg\n");
        fs::write(repo.join(".git/config"), c).unwrap();
        assert!(open_at(&f, &repo).is_ok());
    }

    #[test]
    fn a_gitfile_pointing_outside_is_refused() {
        let f = fx();
        let out = f.root.join("elsewhere.git");
        init(&f.root.join("seed"));
        git_in(
            &f.root,
            &["clone", "-q", "--bare", "seed", out.to_str().unwrap()],
        );
        for target in [out.display().to_string(), "../elsewhere.git".to_string()] {
            let repo = f.root.join("granted");
            fs::create_dir_all(&repo).unwrap();
            fs::write(repo.join(".git"), format!("gitdir: {target}\n")).unwrap();
            assert_eq!(code(open_at(&f, &repo)), ErrorCode::OutsideRoot, "{target}");
        }
    }

    #[test]
    fn a_commondir_pointing_outside_is_refused() {
        let f = fx();
        let repo = basic(&f);
        let outer = f.root.join("outer-repo");
        init(&outer);
        write(&outer.join("o"), "o");
        commit_all(&outer, "o");
        fs::write(
            repo.join(".git/commondir"),
            format!("{}\n", outer.join(".git").display()),
        )
        .unwrap();
        assert_eq!(code(open_at(&f, &repo)), ErrorCode::OutsideRoot);
    }

    #[test]
    fn a_linked_worktree_whose_main_repository_is_outside_is_refused() {
        let f = fx();
        let main = f.root.join("main");
        init(&main);
        write(&main.join("a"), "a");
        commit_all(&main, "a");
        let wt = f.root.join("granted-wt");
        git_in(
            &main,
            &["worktree", "add", "-q", wt.to_str().unwrap(), "-b", "side"],
        );
        assert_eq!(code(open_at(&f, &wt)), ErrorCode::OutsideRoot);
        // The main checkout itself is fine, and so is a worktree granted with its main repo.
        assert!(open_at(&f, &main).is_ok());
    }

    #[test]
    fn alternates_outside_the_folder_are_refused_inside_are_allowed() {
        let f = fx();
        let out = f.root.join("other-repo");
        init(&out);
        write(&out.join("o"), "o");
        commit_all(&out, "o");
        let repo = basic(&f);
        let alt = repo.join(".git/objects/info/alternates");
        write(&alt, &format!("{}\n", out.join(".git/objects").display()));
        assert_eq!(code(open_at(&f, &repo)), ErrorCode::OutsideRoot);
        write(&alt, "../../../../other-repo/.git/objects\n");
        assert_eq!(
            code(open_at(&f, &repo)),
            ErrorCode::OutsideRoot,
            "a relative alternate that climbs out"
        );
        let inside = repo.join("extra-objects");
        fs::create_dir_all(&inside).unwrap();
        write(&alt, &format!("# comment\n\n{}\n", inside.display()));
        assert!(
            open_at(&f, &repo).is_ok(),
            "an alternate that stays inside is allowed"
        );
    }

    #[test]
    fn nested_alternates_are_followed() {
        let f = fx();
        let repo = basic(&f);
        let inner = repo.join("vendor-objects");
        write(
            &inner.join("info/alternates"),
            &format!("{}\n", f.root.join("other/.git/objects").display()),
        );
        write(
            &repo.join(".git/objects/info/alternates"),
            &format!("{}\n", inner.display()),
        );
        assert_eq!(code(open_at(&f, &repo)), ErrorCode::OutsideRoot);
    }

    #[cfg(unix)]
    #[test]
    fn git_directory_files_that_are_links_leading_out_are_refused() {
        let f = fx();
        let out = outside_dir(&f);
        for name in ["HEAD", "config", "index"] {
            let repo = f.root.join(format!("repo-{name}"));
            init(&repo);
            write(&repo.join("a"), "a");
            commit_all(&repo, "c");
            let p = repo.join(".git").join(name);
            fs::remove_file(&p).unwrap();
            std::os::unix::fs::symlink(out.join("sentinel.txt"), &p).unwrap();
            assert_eq!(code(open_at(&f, &repo)), ErrorCode::OutsideRoot, "{name}");
        }
        // A .git that is itself a link out.
        let repo = f.root.join("repo-dotgit-link");
        fs::create_dir_all(&repo).unwrap();
        std::os::unix::fs::symlink(f.root.join("repo-HEAD/.git"), repo.join(".git")).unwrap();
        assert_eq!(code(open_at(&f, &repo)), ErrorCode::OutsideRoot);
    }

    /// An outside repository whose only file is secret.txt, packed or loose.
    #[cfg(unix)]
    fn outside_repo_with_secret(f: &Fx, packed: bool) -> PathBuf {
        let out = f.root.join("outside-repo");
        init(&out);
        write(&out.join("secret.txt"), "OUTSIDE SENTINEL\n");
        commit_all(&out, "secret");
        if packed {
            git_in(&out, &["repack", "-q", "-a", "-d"]);
            git_in(&out, &["prune-packed"]);
        }
        out
    }

    #[cfg(unix)]
    fn link(target: &Path, at: &Path) {
        fs::create_dir_all(at.parent().unwrap()).unwrap();
        let _ = fs::remove_dir_all(at);
        let _ = fs::remove_file(at);
        std::os::unix::fs::symlink(target, at).unwrap();
    }

    #[cfg(unix)]
    fn assert_secret_never_returned(f: &Fx, repo: &Path) {
        match open_at(f, repo) {
            Err(e) => assert_eq!(e.code, ErrorCode::OutsideRoot, "{e}"),
            Ok(g) => {
                let r = g.show("HEAD", Some("secret.txt"));
                panic!(
                    "the layout was accepted; show returned {:?}",
                    r.map(|x| x.bytes)
                );
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn packed_objects_and_refs_linked_from_outside_are_refused() {
        let f = fx();
        let out = outside_repo_with_secret(&f, true);
        let repo = f.root.join("granted");
        init(&repo);
        link(
            &out.join(".git/objects/pack"),
            &repo.join(".git/objects/pack"),
        );
        link(
            &out.join(".git/refs/heads/main"),
            &repo.join(".git/refs/heads/main"),
        );
        assert_secret_never_returned(&f, &repo);
        // Each link alone is refused as well.
        link(
            &out.join(".git/objects/pack"),
            &repo.join(".git/objects/pack"),
        );
        let _ = fs::remove_file(repo.join(".git/refs/heads/main"));
        assert_eq!(code(open_at(&f, &repo)), ErrorCode::OutsideRoot);
        fs::remove_file(repo.join(".git/objects/pack")).unwrap();
        fs::create_dir_all(repo.join(".git/objects/pack")).unwrap();
        link(
            &out.join(".git/refs/heads/main"),
            &repo.join(".git/refs/heads/main"),
        );
        assert_eq!(code(open_at(&f, &repo)), ErrorCode::OutsideRoot);
        // A single pack file, a nested ref folder and packed-refs.
        let _ = fs::remove_file(repo.join(".git/refs/heads/main"));
        for entry in fs::read_dir(out.join(".git/objects/pack"))
            .unwrap()
            .flatten()
        {
            link(
                &entry.path(),
                &repo.join(".git/objects/pack").join(entry.file_name()),
            );
        }
        assert_eq!(
            code(open_at(&f, &repo)),
            ErrorCode::OutsideRoot,
            "a link to one pack file"
        );
        link(&out.join(".git/refs/heads"), &repo.join(".git/refs/heads"));
        assert_eq!(
            code(open_at(&f, &repo)),
            ErrorCode::OutsideRoot,
            "a linked refs/heads folder"
        );
    }

    #[cfg(unix)]
    #[test]
    fn loose_objects_linked_from_outside_are_refused() {
        let f = fx();
        let out = outside_repo_with_secret(&f, false);
        let blob = git_in(&out, &["rev-parse", "HEAD:secret.txt"]);
        let commit = git_in(&out, &["rev-parse", "HEAD"]);
        let tree = git_in(&out, &["rev-parse", "HEAD^{tree}"]);
        let repo = f.root.join("granted");
        init(&repo);
        // A whole fanout folder.
        for oid in [&blob, &commit, &tree] {
            link(
                &out.join(".git/objects").join(&oid[..2]),
                &repo.join(".git/objects").join(&oid[..2]),
            );
        }
        link(
            &out.join(".git/refs/heads/main"),
            &repo.join(".git/refs/heads/main"),
        );
        assert_secret_never_returned(&f, &repo);
        // Single object files inside real folders.
        let repo2 = f.root.join("granted2");
        init(&repo2);
        for oid in [&blob, &commit, &tree] {
            link(
                &out.join(".git/objects").join(&oid[..2]).join(&oid[2..]),
                &repo2.join(".git/objects").join(&oid[..2]).join(&oid[2..]),
            );
        }
        fs::write(repo2.join(".git/refs/heads/main"), format!("{commit}\n")).unwrap();
        assert_secret_never_returned(&f, &repo2);
    }

    #[cfg(unix)]
    #[test]
    fn a_link_to_a_folder_inside_the_root_does_not_hide_a_link_out() {
        let f = fx();
        let out = outside_repo_with_secret(&f, true);
        let repo = f.root.join("granted");
        init(&repo);
        // .git/objects and .git/refs are links to folders inside the root; the links
        // out are one level further in.
        let inside_objects = repo.join("inside-objects");
        let inside_refs = repo.join("inside-refs");
        fs::create_dir_all(&inside_objects).unwrap();
        fs::create_dir_all(inside_refs.join("heads")).unwrap();
        link(&out.join(".git/objects/pack"), &inside_objects.join("pack"));
        link(
            &out.join(".git/refs/heads/main"),
            &inside_refs.join("heads/main"),
        );
        fs::remove_dir_all(repo.join(".git/objects")).unwrap();
        fs::remove_dir_all(repo.join(".git/refs")).unwrap();
        link(&inside_objects, &repo.join(".git/objects"));
        link(&inside_refs, &repo.join(".git/refs"));
        assert_secret_never_returned(&f, &repo);
    }

    #[cfg(unix)]
    #[test]
    fn link_cycles_inside_the_git_directory_do_not_loop() {
        let f = fx();
        let repo = basic(&f);
        link(&repo.join(".git"), &repo.join(".git/objects/info/cycle"));
        link(&repo.join(".git/objects"), &repo.join(".git/refs/loop"));
        assert!(open_at(&f, &repo).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn a_link_that_stays_inside_the_folder_is_allowed() {
        let f = fx();
        let repo = basic(&f);
        let keep = repo.join("kept-objects");
        fs::create_dir_all(&keep).unwrap();
        link(&keep, &repo.join(".git/objects/info/inside-link"));
        assert!(open_at(&f, &repo).is_ok());
    }

    #[cfg(unix)]
    #[test]
    fn the_alternates_file_and_alternate_stores_are_checked_for_links_too() {
        let f = fx();
        let out = outside_repo_with_secret(&f, true);
        let repo = basic(&f);
        // info/alternates itself is a link to an outside file.
        let list = f.root.join("alternates-list");
        write(&list, &format!("{}\n", repo.join("store").display()));
        fs::create_dir_all(repo.join("store")).unwrap();
        link(&list, &repo.join(".git/objects/info/alternates"));
        assert_eq!(code(open_at(&f, &repo)), ErrorCode::OutsideRoot);
        // An alternate store inside the folder that holds a link out.
        fs::remove_file(repo.join(".git/objects/info/alternates")).unwrap();
        write(
            &repo.join(".git/objects/info/alternates"),
            &format!("{}\n", repo.join("store").display()),
        );
        link(&out.join(".git/objects/pack"), &repo.join("store/pack"));
        assert_eq!(code(open_at(&f, &repo)), ErrorCode::OutsideRoot);
    }

    #[test]
    fn control_files_that_are_too_large_to_scan_are_refused() {
        let f = fx();
        let big_comment = format!("# {}\n", "x".repeat(1_100_000));
        // config
        let repo = f.root.join("big-config");
        init(&repo);
        write(&repo.join("a"), "a");
        commit_all(&repo, "c");
        let mut c = fs::read_to_string(repo.join(".git/config")).unwrap();
        c.push_str(&big_comment);
        c.push_str("[extensions]\n\tpartialClone = origin\n");
        fs::write(repo.join(".git/config"), c).unwrap();
        let e = open_at(&f, &repo).err().expect("refused");
        assert_eq!(e.code, ErrorCode::UnsupportedRepo);
        assert!(e.message.contains("cannot be checked"), "{}", e.message);
        // an included file
        let repo = f.root.join("big-include");
        init(&repo);
        write(&repo.join("a"), "a");
        commit_all(&repo, "c");
        write(
            &repo.join(".git/inc.cfg"),
            &format!("{big_comment}[core]\n\tworktree = /elsewhere\n"),
        );
        let mut c = fs::read_to_string(repo.join(".git/config")).unwrap();
        c.push_str("[include]\n\tpath = inc.cfg\n");
        fs::write(repo.join(".git/config"), c).unwrap();
        assert_eq!(code(open_at(&f, &repo)), ErrorCode::UnsupportedRepo);
        // alternates, commondir and a gitfile
        let repo = basic(&f);
        write(
            &repo.join(".git/objects/info/alternates"),
            &format!("{big_comment}/somewhere/else\n"),
        );
        assert_eq!(code(open_at(&f, &repo)), ErrorCode::UnsupportedRepo);
        let repo = f.root.join("big-gitfile");
        fs::create_dir_all(&repo).unwrap();
        fs::write(repo.join(".git"), format!("gitdir: .real\n{big_comment}")).unwrap();
        assert_eq!(code(open_at(&f, &repo)), ErrorCode::UnsupportedRepo);
    }

    #[cfg(unix)]
    #[test]
    fn a_control_file_that_cannot_be_read_is_refused_not_skipped() {
        use std::os::unix::fs::PermissionsExt;
        let f = fx();
        let repo = basic(&f);
        let cfg = repo.join(".git/config");
        fs::set_permissions(&cfg, fs::Permissions::from_mode(0o000)).unwrap();
        // Skip when running as a user that can read anything.
        if fs::File::open(&cfg).is_err() {
            assert_eq!(code(open_at(&f, &repo)), ErrorCode::UnsupportedRepo);
        }
        fs::set_permissions(&cfg, fs::Permissions::from_mode(0o644)).unwrap();
    }

    #[test]
    fn not_a_repository_is_unsupported() {
        let f = fx();
        let plain = f.root.join("plain");
        fs::create_dir_all(&plain).unwrap();
        assert_eq!(code(open_at(&f, &plain)), ErrorCode::UnsupportedRepo);
        // A subfolder of a repository is not the repository root.
        let repo = basic(&f);
        assert_eq!(
            code(open_at(&f, &repo.join("dir"))),
            ErrorCode::UnsupportedRepo
        );
        assert_eq!(
            code(open_at(&f, &f.root.join("missing"))),
            ErrorCode::NotFound
        );
    }

    // -- partial clones and the lazy-fetch helper (an ext:: transport that writes a marker file)

    #[cfg(unix)]
    fn helper_script(dir: &Path, name: &str) -> (PathBuf, PathBuf) {
        use std::os::unix::fs::PermissionsExt;
        let sentinel = dir.join(format!("{name}-ran"));
        let script = dir.join(name);
        fs::write(
            &script,
            format!("#!/bin/sh\nprintf ran > '{}'\nexit 1\n", sentinel.display()),
        )
        .unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        (script, sentinel)
    }

    #[cfg(unix)]
    fn partial_clone_repo(f: &Fx) -> (PathBuf, PathBuf) {
        let repo = f.root.join("partial");
        init(&repo);
        write(&repo.join("a.txt"), "a\n");
        commit_all(&repo, "c");
        let (helper, sentinel) = helper_script(&f.root, "transport");
        let mut c = fs::read_to_string(repo.join(".git/config")).unwrap();
        c.push_str(&format!(
            "[extensions]\n\tpartialClone = origin\n[remote \"origin\"]\n\tpromisor = true\n\turl = ext::{}\n\tpartialclonefilter = blob:none\n[protocol \"ext\"]\n\tallow = always\n",
            helper.display()
        ));
        fs::write(repo.join(".git/config"), c).unwrap();
        (repo, sentinel)
    }

    #[cfg(unix)]
    #[test]
    fn a_partial_clone_is_unsupported_and_its_helper_never_runs() {
        let f = fx();
        let (repo, sentinel) = partial_clone_repo(&f);
        assert_eq!(code(open_at(&f, &repo)), ErrorCode::UnsupportedRepo);
        assert!(
            !sentinel.exists(),
            "the repo-configured ext:: helper must never start"
        );
        // Each marker alone is enough.
        for cfg in [
            "[extensions]\n\tpartialClone = origin\n",
            "[remote \"o\"]\n\tpromisor = true\n",
            "[extensions]\n\tobjectFormat = sha256\n",
        ] {
            let r = f.root.join("one-marker");
            let _ = fs::remove_dir_all(&r);
            init(&r);
            write(&r.join("a"), "a");
            commit_all(&r, "c");
            let mut c = fs::read_to_string(r.join(".git/config")).unwrap();
            c.push_str(cfg);
            fs::write(r.join(".git/config"), c).unwrap();
            assert_eq!(code(open_at(&f, &r)), ErrorCode::UnsupportedRepo, "{cfg}");
        }
        // A promisor pack marks a partial clone even when the config does not.
        let r = f.root.join("promisor-pack");
        init(&r);
        write(&r.join("a"), "a");
        commit_all(&r, "c");
        write(&r.join(".git/objects/pack/pack-1234.promisor"), "");
        assert_eq!(code(open_at(&f, &r)), ErrorCode::UnsupportedRepo);
    }

    #[cfg(unix)]
    #[test]
    fn even_with_the_layout_check_bypassed_a_missing_object_does_not_start_the_helper() {
        // Defence in depth: the runner's own environment and flags must stop the
        // lazy fetch, in case a partial-clone marker is ever missed.
        let f = fx();
        let (repo, sentinel) = partial_clone_repo(&f);
        let env = GitEnv::new("git", &f.support).unwrap();
        let runner = Runner {
            env,
            git_dir: repo.join(".git"),
            work_tree: repo.clone(),
            ceiling: f.root.clone(),
        };
        let missing = "1234567890123456789012345678901234567890";
        let (ok, _, _) = runner
            .run_raw(&["cat-file", "-p", missing], None, 4096)
            .unwrap();
        assert!(!ok);
        let mut batch = runner.batch().unwrap();
        assert_eq!(
            batch.blob(missing, 1024).unwrap_err().code,
            ErrorCode::NotFound
        );
        assert!(!sentinel.exists(), "no transport helper may run");
    }

    #[cfg(unix)]
    #[test]
    fn the_probe_passes_on_this_git() {
        let f = fx();
        let env = GitEnv::new("git", &f.support).unwrap();
        probe_no_lazy_fetch(&env, &f.root).unwrap();
    }

    // -- repo config that runs programs

    #[cfg(unix)]
    #[test]
    fn programs_named_in_repo_config_never_run() {
        let f = fx();
        let repo = basic(&f);
        let sdir = f.root.join("scripts");
        fs::create_dir_all(&sdir).unwrap();
        let (fsmon, s_fsmon) = helper_script(&sdir, "fsmonitor");
        let (clean, s_clean) = helper_script(&sdir, "clean");
        let (smudge, s_smudge) = helper_script(&sdir, "smudge");
        let (textconv, s_textconv) = helper_script(&sdir, "textconv");
        let (extdiff, s_extdiff) = helper_script(&sdir, "extdiff");
        let (gpg, s_gpg) = helper_script(&sdir, "gpg");
        let (pager, s_pager) = helper_script(&sdir, "pager");
        let hooks = f.root.join("hooks");
        fs::create_dir_all(&hooks).unwrap();
        let (hook, s_hook) = helper_script(&sdir, "hook");
        for name in [
            "reference-transaction",
            "post-checkout",
            "post-index-change",
            "pre-commit",
        ] {
            fs::copy(&hook, hooks.join(name)).unwrap();
        }
        let set = |k: &str, v: &str| git_in(&repo, &["config", k, v]);
        set("core.fsmonitor", fsmon.to_str().unwrap());
        set("filter.evil.clean", clean.to_str().unwrap());
        set("filter.evil.smudge", smudge.to_str().unwrap());
        set("filter.evil.required", "false");
        set("diff.evil.textconv", textconv.to_str().unwrap());
        set("diff.external", extdiff.to_str().unwrap());
        set("gpg.program", gpg.to_str().unwrap());
        set("log.showSignature", "true");
        set("core.pager", pager.to_str().unwrap());
        set("core.hooksPath", hooks.to_str().unwrap());
        write(&repo.join(".gitattributes"), "* filter=evil diff=evil\n");
        write(&repo.join("a.txt"), "one\nCHANGED\nthree\n");

        // The fixture is live: plain git, in the same repo, does start the monitor.
        git_in(&repo, &["status", "--porcelain"]);
        assert!(
            s_fsmon.exists(),
            "the fixture must be able to trigger the program, or this test proves nothing"
        );
        for s in [
            &s_fsmon,
            &s_clean,
            &s_smudge,
            &s_textconv,
            &s_extdiff,
            &s_gpg,
            &s_pager,
            &s_hook,
        ] {
            let _ = fs::remove_file(s);
        }

        let g = open_at(&f, &repo).unwrap();
        g.diff(&DiffRequest::default()).unwrap();
        g.status().unwrap();
        g.log(&LogRequest::default()).unwrap();
        g.ls_tree("HEAD", "").unwrap();
        g.show("HEAD", Some("a.txt")).unwrap();
        g.diff(&DiffRequest {
            base: Some("HEAD".into()),
            head: Some("HEAD".into()),
            ..Default::default()
        })
        .unwrap();
        for (name, s) in [
            ("fsmonitor", &s_fsmon),
            ("clean filter", &s_clean),
            ("smudge filter", &s_smudge),
            ("textconv", &s_textconv),
            ("external diff", &s_extdiff),
            ("gpg", &s_gpg),
            ("pager", &s_pager),
            ("hook", &s_hook),
        ] {
            assert!(!s.exists(), "{name} ran");
        }
    }

    #[cfg(unix)]
    #[test]
    #[serial_test::serial]
    fn git_variables_in_the_apps_environment_do_not_reach_git() {
        use std::os::unix::fs::PermissionsExt;
        let f = fx();
        let repo = basic(&f);
        let elsewhere = f.root.join("elsewhere");
        fs::create_dir_all(&elsewhere).unwrap();
        let hostile = [
            ("GIT_DIR", "/nonexistent/.git"),
            ("GIT_WORK_TREE", "/nonexistent"),
            ("GIT_INDEX_FILE", "/nonexistent/index"),
            ("GIT_COMMON_DIR", "/nonexistent"),
            ("GIT_OBJECT_DIRECTORY", "/nonexistent"),
            ("GIT_ALTERNATE_OBJECT_DIRECTORIES", "/nonexistent"),
            ("GIT_CONFIG_COUNT", "1"),
            ("GIT_CONFIG_KEY_0", "core.worktree"),
            ("GIT_CONFIG_VALUE_0", "/nonexistent"),
            ("GIT_CONFIG_PARAMETERS", "'core.worktree=/nonexistent'"),
            ("GIT_EXTERNAL_DIFF", "/nonexistent/diff"),
            ("GIT_SSH_COMMAND", "/nonexistent/ssh"),
        ];
        for (k, v) in hostile {
            std::env::set_var(k, v);
        }
        // A stand-in for git that records the environment it was started with.
        let dump = f.root.join("env-dump");
        let fake = f.root.join("fake-git");
        fs::write(
            &fake,
            format!("#!/bin/sh\nenv > '{}'\nexit 1\n", dump.display()),
        )
        .unwrap();
        fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
        let env = GitEnv::new(&fake, &f.support).unwrap();
        let runner = Runner {
            env,
            git_dir: repo.join(".git"),
            work_tree: repo.clone(),
            ceiling: f.root.clone(),
        };
        let _ = runner.run_raw(&["rev-parse", "HEAD"], None, 4096);
        let seen = fs::read_to_string(&dump).unwrap_or_default();
        // And the real thing still sees only the repository it was pointed at.
        let real = open_at(&f, &repo).and_then(|g| g.diff(&DiffRequest::default()));
        for (k, _) in hostile {
            std::env::remove_var(k);
        }
        let vars: BTreeSet<&str> = seen
            .lines()
            .filter_map(|l| l.split_once('='))
            .map(|(k, _)| k)
            .collect();
        for (k, _) in hostile {
            assert!(!vars.contains(k), "{k} reached git");
        }
        let ours = [
            "GIT_CONFIG_NOSYSTEM",
            "GIT_CONFIG_GLOBAL",
            "GIT_NO_REPLACE_OBJECTS",
            "GIT_OPTIONAL_LOCKS",
            "GIT_CEILING_DIRECTORIES",
            "GIT_NO_LAZY_FETCH",
            "GIT_PROTOCOL_FROM_USER",
            "GIT_TERMINAL_PROMPT",
        ];
        let git_vars: BTreeSet<&str> = vars
            .iter()
            .copied()
            .filter(|k| k.starts_with("GIT_"))
            .collect();
        assert_eq!(git_vars, ours.iter().copied().collect::<BTreeSet<_>>());
        assert!(real.is_ok(), "{real:?}");
    }

    // -- time limit

    #[cfg(unix)]
    fn hanging_git(f: &Fx) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let fake = f.root.join("hanging-git");
        // exec: the sleeping process is the one that gets killed.
        fs::write(&fake, "#!/bin/sh\nexec sleep 20\n").unwrap();
        fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
        fake
    }

    #[cfg(unix)]
    #[test]
    fn a_git_run_that_hangs_is_killed_and_reported() {
        let f = fx();
        let repo = basic(&f);
        let mut env = GitEnv::new(hanging_git(&f), &f.support).unwrap();
        env.timeout = Duration::from_millis(300);
        let runner = Runner {
            env,
            git_dir: repo.join(".git"),
            work_tree: repo.clone(),
            ceiling: f.root.clone(),
        };
        let started = Instant::now();
        let err = runner
            .run_raw(&["rev-parse", "HEAD"], None, 4096)
            .unwrap_err();
        assert_eq!(err.code, ErrorCode::NotAvailable);
        assert!(err.message.contains("did not answer"), "{}", err.message);
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "returned only after {:?}",
            started.elapsed()
        );
    }

    #[cfg(unix)]
    #[test]
    fn an_object_reader_that_stops_answering_is_killed_and_reported() {
        let f = fx();
        let repo = basic(&f);
        let mut env = GitEnv::new(hanging_git(&f), &f.support).unwrap();
        env.timeout = Duration::from_millis(300);
        let runner = Runner {
            env,
            git_dir: repo.join(".git"),
            work_tree: repo.clone(),
            ceiling: f.root.clone(),
        };
        let mut batch = runner.batch().unwrap();
        let started = Instant::now();
        let oid = git_in(&repo, &["rev-parse", "HEAD:a.txt"]);
        let err = batch.blob(&oid, 1024).unwrap_err();
        assert_eq!(err.code, ErrorCode::NotAvailable);
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn a_normal_run_is_well_inside_the_default_limit() {
        assert!(DEFAULT_TIMEOUT >= Duration::from_secs(10));
    }

    // -- untracked files

    #[test]
    fn untracked_files_that_are_not_ignored_show_as_added() {
        let f = fx();
        let repo = basic(&f);
        write(&repo.join(".gitignore"), "*.log\nbuild/\n");
        git_in(&repo, &["add", ".gitignore"]);
        git_in(&repo, &["commit", "-q", "-m", "ignore"]);
        write(&repo.join("new.txt"), "brand new\n");
        write(&repo.join("sub/deep/also.txt"), "deep\n");
        write(&repo.join("debug.log"), "ignored\n");
        write(&repo.join("build/out.bin"), "ignored\n");
        // A nested repository is not entered.
        let nested = repo.join("vendor");
        init(&nested);
        write(&nested.join("inner.txt"), "inner\n");
        let g = open_at(&f, &repo).unwrap();
        let d = g.diff(&DiffRequest::default()).unwrap();
        let mut paths: Vec<_> = d.files.iter().map(|x| x.path.as_str()).collect();
        paths.sort();
        assert_eq!(paths, vec!["new.txt", "sub/deep/also.txt"]);
        assert!(d.files.iter().all(|x| x.status == DiffStatus::Added));
        assert_eq!(d.files[0].hunks[0].lines[0].text, "brand new");
        let st = g.status().unwrap();
        assert_eq!(st.len(), 2);
        // A path filter applies to them too.
        let only = g
            .diff(&DiffRequest {
                path: Some("sub".into()),
                ..Default::default()
            })
            .unwrap();
        assert_eq!(only.files.len(), 1);
        // Comparing two commits does not look at the work tree.
        let c = g
            .diff(&DiffRequest {
                base: Some("HEAD".into()),
                head: Some("HEAD".into()),
                ..Default::default()
            })
            .unwrap();
        assert!(c.files.is_empty());
    }

    #[test]
    fn untracked_protected_files_and_big_files_are_handled_like_tracked_ones() {
        let f = fx();
        let home = f.root.join("home");
        init(&home);
        write(&home.join("ok.txt"), "ok\n");
        commit_all(&home, "c");
        write(&home.join(".ssh/id_rsa"), "UNTRACKED-SECRET\n");
        write(&home.join(".aws/credentials"), "UNTRACKED-AWS\n");
        write(&home.join("fresh.txt"), "fresh\n");
        write(&home.join("big.txt"), &"x\n".repeat(1_100_000));
        let d = open_at(&f, &home)
            .unwrap()
            .diff(&DiffRequest::default())
            .unwrap();
        let json = serde_json::to_string(&d).unwrap();
        assert!(
            !json.contains(".ssh") && !json.contains(".aws") && !json.contains("UNTRACKED"),
            "{json}"
        );
        let by: BTreeMap<_, _> = d.files.iter().map(|x| (x.path.as_str(), x)).collect();
        assert_eq!(by["fresh.txt"].status, DiffStatus::Added);
        assert!(by["big.txt"].too_large);
    }

    #[cfg(unix)]
    #[test]
    fn an_untracked_symlink_is_listed_by_its_text_and_never_followed() {
        let f = fx();
        let repo = basic(&f);
        let out = outside_dir(&f);
        std::os::unix::fs::symlink(out.join("sentinel.txt"), repo.join("link")).unwrap();
        std::os::unix::fs::symlink(&out, repo.join("dirlink")).unwrap();
        let d = open_at(&f, &repo)
            .unwrap()
            .diff(&DiffRequest::default())
            .unwrap();
        let json = serde_json::to_string(&d).unwrap();
        assert!(!json.contains("OUTSIDE-SECRET"), "{json}");
        let by: BTreeMap<_, _> = d.files.iter().map(|x| (x.path.as_str(), x)).collect();
        assert_eq!(by["link"].new_mode.as_deref(), Some("120000"));
        assert_eq!(by["dirlink"].new_mode.as_deref(), Some("120000"));
    }

    // -- the denylist inside history

    fn home_repo(f: &Fx) -> (PathBuf, String) {
        let home = f.root.join("home");
        init(&home);
        write(&home.join("notes.txt"), "notes\n");
        write(&home.join(".ssh/id_rsa"), "SECRET-KEY-MATERIAL\n");
        write(&home.join(".ssh/config"), "Host x\n");
        write(&home.join(".aws/credentials"), "AWS-SECRET-VALUE\n");
        let first = commit_all(&home, "with secrets");
        git_in(&home, &["rm", "-q", "-r", ".ssh"]);
        git_in(&home, &["mv", ".aws/credentials", "cred-old.txt"]);
        commit_all(&home, "remove and rename");
        (home, first)
    }

    #[test]
    fn a_protected_path_that_exists_only_in_history_is_invisible_everywhere() {
        let f = fx();
        let (home, first) = home_repo(&f);
        let g = open_at(&f, &home).unwrap();

        let top = g.ls_tree(&first, "").unwrap();
        let names: Vec<_> = top.iter().map(|e| e.path.as_str()).collect();
        assert!(names.contains(&"notes.txt"));
        assert!(
            !names.contains(&".ssh") && !names.contains(&".aws"),
            "{names:?}"
        );
        assert_eq!(code(g.ls_tree(&first, ".ssh")), ErrorCode::DeniedPath);
        assert_eq!(
            code(g.show(&first, Some(".ssh/id_rsa"))),
            ErrorCode::DeniedPath
        );
        assert_eq!(
            code(g.show(&first, Some(".aws/credentials"))),
            ErrorCode::DeniedPath
        );
        assert_eq!(
            code(g.show("HEAD", Some(".ssh/id_rsa"))),
            ErrorCode::DeniedPath,
            "denied before it is looked up"
        );
        assert_eq!(
            code(g.log(&LogRequest {
                path: Some(".ssh/id_rsa".into()),
                ..Default::default()
            })),
            ErrorCode::DeniedPath
        );

        // The whole history compared with today: no protected name, no content.
        let d = g
            .diff(&DiffRequest {
                base: Some(first.clone()),
                ..Default::default()
            })
            .unwrap();
        let json = serde_json::to_string(&d).unwrap();
        for needle in [".ssh", ".aws", "SECRET-KEY-MATERIAL", "id_rsa"] {
            assert!(!json.contains(needle), "{needle} leaked: {json}");
        }
        // The rename's new path shows as a plain addition: its protected old path is not named.
        let moved = d
            .files
            .iter()
            .find(|x| x.path == "cred-old.txt")
            .expect("the new path is not protected");
        assert_eq!(moved.status, DiffStatus::Added);
        assert!(moved.old_path.is_none());
        let st = serde_json::to_string(&g.status().unwrap()).unwrap();
        assert!(!st.contains(".ssh") && !st.contains(".aws"));
    }

    #[test]
    fn a_protected_file_that_is_tracked_and_changed_today_is_left_out_of_diff_and_status() {
        let f = fx();
        let home = f.root.join("home");
        init(&home);
        write(&home.join(".ssh/config"), "Host a\n");
        write(&home.join("ok.txt"), "ok\n");
        commit_all(&home, "c");
        write(&home.join(".ssh/config"), "Host b-SECRET\n");
        write(&home.join("ok.txt"), "changed\n");
        let g = open_at(&f, &home).unwrap();
        let d = g.diff(&DiffRequest::default()).unwrap();
        assert_eq!(
            d.files.iter().map(|x| x.path.as_str()).collect::<Vec<_>>(),
            vec!["ok.txt"]
        );
        assert!(!serde_json::to_string(&d).unwrap().contains("SECRET"));
        assert_eq!(g.status().unwrap().len(), 1);
        assert_eq!(
            code(g.diff(&DiffRequest {
                path: Some(".ssh/config".into()),
                ..Default::default()
            })),
            ErrorCode::DeniedPath
        );
    }

    // -- worktree reads stay inside the folder

    #[cfg(unix)]
    #[test]
    fn a_worktree_folder_replaced_by_a_link_out_is_not_read() {
        let f = fx();
        let repo = basic(&f);
        let out = outside_dir(&f);
        // dir/b.txt is tracked; now "dir" leads to a folder holding a file of the same name.
        write(&out.join("b.txt"), "OUTSIDE-SECRET-CONTENT");
        fs::remove_dir_all(repo.join("dir")).unwrap();
        std::os::unix::fs::symlink(&out, repo.join("dir")).unwrap();
        let g = open_at(&f, &repo).unwrap();
        let err = g.diff(&DiffRequest::default()).unwrap_err();
        assert_eq!(err.code, ErrorCode::OutsideRoot);
        assert!(!err.message.contains("OUTSIDE-SECRET"));
    }

    #[cfg(unix)]
    #[test]
    fn a_worktree_symlink_is_compared_by_its_target_text_and_never_followed() {
        let f = fx();
        let repo = basic(&f);
        let out = outside_dir(&f);
        std::os::unix::fs::symlink(out.join("sentinel.txt"), repo.join("link")).unwrap();
        git_in(&repo, &["add", "link"]);
        let d = open_at(&f, &repo)
            .unwrap()
            .diff(&DiffRequest::default())
            .unwrap();
        let link = d.files.iter().find(|x| x.path == "link").unwrap();
        assert_eq!(link.status, DiffStatus::Added);
        assert_eq!(link.new_mode.as_deref(), Some("120000"));
        let json = serde_json::to_string(&d).unwrap();
        assert!(
            !json.contains("OUTSIDE-SECRET"),
            "the target's content must not be read"
        );
        assert!(
            json.contains("sentinel.txt"),
            "the link text itself is the content, as in git"
        );
    }

    #[cfg(unix)]
    #[test]
    fn a_worktree_link_into_a_protected_place_is_hidden() {
        let f = fx();
        let home = f.root.join("home");
        init(&home);
        write(&home.join(".ssh/id_rsa"), "KEY\n");
        write(&home.join("proj/a.txt"), "a\n");
        commit_all(&home, "c");
        std::os::unix::fs::symlink(home.join(".ssh/id_rsa"), home.join("proj/key")).unwrap();
        git_in(&home, &["add", "-f", "proj/key"]);
        let d = open_at(&f, &home)
            .unwrap()
            .diff(&DiffRequest::default())
            .unwrap();
        assert!(
            d.files.iter().all(|x| x.path != "proj/key"),
            "judged by where it leads: {d:?}"
        );
    }

    // -- config scanner details

    #[test]
    fn config_values_are_cleaned_like_git_cleans_them() {
        assert_eq!(clean_value(" \"/a b/c\" "), "/a b/c");
        assert_eq!(clean_value("x # comment"), "x");
        assert_eq!(clean_value("x;y"), "x;y");
        assert_eq!(clean_value("\"a # b\""), "a # b");
    }
}
