//! The broker: what an add-on may ask the app for (design 4.3).
//!
//! Order of checks, always: pane instance and generation current → declared →
//! granted → path checks → the op. The pane identity comes from the port the
//! request arrived on (see `panes`), never from `args`. Paths are relative to
//! the one folder the user allowed; they are resolved to real paths and must
//! stay under that folder (symlinks, junctions, `\\?\`, 8.3 names and case are
//! all handled by resolving, not by comparing text), and the denylist is applied
//! to the *real* path. Results are plain JSON.

use serde_json::{json, Value};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use std::sync::{Arc, OnceLock};

use super::denylist::Denylist;
use super::git::{self, DiffRequest, GitBroker, GitEnv, GitError, LogRequest};
use super::panes::{Authorized, BrokerError, Need, Registry};

pub const MAX_LIST: usize = 5000;
pub const MAX_READ: u64 = 10 * 1024 * 1024;

type Res = Result<Value, BrokerError>;

/// Which permissions an op needs. `None` for an op this broker does not know.
pub fn need_for(op: &str) -> Option<Need> {
    match op {
        "open.args" => Some(Need::Current),
        "fs.stat" | "fs.list" | "fs.read" => Some(Need::Files),
        "git.status" | "git.log" | "git.diff" | "git.show" => Some(Need::FilesAndGit),
        _ => None,
    }
}

/// Runs one request. `reg` is locked only while authorizing and while checking
/// again before the answer is returned; the op itself runs unlocked.
pub fn handle(reg: &std::sync::Mutex<Registry>, deny: &Denylist, id: u64, generation: u64, op: &str, args: &Value) -> Res {
    // The git side is only measured when an op needs it, so a pane that never asks
    // for git never starts a git process.
    let lazy: &dyn Fn() -> &'static GitSupport = &git_support;
    handle_with_git(reg, deny, lazy, id, generation, op, args)
}

/// `handle`, with the git side supplied (tests pass their own).
pub fn handle_with_git(
    reg: &std::sync::Mutex<Registry>,
    deny: &Denylist,
    git: &dyn Fn() -> &'static GitSupport,
    id: u64,
    generation: u64,
    op: &str,
    args: &Value,
) -> Res {
    let need = need_for(op).ok_or_else(|| BrokerError::new("bad_args", format!("unknown op `{op}`")))?;
    let (auth, _slot) = {
        let r = reg.lock().unwrap();
        let auth = r.authorize(id, generation, need)?;
        let slot = r.slot(id).ok_or_else(|| BrokerError::new("not_available", "too many requests are waiting"))?;
        (auth, slot)
    };
    let out = run(&auth, deny, git, op, args);
    // Re-check just before the answer leaves: if the pane was reloaded, closed
    // or revoked meanwhile, the answer is dropped, not delivered late.
    reg.lock().unwrap().authorize(id, generation, need)?;
    out
}

fn run(a: &Authorized, deny: &Denylist, git: &dyn Fn() -> &'static GitSupport, op: &str, args: &Value) -> Res {
    match op {
        "open.args" => Ok(serde_json::to_value(&a.open_args).unwrap_or(json!({}))),
        "fs.stat" => {
            let (real, _rel) = resolve(a, deny, args)?;
            let md = fs::metadata(&real).map_err(io_err)?;
            Ok(entry_json(&real, &md)?)
        }
        "fs.list" => fs_list(a, deny, args),
        "fs.read" => fs_read(a, deny, args),
        "git.status" | "git.log" | "git.diff" | "git.show" => git_op(git(), a, deny, op, args),
        _ => Err(BrokerError::new("bad_args", "unknown op")),
    }
}

fn arg_path(args: &Value) -> Result<String, BrokerError> {
    match args.get("path") {
        None => Ok(".".to_string()),
        Some(Value::String(s)) => Ok(s.clone()),
        Some(_) => Err(BrokerError::new("bad_args", "`path` must be a string")),
    }
}

/// A relative path: `.` or plain segments. No absolute path, drive, UNC, `..`,
/// backslash, NUL or control character; nothing the OS could read as another place.
pub fn check_relative(rel: &str) -> Result<(), BrokerError> {
    let bad = |m: &str| Err(BrokerError::new("bad_args", m.to_string()));
    if rel.len() > 4096 {
        return bad("path is too long");
    }
    if rel == "." {
        return Ok(());
    }
    if rel.is_empty() || rel.starts_with('/') || rel.contains('\\') {
        return bad("path must be relative, with `/` separators");
    }
    for seg in rel.split('/') {
        if seg.is_empty() || seg == "." || seg == ".." {
            return bad("path must not contain empty, `.` or `..` segments");
        }
        if seg.chars().any(|c| c.is_control() || c == ':') {
            return bad("path has a character that is not allowed");
        }
        if seg.ends_with('.') || seg.ends_with(' ') {
            return bad("path segments must not end in a dot or a space");
        }
    }
    Ok(())
}

/// Real path of `args.path` under the granted root. Fails with `outside_root`
/// when the real path leaves the root and `denied_path` for the denylist.
fn resolve(a: &Authorized, deny: &Denylist, args: &Value) -> Result<(PathBuf, String), BrokerError> {
    let rel = arg_path(args)?;
    check_relative(&rel)?;
    let root = a.root.as_ref().ok_or_else(|| BrokerError::new("not_granted", "no folder is allowed for this pane"))?;
    let root_real = fs::canonicalize(root).map_err(|_| BrokerError::new("not_found", "the allowed folder no longer exists"))?;
    // The root itself may have been made denied since it was granted.
    if deny.is_denied(&root_real) {
        return Err(BrokerError::new("denied_path", super::denylist::refusal_message(&root_real)));
    }
    let joined = if rel == "." { root_real.clone() } else { root_real.join(&rel) };
    let real = fs::canonicalize(&joined).map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => BrokerError::new("not_found", "not found"),
        _ => BrokerError::new("not_found", "cannot be read"),
    })?;
    if !real.starts_with(&root_real) {
        return Err(BrokerError::new("outside_root", "that path leads outside the allowed folder"));
    }
    if deny.is_denied(&real) {
        return Err(BrokerError::new("denied_path", super::denylist::refusal_message(&real)));
    }
    Ok((real, rel))
}

fn io_err(e: std::io::Error) -> BrokerError {
    match e.kind() {
        std::io::ErrorKind::NotFound => BrokerError::new("not_found", "not found"),
        _ => BrokerError::new("not_found", "cannot be read"),
    }
}

fn mtime_iso(md: &fs::Metadata) -> String {
    let secs = md.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
    iso8601(secs)
}

/// Seconds since the epoch → `YYYY-MM-DDTHH:MM:SSZ` (UTC), no dependency.
pub fn iso8601(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // civil-from-days (Howard Hinnant)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, (rem % 3600) / 60, rem % 60)
}

fn kind_of(md: &fs::Metadata) -> Result<&'static str, BrokerError> {
    if md.is_dir() {
        Ok("dir")
    } else if md.is_file() {
        Ok("file")
    } else {
        // devices, sockets, pipes
        Err(BrokerError::new("bad_args", "not a regular file or folder"))
    }
}

fn entry_json(real: &Path, md: &fs::Metadata) -> Res {
    let name = real.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    Ok(json!({ "name": name, "kind": kind_of(md)?, "size": if md.is_file() { md.len() } else { 0 }, "mtime": mtime_iso(md) }))
}

fn fs_list(a: &Authorized, deny: &Denylist, args: &Value) -> Res {
    let (real, _) = resolve(a, deny, args)?;
    let md = fs::metadata(&real).map_err(io_err)?;
    if !md.is_dir() {
        return Err(BrokerError::new("bad_args", "not a folder"));
    }
    // one snapshot of the denylist for the whole listing (taking one per entry re-resolves every entry)
    let snap = deny.snapshot();
    let names: Vec<std::ffi::OsString> = fs::read_dir(&real).map_err(io_err)?.flatten().map(|e| e.file_name()).collect();
    let mut names = snap.filter_children(&real, names);
    names.sort();
    let root_real = a.root.as_ref().and_then(|r| fs::canonicalize(r).ok());
    let mut entries = Vec::new();
    let mut truncated = false;
    for n in names {
        if entries.len() >= MAX_LIST {
            truncated = true;
            break;
        }
        let child = real.join(&n);
        // an entry whose real path leaves the root (a symlink out) is not listed
        let Ok(child_real) = fs::canonicalize(&child) else { continue };
        if let Some(rr) = &root_real {
            if !child_real.starts_with(rr) {
                continue;
            }
        }
        if snap.is_denied(&child_real) {
            continue;
        }
        let Ok(cmd) = fs::metadata(&child_real) else { continue };
        let Ok(kind) = kind_of(&cmd) else { continue };
        entries.push(json!({ "name": n.to_string_lossy(), "kind": kind, "size": if cmd.is_file() { cmd.len() } else { 0 }, "mtime": mtime_iso(&cmd) }));
    }
    Ok(json!({ "entries": entries, "truncated": truncated }))
}

fn fs_read(a: &Authorized, deny: &Denylist, args: &Value) -> Res {
    let (real, _) = resolve(a, deny, args)?;
    let md = fs::metadata(&real).map_err(io_err)?;
    if !md.is_file() {
        return Err(BrokerError::new("bad_args", "not a file"));
    }
    let size = md.len();
    let (offset, length) = match args.get("range") {
        None | Some(Value::Null) => {
            if size > MAX_READ {
                return Err(BrokerError::new("too_large", format!("the file is {size} bytes; read it in ranges of at most {MAX_READ} bytes")));
            }
            (0, size)
        }
        Some(r) => {
            let offset = r.get("offset").and_then(Value::as_u64).ok_or_else(|| BrokerError::new("bad_args", "range.offset must be a non-negative integer"))?;
            let length = r.get("length").and_then(Value::as_u64).ok_or_else(|| BrokerError::new("bad_args", "range.length must be a non-negative integer"))?;
            if length > MAX_READ {
                return Err(BrokerError::new("too_large", format!("one call reads at most {MAX_READ} bytes")));
            }
            (offset, length)
        }
    };
    let mut f = fs::File::open(&real).map_err(io_err)?;
    f.seek(SeekFrom::Start(offset.min(size))).map_err(io_err)?;
    let mut buf = Vec::new();
    f.take(length).read_to_end(&mut buf).map_err(io_err)?;
    let eof = offset.saturating_add(buf.len() as u64) >= size;
    Ok(text_or_bytes(&buf, size, eof))
}

/// Text when the bytes are valid UTF-8 without a NUL, base64 bytes otherwise
/// (the window side turns `bytesBase64` into an ArrayBuffer).
fn text_or_bytes(buf: &[u8], size: u64, eof: bool) -> Value {
    if !buf.contains(&0) {
        if let Ok(t) = std::str::from_utf8(buf) {
            return json!({ "text": t, "size": size, "eof": eof });
        }
    }
    use base64::Engine;
    json!({ "bytesBase64": base64::engine::general_purpose::STANDARD.encode(buf), "size": size, "eof": eof })
}

// ---- git ----------------------------------------------------------------------

/// Whether `git:read` can be offered on this computer. Measured once: a usable git
/// that honours `GIT_NO_LAZY_FETCH`. When it is off, every git op answers
/// `not_available` with the reason.
pub enum GitSupport {
    Ready(GitEnv),
    Off(String),
}

static GIT: OnceLock<GitSupport> = OnceLock::new();

pub fn git_support() -> &'static GitSupport {
    GIT.get_or_init(|| {
        let support = crate::agmsg::base_dir().join("addons").join(".git-support");
        measure_git(find_git(), &support)
    })
}

/// Runs the measurement now (at startup, off the UI thread) so the first git op
/// does not pay for it. Returns the reason when git:read is off.
pub fn prepare_git() -> Option<String> {
    match git_support() {
        GitSupport::Ready(_) => None,
        GitSupport::Off(why) => Some(why.clone()),
    }
}

pub fn measure_git(git: Result<PathBuf, String>, support_dir: &Path) -> GitSupport {
    let git = match git {
        Ok(g) => g,
        Err(why) => return GitSupport::Off(why),
    };
    if let Err(e) = fs::create_dir_all(support_dir) {
        return GitSupport::Off(format!("cannot prepare {}: {e}", support_dir.display()));
    }
    let env = match GitEnv::new(&git, support_dir) {
        Ok(e) => e,
        Err(e) => return GitSupport::Off(format!("cannot prepare {}: {e}", support_dir.display())),
    };
    match git::probe_no_lazy_fetch(&env, support_dir) {
        Ok(()) => GitSupport::Ready(env),
        Err(e) => GitSupport::Off(e.message),
    }
}

/// The git to use: the first `git` on the login-shell PATH the app imported (or the
/// process PATH). On macOS the system `git` is a stub that offers to install the
/// command line tools, so it is used only when those are installed.
pub fn find_git() -> Result<PathBuf, String> {
    let path = crate::imported_path().map(std::ffi::OsString::from).or_else(|| std::env::var_os("PATH")).unwrap_or_default();
    let exe = if cfg!(windows) { "git.exe" } else { "git" };
    for dir in std::env::split_paths(&path) {
        let cand = dir.join(exe);
        if cand.is_file() {
            if cfg!(target_os = "macos") && cand == Path::new("/usr/bin/git") && !command_line_tools_installed() {
                continue;
            }
            return Ok(cand);
        }
    }
    Err("git was not found on this computer".to_string())
}

fn command_line_tools_installed() -> bool {
    std::process::Command::new("/usr/bin/xcode-select")
        .arg("-p")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn git_err(e: GitError) -> BrokerError {
    BrokerError::new(e.code.as_str(), e.message)
}

fn from_args<T: serde::de::DeserializeOwned>(args: &Value) -> Result<T, BrokerError> {
    serde_json::from_value(args.clone()).map_err(|e| BrokerError::new("bad_args", e.to_string()))
}

/// One git op. The repository is the granted folder itself; its layout is checked
/// again on every request (the folder can change between requests), then git runs
/// only through `GitBroker`.
fn git_op(support: &GitSupport, a: &Authorized, deny: &Denylist, op: &str, args: &Value) -> Res {
    let env = match support {
        GitSupport::Ready(e) => e,
        GitSupport::Off(why) => return Err(BrokerError::new("not_available", format!("git:read is off on this computer: {why}"))),
    };
    let root = a.root.as_ref().ok_or_else(|| BrokerError::new("not_granted", "no folder is allowed for this pane"))?;
    let root_real = fs::canonicalize(root).map_err(|_| BrokerError::new("not_found", "the allowed folder no longer exists"))?;
    if deny.is_denied(&root_real) {
        return Err(BrokerError::new("denied_path", super::denylist::refusal_message(&root_real)));
    }
    let g = GitBroker::open(env, &root_real, Arc::new(deny.clone())).map_err(git_err)?;
    match op {
        "git.status" => Ok(json!({ "files": g.status().map_err(git_err)? })),
        "git.log" => {
            let req: LogRequest = from_args(args)?;
            Ok(json!({ "commits": g.log(&req).map_err(git_err)? }))
        }
        "git.diff" => {
            let req: DiffRequest = from_args(args)?;
            let r = g.diff(&req).map_err(git_err)?;
            serde_json::to_value(r).map_err(|e| BrokerError::new("not_available", e.to_string()))
        }
        "git.show" => {
            let rev = args.get("rev").and_then(Value::as_str).ok_or_else(|| BrokerError::new("bad_args", "`rev` must be a string"))?;
            let path = args.get("path").and_then(Value::as_str);
            let r = g.show(rev, path).map_err(git_err)?;
            Ok(text_or_bytes(&r.bytes, r.size, true))
        }
        _ => Err(BrokerError::new("bad_args", "unknown op")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::addons::panes::{AddPane, Declared, OpenArgs};
    use crate::addons::server::Payload;
    use std::collections::HashMap;
    use std::sync::Mutex;

    struct Fx {
        _tmp: tempfile::TempDir,
        root: PathBuf,
        outside: PathBuf,
        protected: PathBuf,
        reg: Mutex<Registry>,
        id: u64,
        gen: u64,
        deny: Denylist,
    }

    fn fx(declared: Declared) -> Fx {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path().canonicalize().unwrap();
        let root = base.join("proj");
        let outside = base.join("outside");
        let protected = base.join("proj/secret-keys");
        fs::create_dir_all(root.join("src")).unwrap();
        fs::create_dir_all(&outside).unwrap();
        fs::create_dir_all(&protected).unwrap();
        fs::write(root.join("README.md"), "# hi\n").unwrap();
        fs::write(root.join("src/main.rs"), "fn main() {}\n").unwrap();
        fs::write(root.join("blob.bin"), [0u8, 1, 2, 255, 254]).unwrap();
        fs::write(outside.join("secret.txt"), "OUTSIDE-SECRET").unwrap();
        fs::write(protected.join("id"), "KEY").unwrap();
        let deny = Denylist::from_process_env(vec![protected.clone()]);
        let mut reg = Registry::new();
        let mut files = HashMap::new();
        files.insert("index.html".to_string(), b"x".to_vec());
        let id = reg
            .add(AddPane { addon: "o/r".into(), commit: "c".into(), name: "n".into(), payload: Payload::Embedded(files), entry: "index.html".into(), declared, open_args: OpenArgs { path: Some(root.to_string_lossy().into_owned()), ..Default::default() }, expected_digest: None, pinned: None, on_tamper: None })
            .unwrap()
            .id;
        let gen = reg.begin_generation(id).unwrap();
        reg.grant_root(id, root.clone()).ok();
        Fx { _tmp: tmp, root, outside, protected, reg: Mutex::new(reg), id, gen, deny }
    }

    fn files_only() -> Declared {
        Declared { files_read: true, ..Default::default() }
    }

    fn call(f: &Fx, op: &str, args: Value) -> Res {
        handle(&f.reg, &f.deny, f.id, f.gen, op, &args)
    }

    fn code(r: Res) -> &'static str {
        r.unwrap_err().code
    }

    #[test]
    fn open_args_needs_no_permission() {
        let f = fx(Declared::default());
        let v = call(&f, "open.args", json!({})).unwrap();
        assert_eq!(v["path"], f.root.to_string_lossy().as_ref());
        assert!(v.get("url").is_none());
    }

    #[test]
    fn undeclared_beats_everything_and_unknown_ops_are_bad_args() {
        let f = fx(Declared::default());
        for op in ["fs.stat", "fs.list", "fs.read"] {
            assert_eq!(code(call(&f, op, json!({"path": "../../etc/hosts"}))), "not_declared", "{op}: declared is checked before the path");
        }
        assert_eq!(code(call(&f, "git.status", json!({}))), "not_declared");
        assert_eq!(code(call(&f, "nope", json!({}))), "bad_args");
        assert_eq!(code(call(&f, "", json!({}))), "bad_args");
    }

    fn ready_git(f: &Fx) -> &'static GitSupport {
        let support = f._tmp.path().join("support");
        fs::create_dir_all(&support).unwrap();
        Box::leak(Box::new(GitSupport::Ready(GitEnv::new("git", &support).unwrap())))
    }

    fn git_call(f: &Fx, g: &'static GitSupport, op: &str, args: Value) -> Res {
        let lazy = move || g;
        handle_with_git(&f.reg, &f.deny, &lazy, f.id, f.gen, op, &args)
    }

    fn sh_git(dir: &Path, args: &[&str]) {
        let out = std::process::Command::new("git")
            .current_dir(dir)
            .env_clear()
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .args(["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"])
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
    }

    #[test]
    fn git_ops_stay_gated_and_answer_for_a_folder_that_is_not_a_repository() {
        let f = fx(Declared { files_read: true, git_read: true, ..Default::default() });
        assert_eq!(code(call(&f, "git.status", json!({}))), "unsupported_repo", "proj has no .git");
        let g = fx(files_only());
        assert_eq!(code(call(&g, "git.log", json!({}))), "not_declared");
    }

    #[test]
    fn git_is_off_with_its_reason_when_it_was_not_measured_ok() {
        let f = fx(Declared { files_read: true, git_read: true, ..Default::default() });
        let off: &'static GitSupport = Box::leak(Box::new(GitSupport::Off("this git starts a transport helper".into())));
        for op in ["git.status", "git.log", "git.diff", "git.show"] {
            let e = git_call(&f, off, op, json!({"rev": "HEAD", "path": "a"})).unwrap_err();
            assert_eq!(e.code, "not_available", "{op}");
            assert!(e.message.contains("git:read is off") && e.message.contains("transport helper"), "{}", e.message);
        }
    }

    #[test]
    fn git_status_log_diff_and_show_over_the_broker() {
        let f = fx(Declared { files_read: true, git_read: true, ..Default::default() });
        let g = ready_git(&f);
        sh_git(&f.root, &["init", "-q", "-b", "main"]);
        sh_git(&f.root, &["add", "README.md", "src"]);
        sh_git(&f.root, &["commit", "-q", "-m", "first"]);
        fs::write(f.root.join("README.md"), "# changed\n").unwrap();
        fs::write(f.root.join("new.txt"), "new\n").unwrap();

        let st = git_call(&f, g, "git.status", json!({})).unwrap();
        let files: Vec<(&str, &str)> = st["files"].as_array().unwrap().iter().map(|e| (e["path"].as_str().unwrap(), e["status"].as_str().unwrap())).collect();
        assert!(files.contains(&("README.md", "modified")) && files.contains(&("new.txt", "added")), "{files:?}");

        let d = git_call(&f, g, "git.diff", json!({})).unwrap();
        assert_eq!(d["base"]["rev"], "HEAD");
        assert_eq!(d["head"]["worktree"], true);
        let readme = d["files"].as_array().unwrap().iter().find(|e| e["path"] == "README.md").unwrap();
        assert_eq!(readme["hunks"][0]["lines"][0]["type"], "del");
        assert_eq!(readme["hunks"][0]["lines"][0]["oldNo"], 1);
        let ctx = git_call(&f, g, "git.diff", json!({"context": "all", "path": "README.md"})).unwrap();
        assert_eq!(ctx["files"].as_array().unwrap().len(), 1);
        assert_eq!(code_of(git_call(&f, g, "git.diff", json!({"context": "lots"}))), "bad_args");
        assert_eq!(code_of(git_call(&f, g, "git.diff", json!({"base": "--output=/tmp/x"}))), "bad_args");

        let log = git_call(&f, g, "git.log", json!({})).unwrap();
        assert_eq!(log["commits"][0]["subject"], "first");
        assert_eq!(log["commits"].as_array().unwrap().len(), 1);

        let shown = git_call(&f, g, "git.show", json!({"rev": "HEAD", "path": "README.md"})).unwrap();
        assert_eq!(shown["text"], "# hi\n");
        assert_eq!(shown["eof"], true);
        assert_eq!(code_of(git_call(&f, g, "git.show", json!({"rev": "HEAD"}))), "bad_args", "a path is required");
        assert_eq!(code_of(git_call(&f, g, "git.show", json!({"path": "README.md"}))), "bad_args");
        assert_eq!(code_of(git_call(&f, g, "git.show", json!({"rev": "HEAD", "path": "missing"}))), "not_found");
        // binary content comes back as bytes
        sh_git(&f.root, &["add", "blob.bin"]);
        sh_git(&f.root, &["commit", "-q", "-m", "bin"]);
        let bin = git_call(&f, g, "git.show", json!({"rev": "HEAD", "path": "blob.bin"})).unwrap();
        assert!(bin.get("text").is_none() && bin["bytesBase64"].is_string());
    }

    fn code_of(r: Res) -> &'static str {
        r.unwrap_err().code
    }

    #[test]
    fn git_measurement_reports_a_missing_git_and_passes_on_a_good_one() {
        let tmp = tempfile::tempdir().unwrap();
        match measure_git(Err("git was not found on this computer".into()), tmp.path()) {
            GitSupport::Off(why) => assert!(why.contains("not found")),
            _ => panic!("expected off"),
        }
        #[cfg(unix)]
        match measure_git(find_git(), tmp.path()) {
            GitSupport::Ready(_) => {}
            GitSupport::Off(why) => panic!("git is expected on a development machine: {why}"),
        }
    }

    #[test]
    fn list_stat_and_read_inside_the_root() {
        let f = fx(files_only());
        let l = call(&f, "fs.list", json!({"path": "."})).unwrap();
        let names: Vec<_> = l["entries"].as_array().unwrap().iter().map(|e| e["name"].as_str().unwrap().to_string()).collect();
        assert_eq!(names, vec!["README.md", "blob.bin", "src"], "the protected folder is not listed");
        assert_eq!(l["truncated"], false);
        let src = call(&f, "fs.list", json!({"path": "src"})).unwrap();
        assert_eq!(src["entries"][0]["name"], "main.rs");
        assert_eq!(src["entries"][0]["kind"], "file");
        let st = call(&f, "fs.stat", json!({"path": "README.md"})).unwrap();
        assert_eq!((st["kind"].as_str().unwrap(), st["size"].as_u64().unwrap()), ("file", 5));
        assert!(st["mtime"].as_str().unwrap().ends_with('Z'));
        let rd = call(&f, "fs.read", json!({"path": "README.md"})).unwrap();
        assert_eq!((rd["text"].as_str().unwrap(), rd["size"].as_u64().unwrap(), rd["eof"].as_bool().unwrap()), ("# hi\n", 5, true));
        let bin = call(&f, "fs.read", json!({"path": "blob.bin"})).unwrap();
        assert!(bin.get("text").is_none());
        assert_eq!(bin["bytesBase64"], "AAEC//4=");
        assert_eq!(call(&f, "fs.stat", json!({})).unwrap()["kind"], call(&f, "fs.stat", json!({"path": "."})).unwrap()["kind"]);
    }

    #[test]
    fn read_ranges_and_caps() {
        let f = fx(files_only());
        let r = call(&f, "fs.read", json!({"path": "README.md", "range": {"offset": 2, "length": 2}})).unwrap();
        assert_eq!((r["text"].as_str().unwrap(), r["eof"].as_bool().unwrap()), ("hi", false));
        let r = call(&f, "fs.read", json!({"path": "README.md", "range": {"offset": 99, "length": 5}})).unwrap();
        assert_eq!((r["text"].as_str().unwrap(), r["eof"].as_bool().unwrap()), ("", true));
        assert_eq!(code(call(&f, "fs.read", json!({"path": "README.md", "range": {"offset": 0, "length": MAX_READ + 1}}))), "too_large");
        assert_eq!(code(call(&f, "fs.read", json!({"path": "README.md", "range": {"offset": -1, "length": 1}}))), "bad_args");
        assert_eq!(code(call(&f, "fs.read", json!({"path": "README.md", "range": {"length": 1}}))), "bad_args");
        let big = f.root.join("big.bin");
        let fh = fs::File::create(&big).unwrap();
        fh.set_len(MAX_READ + 1).unwrap();
        assert_eq!(code(call(&f, "fs.read", json!({"path": "big.bin"}))), "too_large", "no range on a file over the cap");
        let ok = call(&f, "fs.read", json!({"path": "big.bin", "range": {"offset": 0, "length": 16}})).unwrap();
        assert_eq!(ok["size"].as_u64().unwrap(), MAX_READ + 1);
    }

    #[test]
    fn paths_that_are_not_plain_relative_names_are_bad_args() {
        let f = fx(files_only());
        for p in ["/etc/hosts", "../outside/secret.txt", "src/../README.md", "./README.md", "src//main.rs", "src\\main.rs", "C:/Windows", "C:\\Windows", "\\\\server\\share", "a\u{0}b", "a\nb", "src/", "name.", "name ", ""] {
            for op in ["fs.stat", "fs.list", "fs.read"] {
                let c = code(call(&f, op, json!({ "path": p })));
                assert_eq!(c, "bad_args", "{op} {p:?}");
            }
        }
        assert_eq!(code(call(&f, "fs.read", json!({"path": 7}))), "bad_args");
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_out_of_the_root_are_outside_root_and_not_listed() {
        let f = fx(files_only());
        std::os::unix::fs::symlink(f.outside.join("secret.txt"), f.root.join("link-file")).unwrap();
        std::os::unix::fs::symlink(&f.outside, f.root.join("link-dir")).unwrap();
        std::os::unix::fs::symlink(f.root.join("README.md"), f.root.join("link-inside")).unwrap();
        assert_eq!(code(call(&f, "fs.read", json!({"path": "link-file"}))), "outside_root");
        assert_eq!(code(call(&f, "fs.read", json!({"path": "link-dir/secret.txt"}))), "outside_root");
        assert_eq!(code(call(&f, "fs.list", json!({"path": "link-dir"}))), "outside_root");
        assert_eq!(code(call(&f, "fs.stat", json!({"path": "link-file"}))), "outside_root");
        let l = call(&f, "fs.list", json!({})).unwrap();
        let names: Vec<_> = l["entries"].as_array().unwrap().iter().map(|e| e["name"].as_str().unwrap().to_string()).collect();
        assert!(!names.contains(&"link-file".to_string()) && !names.contains(&"link-dir".to_string()), "{names:?}");
        assert!(names.contains(&"link-inside".to_string()), "a link that stays inside is fine");
        assert_eq!(call(&f, "fs.read", json!({"path": "link-inside"})).unwrap()["text"], "# hi\n");
    }

    #[cfg(unix)]
    #[test]
    fn a_link_into_the_denylist_is_denied_by_its_real_path() {
        let f = fx(files_only());
        // inside the root, pointing at a protected folder that is also inside the root
        std::os::unix::fs::symlink(&f.protected, f.root.join("innocent")).unwrap();
        assert_eq!(code(call(&f, "fs.list", json!({"path": "innocent"}))), "denied_path");
        assert_eq!(code(call(&f, "fs.read", json!({"path": "innocent/id"}))), "denied_path");
        assert_eq!(code(call(&f, "fs.read", json!({"path": "secret-keys/id"}))), "denied_path");
        assert_eq!(code(call(&f, "fs.stat", json!({"path": "secret-keys"}))), "denied_path");
    }

    #[test]
    fn a_granted_home_cannot_reach_the_agmsg_base_stores_or_addons() {
        // the agmsg home sits inside the folder the user granted (the usual layout:
        // the base is under the home folder); its stores, db, teams and add-on
        // state must stay unreadable, which is what keeps messages:read's one-team limit real
        let f = fx(files_only());
        let base = f.root.join(".agents/skills/agmsg");
        for d in ["db", "teams/t", "addons/o/r", "scripts"] {
            fs::create_dir_all(base.join(d)).unwrap();
        }
        fs::write(base.join("db/messages.db"), "SQLITE-SECRET").unwrap();
        fs::write(base.join("db/messages.db-wal"), "WAL-SECRET").unwrap();
        fs::write(base.join("teams/t/config"), "TEAM-SECRET").unwrap();
        fs::write(base.join("addons/grants.tsv"), "GRANTS-SECRET").unwrap();
        fs::write(base.join("addons/index.tsv"), "INDEX-SECRET").unwrap();
        let store = f.root.join("elsewhere/store.db");
        fs::create_dir_all(store.parent().unwrap()).unwrap();
        fs::write(&store, "STORE-SECRET").unwrap();
        let mut extra = vec![base.clone(), store.clone(), PathBuf::from(format!("{}-wal", store.display()))];
        extra.sort();
        let f = Fx { deny: Denylist::from_process_env(extra), ..f };
        for p in [".agents/skills/agmsg/db/messages.db", ".agents/skills/agmsg/db/messages.db-wal", ".agents/skills/agmsg/teams/t/config", ".agents/skills/agmsg/addons/grants.tsv", ".agents/skills/agmsg/addons/index.tsv", "elsewhere/store.db"] {
            let r = call(&f, "fs.read", json!({ "path": p }));
            assert_eq!(r.as_ref().unwrap_err().code, "denied_path", "{p}: {r:?}");
        }
        for d in [".agents/skills/agmsg", ".agents/skills/agmsg/db", ".agents/skills/agmsg/addons"] {
            assert_eq!(code(call(&f, "fs.list", json!({ "path": d }))), "denied_path", "{d}");
        }
        let top = call(&f, "fs.list", json!({})).unwrap();
        let names: Vec<_> = top["entries"].as_array().unwrap().iter().map(|e| e["name"].as_str().unwrap().to_string()).collect();
        assert!(names.contains(&"README.md".to_string()));
        let hidden = call(&f, "fs.list", json!({"path": ".agents/skills"}));
        assert!(hidden.is_ok() && hidden.unwrap()["entries"].as_array().unwrap().is_empty(), "the base is not even listed");
        assert_eq!(code(call(&f, "fs.stat", json!({"path": ".agents/skills/agmsg/db/messages.db"}))), "denied_path");
    }

    #[test]
    fn missing_paths_and_special_files() {
        let f = fx(files_only());
        assert_eq!(code(call(&f, "fs.read", json!({"path": "nope.txt"}))), "not_found");
        assert_eq!(code(call(&f, "fs.list", json!({"path": "nope"}))), "not_found");
        assert_eq!(code(call(&f, "fs.read", json!({"path": "src"}))), "bad_args");
        assert_eq!(code(call(&f, "fs.list", json!({"path": "README.md"}))), "bad_args");
    }

    #[test]
    fn the_root_removed_mid_session_is_not_found() {
        let f = fx(files_only());
        fs::remove_dir_all(&f.root).unwrap();
        assert_eq!(code(call(&f, "fs.list", json!({}))), "not_found");
    }

    #[test]
    fn a_root_that_became_denied_is_refused() {
        let mut f = fx(files_only());
        f.deny = Denylist::from_process_env(vec![f.root.clone()]);
        assert_eq!(code(call(&f, "fs.list", json!({}))), "denied_path");
    }

    #[test]
    fn stale_generation_and_revocation_drop_the_answer() {
        let f = fx(files_only());
        assert!(call(&f, "fs.list", json!({})).is_ok());
        let old = f.gen;
        f.reg.lock().unwrap().begin_generation(f.id);
        assert_eq!(handle(&f.reg, &f.deny, f.id, old, "fs.list", &json!({})).unwrap_err().code, "not_granted");
        let g2 = f.reg.lock().unwrap().generation(f.id).unwrap();
        assert!(handle(&f.reg, &f.deny, f.id, g2, "fs.list", &json!({})).is_ok());
        f.reg.lock().unwrap().revoke_root(f.id);
        let g3 = f.reg.lock().unwrap().generation(f.id).unwrap();
        assert_eq!(handle(&f.reg, &f.deny, f.id, g3, "fs.list", &json!({})).unwrap_err().code, "not_granted");
        assert_eq!(handle(&f.reg, &f.deny, 9999, 1, "fs.list", &json!({})).unwrap_err().code, "not_granted");
    }

    #[test]
    fn a_big_folder_is_cut_at_the_cap() {
        let f = fx(files_only());
        let d = f.root.join("many");
        fs::create_dir_all(&d).unwrap();
        for i in 0..(MAX_LIST + 3) {
            fs::write(d.join(format!("f{i:05}")), "").unwrap();
        }
        let l = call(&f, "fs.list", json!({"path": "many"})).unwrap();
        assert_eq!(l["entries"].as_array().unwrap().len(), MAX_LIST);
        assert_eq!(l["truncated"], true);
    }

    #[test]
    fn iso8601_known_values() {
        assert_eq!(iso8601(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601(951_782_400), "2000-02-29T00:00:00Z");
        assert_eq!(iso8601(1_792_657_018), "2026-10-22T08:16:58Z");
    }
}
