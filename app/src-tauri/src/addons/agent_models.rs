//! `agents.models`: the model choices an add-on can offer for a CLI type, with the reasoning efforts each model
//! takes. Codex's list is read from Codex itself (a short-lived `codex app-server` over stdio, one `model/list`);
//! Claude Code's is a fixed list of aliases. Nothing here writes anywhere or touches a running server: the process
//! is our own child, it has no port or socket, and it ends when its input closes.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// How long one read of the Codex list may take, start to finish, before the fixed list is used instead.
pub const FETCH_TIMEOUT: Duration = Duration::from_secs(10);
/// A failed read is not repeated for this long (a broken Codex must not start a process per request).
pub const FAILURE_BACKOFF: Duration = Duration::from_secs(60);
/// At most this many pages of the list are read (the server's default page holds the whole list today).
const MAX_PAGES: usize = 5;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Effort {
    pub id: String,
    pub description: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelOption {
    pub id: String,
    pub name: String,
    pub description: String,
    /// The CLI's own default model.
    pub is_default: bool,
    /// The effort used when none is chosen (absent for a list that does not say).
    pub default_effort: Option<String>,
    pub efforts: Vec<Effort>,
}

impl ModelOption {
    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "name": self.name,
            "description": self.description,
            "isDefault": self.is_default,
            "defaultEffort": self.default_effort,
            "efforts": self.efforts.iter().map(|e| json!({ "id": e.id, "description": e.description })).collect::<Vec<_>>(),
        })
    }
}

fn effort(id: &str, description: &str) -> Effort {
    Effort { id: id.into(), description: description.into() }
}

// ---- Claude Code: fixed aliases ------------------------------------------------

/// The aliases `claude --model` takes, with the efforts it takes. The CLI has no way to ask, so this list is ours.
pub fn claude_models() -> Vec<ModelOption> {
    let efforts = || {
        vec![
            effort("low", "Fastest, least thinking"),
            effort("medium", "Balanced"),
            effort("high", "More thinking"),
            effort("xhigh", "Even more thinking"),
            effort("max", "Most thinking"),
        ]
    };
    let m = |id: &str, name: &str, description: &str, is_default: bool| ModelOption {
        id: id.into(),
        name: name.into(),
        description: description.into(),
        is_default,
        default_effort: None,
        efforts: efforts(),
    };
    vec![
        m("default", "Default", "The model Claude Code picks for this account", true),
        m("opus", "Opus", "The most capable model, for hard problems", false),
        m("fable", "Fable", "A capable model for everyday work", false),
        m("sonnet", "Sonnet", "Fast and capable for most tasks", false),
        m("haiku", "Haiku", "The fastest and lightest model", false),
    ]
}

// ---- Codex: fixed list used only when the real one cannot be read ----------------

/// Used when `codex app-server` cannot be reached; the answer then says why and that this list is a stand-in.
pub fn codex_fallback_models() -> Vec<ModelOption> {
    let all = || vec![effort("low", ""), effort("medium", ""), effort("high", ""), effort("xhigh", "")];
    let m = |id: &str, name: &str, default_effort: &str, is_default: bool, extra: &[&str]| {
        let mut efforts = all();
        efforts.extend(extra.iter().map(|e| effort(e, "")));
        ModelOption { id: id.into(), name: name.into(), description: String::new(), is_default, default_effort: Some(default_effort.into()), efforts }
    };
    vec![
        m("gpt-6.1-sol", "GPT-6.1-Sol", "low", true, &["max", "ultra"]),
        m("gpt-6-sol", "GPT-6-Sol", "medium", false, &["max", "ultra"]),
        m("gpt-6-luna", "GPT-6-Luna", "medium", false, &["max"]),
        m("gpt-5.6-sol", "GPT-5.6-Sol", "low", false, &["max", "ultra"]),
        m("gpt-5.6-luna", "GPT-5.6-Luna", "medium", false, &["max"]),
        m("gpt-5.5", "GPT-5.5", "medium", false, &[]),
    ]
}

// ---- reading `model/list` -------------------------------------------------------

/// The entries of one `model/list` answer (`result`), or why they cannot be read.
pub fn parse_model_page(result: &Value) -> Result<(Vec<ModelOption>, Option<String>), String> {
    let data = result.get("data").and_then(Value::as_array).ok_or("the answer has no model list")?;
    let mut out = Vec::new();
    for m in data {
        let id = m.get("id").and_then(Value::as_str).or_else(|| m.get("model").and_then(Value::as_str)).ok_or("a model has no id")?;
        let efforts = m
            .get("supportedReasoningEfforts")
            .and_then(Value::as_array)
            .map(|es| {
                es.iter()
                    .filter_map(|e| {
                        let id = e.get("reasoningEffort").and_then(Value::as_str)?;
                        Some(Effort { id: id.to_string(), description: e.get("description").and_then(Value::as_str).unwrap_or("").to_string() })
                    })
                    .collect()
            })
            .unwrap_or_default();
        out.push(ModelOption {
            id: id.to_string(),
            name: m.get("displayName").and_then(Value::as_str).unwrap_or(id).to_string(),
            description: m.get("description").and_then(Value::as_str).unwrap_or("").to_string(),
            is_default: m.get("isDefault").and_then(Value::as_bool).unwrap_or(false),
            default_effort: m.get("defaultReasoningEffort").and_then(Value::as_str).map(str::to_string),
            efforts,
        });
    }
    let next = result.get("nextCursor").and_then(Value::as_str).filter(|c| !c.is_empty()).map(str::to_string);
    Ok((out, next))
}

const WRAPPER_MARK: &str = "Optional Codex entrypoint shim for agmsg monitor mode";

fn is_agmsg_wrapper(p: &Path) -> bool {
    use std::io::Read;
    let Ok(f) = std::fs::File::open(p) else { return false };
    let mut head = String::new();
    let _ = f.take(8192).read_to_string(&mut head);
    head.contains(WRAPPER_MARK)
}

/// The real Codex executable: `AGMSG_REAL_CODEX` if set, else the first `codex` on `path` that is not agmsg's own
/// shim (the same rule the shim uses to find the CLI it wraps). The shell function that wraps `codex` in a terminal
/// is not an executable and never appears here.
pub fn find_real_codex(path: &str, real_override: Option<&str>) -> Option<PathBuf> {
    if let Some(r) = real_override.filter(|r| !r.is_empty()) {
        let p = PathBuf::from(r);
        if p.is_file() {
            return Some(p);
        }
    }
    let names: &[&str] = if cfg!(windows) { &["codex.exe", "codex.cmd", "codex"] } else { &["codex"] };
    for dir in std::env::split_paths(path) {
        for n in names {
            let c = dir.join(n);
            if c.is_file() && !is_agmsg_wrapper(&c) {
                return Some(c);
            }
        }
    }
    None
}

fn rpc(id: u64, method: &str, params: Value) -> String {
    format!("{}\n", json!({ "id": id, "method": method, "params": params }))
}

/// What the call may take beyond `timeout` to end the process tree and let the reader finish. The whole call
/// returns within `timeout + CLEANUP_ALLOWANCE`: the exchange itself is cut off at `timeout`, never later.
pub const CLEANUP_ALLOWANCE: Duration = Duration::from_millis(1500);
/// How long the server gets to exit by itself after its input closes, before the tree is ended (part of the allowance).
const GRACE: Duration = Duration::from_millis(300);
/// The longest line read from the server (a model list is a few KB); a longer one is an error, not a buffer.
const MAX_LINE: usize = 1 << 20;
/// Lines waiting for the caller at most; the reader blocks (it does not grow memory) when the caller is behind.
const QUEUE_LINES: usize = 64;
/// The longest page cursor followed. A cursor is sent back to the server in the next request, and the server may
/// have stopped reading by then; a request of at most this plus a few hundred bytes cannot fill a pipe (4 KiB is the
/// smallest pipe buffer on the supported systems), so the write cannot block. A longer cursor is an error.
const MAX_CURSOR: usize = 2048;
const TIMED_OUT: &str = "codex app-server did not answer in time";

enum Line {
    Text(String),
    TooLong,
}

/// Owns everything the server starts, so ending it ends the whole tree on every path.
/// Unix: the child leads its own process group and the group is signalled. Windows: the child is put in a job
/// object that kills its members when closed, which also reaches descendants of a wrapper that already exited;
/// if the job cannot be made, `taskkill /T` on the recorded pid is the (bounded) fallback, and a descendant of a
/// wrapper that has already exited is then out of reach. A descendant that starts before the child is assigned to
/// the job, or one that leaves its group by itself, cannot be reached either.
struct OwnedTree {
    #[cfg(unix)]
    pgid: i32,
    #[cfg(windows)]
    job: Option<job::Job>,
    #[cfg(windows)]
    pid: u32,
}

impl OwnedTree {
    fn adopt(child: &std::process::Child) -> OwnedTree {
        #[cfg(unix)]
        {
            OwnedTree { pgid: child.id() as i32 }
        }
        #[cfg(windows)]
        {
            OwnedTree { job: job::Job::assign(child), pid: child.id() }
        }
    }

    fn kill(self, child: &mut std::process::Child, cleanup_end: Instant) {
        #[cfg(unix)]
        {
            // SAFETY: kill(2) with a negative pid signals the group the child led. The group exists while any
            // member lives, so its id is not reused for another group meanwhile; this runs within milliseconds of
            // the child being reaped.
            let _ = cleanup_end;
            unsafe {
                libc::kill(-self.pgid, libc::SIGKILL);
            }
        }
        #[cfg(windows)]
        {
            match self.job {
                Some(j) => drop(j), // closing the job kills every member
                None => taskkill_bounded(self.pid, cleanup_end.saturating_duration_since(Instant::now()).min(Duration::from_millis(1000))),
            }
        }
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[cfg(windows)]
fn taskkill_bounded(pid: u32, within: Duration) {
    use std::os::windows::process::CommandExt;
    let Ok(mut k) = Command::new("taskkill").args(["/T", "/F", "/PID", &pid.to_string()]).stdout(Stdio::null()).stderr(Stdio::null()).creation_flags(0x08000000).spawn() else { return };
    let end = Instant::now() + within;
    while Instant::now() < end {
        if matches!(k.try_wait(), Ok(Some(_))) {
            return;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = k.kill();
    let _ = k.wait();
}

#[cfg(windows)]
mod job {
    use std::os::windows::io::AsRawHandle;
    use windows::core::PCWSTR;
    use windows::Win32::Foundation::{CloseHandle, HANDLE};
    use windows::Win32::System::JobObjects::{AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation, SetInformationJobObject, JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE};

    pub struct Job(HANDLE);

    impl Job {
        pub fn assign(child: &std::process::Child) -> Option<Job> {
            // SAFETY: plain Win32 calls on a handle created here and a process handle owned by `child`.
            unsafe {
                let h = CreateJobObjectW(None, PCWSTR::null()).ok()?;
                let mut info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
                info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                let set = SetInformationJobObject(h, JobObjectExtendedLimitInformation, &info as *const _ as *const _, std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32);
                if set.is_err() || AssignProcessToJobObject(h, HANDLE(child.as_raw_handle() as _)).is_err() {
                    let _ = CloseHandle(h);
                    return None;
                }
                Some(Job(h))
            }
        }
    }

    impl Drop for Job {
        fn drop(&mut self) {
            // SAFETY: the handle is ours and closed once; KILL_ON_JOB_CLOSE ends the members.
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }
}

/// Starts `binary app-server` over stdio, asks `model/list` (includeHidden false) and ends the process tree.
/// The child inherits this app's environment as it is (`CODEX_HOME` included), so the list is the one the CLI the
/// app starts for an agent would show. It has no port, socket or daemon.
///
/// Time: the exchange is cut off at `timeout` (the deadline is checked before every line is looked at, so lines
/// already queued after it are not used), and ending the tree and the reader takes at most `CLEANUP_ALLOWANCE`
/// more. A list that continues past `MAX_PAGES` pages, a line over `MAX_LINE`, or an empty list is an error: a
/// partial list is never returned as the whole one.
pub fn fetch_codex_models(binary: &Path, path_env: Option<&str>, timeout: Duration) -> Result<Vec<ModelOption>, String> {
    let deadline = Instant::now() + timeout;
    let mut cmd = Command::new(binary);
    cmd.arg("app-server").stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null());
    if let Some(p) = path_env {
        cmd.env("PATH", p);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0); // its own group, so the whole tree it starts can be ended together
    }
    let mut child = cmd.spawn().map_err(|e| format!("could not start codex app-server: {e}"))?;
    let tree = OwnedTree::adopt(&child);
    let mut stdin = child.stdin.take().ok_or("no stdin")?;
    let stdout = child.stdout.take().ok_or("no stdout")?;
    let (tx, rx) = mpsc::sync_channel::<Line>(QUEUE_LINES);
    let reader = std::thread::spawn(move || {
        use std::io::Read;
        let mut r = BufReader::new(stdout);
        let mut buf = Vec::new();
        loop {
            buf.clear();
            match (&mut r).take(MAX_LINE as u64 + 1).read_until(b'\n', &mut buf) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            let line = if buf.len() > MAX_LINE { Line::TooLong } else { Line::Text(String::from_utf8_lossy(&buf).trim_end().to_string()) };
            let stop = matches!(line, Line::TooLong);
            if tx.send(line).is_err() || stop {
                break;
            }
        }
    });
    let result = (|| -> Result<Vec<ModelOption>, String> {
        let wait_for = |id: u64| -> Result<Value, String> {
            loop {
                let left = deadline.checked_duration_since(Instant::now()).ok_or(TIMED_OUT)?;
                let line = match rx.recv_timeout(left) {
                    Ok(Line::Text(l)) => l,
                    Ok(Line::TooLong) => return Err(format!("codex app-server sent a line over {MAX_LINE} bytes")),
                    Err(mpsc::RecvTimeoutError::Timeout) => return Err(TIMED_OUT.into()),
                    Err(mpsc::RecvTimeoutError::Disconnected) => return Err("codex app-server ended before it answered".into()),
                };
                if Instant::now() >= deadline {
                    return Err(TIMED_OUT.into()); // a line that was already waiting does not count past the deadline
                }
                let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                if v.get("id").and_then(Value::as_u64) != Some(id) {
                    continue; // a notification or another id
                }
                if let Some(e) = v.get("error") {
                    let msg = e.get("message").and_then(Value::as_str).unwrap_or("error");
                    let code = e.get("code").map(|c| c.to_string()).unwrap_or_default();
                    return Err(format!("codex app-server refused the request ({code}): {msg}"));
                }
                return v.get("result").cloned().ok_or_else(|| "the answer has no result".to_string());
            }
        };
        // A request is sent only after the previous one was answered (so the pipe is empty) and is at most a few
        // hundred bytes plus a cursor of at most MAX_CURSOR, far below any pipe's buffer: the write cannot block
        // on a server that stopped reading. The deadline is checked before every send.
        let send = |stdin: &mut std::process::ChildStdin, s: String| {
            if Instant::now() >= deadline {
                return Err(TIMED_OUT.to_string());
            }
            stdin.write_all(s.as_bytes()).and_then(|_| stdin.flush()).map_err(|e| format!("codex app-server closed its input: {e}"))
        };
        send(&mut stdin, rpc(1, "initialize", json!({ "clientInfo": { "name": "agmsg-app", "title": "agmsg", "version": env!("CARGO_PKG_VERSION") } })))?;
        wait_for(1)?;
        send(&mut stdin, format!("{}\n", json!({ "method": "initialized" })))?;
        let mut models = Vec::new();
        let mut cursor: Option<String> = None;
        for page in 0..MAX_PAGES {
            let id = 2 + page as u64;
            if cursor.as_deref().is_some_and(|c| c.len() > MAX_CURSOR) {
                return Err(format!("the server's page cursor is longer than {MAX_CURSOR} bytes; not following it"));
            }
            send(&mut stdin, rpc(id, "model/list", json!({ "includeHidden": false, "cursor": cursor })))?;
            let (mut got, next) = parse_model_page(&wait_for(id)?)?;
            models.append(&mut got);
            match next {
                Some(c) => cursor = Some(c),
                None => {
                    cursor = None;
                    break;
                }
            }
        }
        if cursor.is_some() {
            return Err(format!("the model list continues past {MAX_PAGES} pages; not showing a partial list"));
        }
        if models.is_empty() {
            return Err("codex app-server returned no models".into());
        }
        Ok(models)
    })();
    // Cleanup, every path, inside one absolute deadline: close the input, give the server a moment to exit, end the
    // whole tree, let the reader finish.
    let cleanup_end = Instant::now() + CLEANUP_ALLOWANCE;
    drop(stdin);
    let grace_end = (Instant::now() + GRACE).min(cleanup_end);
    while Instant::now() < grace_end && !matches!(child.try_wait(), Ok(Some(_))) {
        std::thread::sleep(Duration::from_millis(10));
    }
    tree.kill(&mut child, cleanup_end);
    drop(rx); // a reader blocked on a full queue is released
    while !reader.is_finished() && Instant::now() < cleanup_end {
        std::thread::sleep(Duration::from_millis(5));
    }
    if reader.is_finished() {
        let _ = reader.join();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Value {
        json!({
            "data": [
                { "id": "gpt-x", "model": "gpt-x", "displayName": "GPT-X", "description": "d", "hidden": false, "isDefault": true,
                  "defaultReasoningEffort": "low",
                  "supportedReasoningEfforts": [ { "reasoningEffort": "low", "description": "fast" }, { "reasoningEffort": "ultra", "description": "most" } ] },
                { "id": "gpt-y", "displayName": "GPT-Y", "description": "", "hidden": false, "isDefault": false,
                  "defaultReasoningEffort": "medium", "supportedReasoningEfforts": [ { "reasoningEffort": "medium", "description": "" } ] }
            ],
            "nextCursor": null
        })
    }

    #[test]
    fn a_model_page_keeps_the_names_default_and_efforts_of_each_model() {
        let (ms, next) = parse_model_page(&sample()).unwrap();
        assert_eq!(next, None);
        assert_eq!(ms.len(), 2);
        assert_eq!(ms[0].id, "gpt-x");
        assert_eq!(ms[0].name, "GPT-X");
        assert!(ms[0].is_default && !ms[1].is_default);
        assert_eq!(ms[0].default_effort.as_deref(), Some("low"));
        assert_eq!(ms[0].efforts.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(), ["low", "ultra"]);
        assert_eq!(ms[1].efforts.len(), 1, "efforts differ per model");
    }

    #[test]
    fn a_page_without_a_list_or_with_a_nameless_model_is_an_error() {
        assert!(parse_model_page(&json!({})).is_err());
        assert!(parse_model_page(&json!({ "data": [ {} ] })).is_err());
    }

    #[test]
    fn the_next_cursor_is_kept_only_when_it_is_a_non_empty_string() {
        let mut v = sample();
        v["nextCursor"] = json!("abc");
        assert_eq!(parse_model_page(&v).unwrap().1.as_deref(), Some("abc"));
        v["nextCursor"] = json!("");
        assert_eq!(parse_model_page(&v).unwrap().1, None);
    }

    #[test]
    fn claude_gets_the_fixed_aliases_with_one_default_and_the_five_efforts() {
        let ms = claude_models();
        assert_eq!(ms.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["default", "opus", "fable", "sonnet", "haiku"]);
        assert_eq!(ms.iter().filter(|m| m.is_default).count(), 1);
        for m in &ms {
            assert!(!m.description.is_empty());
            assert_eq!(m.efforts.iter().map(|e| e.id.as_str()).collect::<Vec<_>>(), ["low", "medium", "high", "xhigh", "max"]);
        }
    }

    #[test]
    fn the_codex_fallback_has_one_default_and_efforts_per_model() {
        let ms = codex_fallback_models();
        assert_eq!(ms.iter().filter(|m| m.is_default).count(), 1);
        assert!(ms.iter().any(|m| m.efforts.len() != ms[0].efforts.len()));
    }

    /// By hand on a machine with Codex installed: `cargo test --lib reads_the_real_codex_list -- --ignored --nocapture`.
    /// Uses this shell's environment as the app would (CODEX_HOME included) and only reads.
    #[test]
    #[ignore]
    fn reads_the_real_codex_list() {
        let path = std::env::var("PATH").unwrap_or_default();
        let bin = find_real_codex(&path, std::env::var("AGMSG_REAL_CODEX").ok().as_deref()).expect("codex on PATH");
        let t = Instant::now();
        let ms = fetch_codex_models(&bin, Some(&path), FETCH_TIMEOUT).expect("model/list");
        println!("real codex {} -> {} models in {} ms", bin.display(), ms.len(), t.elapsed().as_millis());
        for m in &ms {
            println!("{} | {} | default={} | {:?} | {:?}", m.id, m.name, m.is_default, m.default_effort, m.efforts.iter().map(|e| e.id.as_str()).collect::<Vec<_>>());
        }
    }

    #[cfg(unix)]
    mod process {
        use super::*;
        use std::os::unix::fs::PermissionsExt;

        /// A stand-in `codex`: answers initialize and model/list from a canned script, or misbehaves as told.
        fn fake(dir: &Path, name: &str, body: &str) -> PathBuf {
            let p = dir.join(name);
            std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
            p
        }

        const GOOD: &str = r#"
while IFS= read -r line; do
  case "$line" in
    *'"initialize"'*) echo '{"id":1,"result":{"userAgent":"x"}}' ;;
    *'"model/list"'*) echo '{"method":"noise"}'; echo '{"id":2,"result":{"data":[{"id":"gpt-x","displayName":"GPT-X","description":"d","hidden":false,"isDefault":true,"defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"low","description":""}]}],"nextCursor":null}}' ;;
  esac
done
"#;

        #[test]
        fn the_list_is_read_over_stdio_and_the_process_ends() {
            let d = tempfile::tempdir().unwrap();
            let bin = fake(d.path(), "codex", GOOD);
            let ms = fetch_codex_models(&bin, None, Duration::from_secs(30)).unwrap();
            assert_eq!(ms.len(), 1);
            assert_eq!(ms[0].id, "gpt-x");
        }

        #[test]
        fn the_client_sends_initialize_then_initialized_then_model_list_without_hidden_models() {
            let d = tempfile::tempdir().unwrap();
            let log = d.path().join("seen.log");
            let body = format!("{{ while IFS= read -r l; do echo \"$l\" >> '{}'; case \"$l\" in *'\"initialize\"'*) echo '{{\"id\":1,\"result\":{{}}}}';; *'\"model/list\"'*) echo '{{\"id\":2,\"result\":{{\"data\":[{{\"id\":\"m\"}}]}}}}';; esac; done; }}", log.display());
            let bin = fake(d.path(), "codex", &body);
            fetch_codex_models(&bin, None, Duration::from_secs(30)).unwrap();
            let seen = std::fs::read_to_string(&log).unwrap();
            let lines: Vec<&str> = seen.lines().collect();
            assert!(lines[0].contains("\"initialize\""), "{seen}");
            assert!(lines[1].contains("\"initialized\"") && !lines[1].contains("\"id\""), "{seen}");
            assert!(lines[2].contains("\"model/list\"") && lines[2].contains("\"includeHidden\":false"), "{seen}");
        }

        #[test]
        fn an_error_answer_such_as_32600_is_returned_with_its_code() {
            let d = tempfile::tempdir().unwrap();
            let bin = fake(d.path(), "codex", r#"while IFS= read -r l; do case "$l" in *'"initialize"'*) echo '{"id":1,"result":{}}';; *'"model/list"'*) echo '{"id":2,"error":{"code":-32600,"message":"restart Codex"}}';; esac; done"#);
            let e = fetch_codex_models(&bin, None, Duration::from_secs(30)).unwrap_err();
            assert!(e.contains("-32600") && e.contains("restart Codex"), "{e}");
        }

        #[test]
        fn a_server_that_never_answers_is_stopped_at_the_timeout() {
            let d = tempfile::tempdir().unwrap();
            let bin = fake(d.path(), "codex", "exec sleep 30");
            let t = Instant::now();
            let e = fetch_codex_models(&bin, None, Duration::from_millis(300)).unwrap_err();
            assert!(e.contains("in time"), "{e}");
            assert!(t.elapsed() < Duration::from_secs(10), "the read is bounded");
        }

        /// A fixture sleep length no other test run (or seat) can share: `<prefix>.<this process id>.<counter>`.
        fn unique(prefix: &str) -> String {
            static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
            format!("{prefix}.{}{}", std::process::id(), N.fetch_add(1, std::sync::atomic::Ordering::SeqCst))
        }

        /// Command lines of every process on the machine, to look for a marker only this test's fixture carries.
        fn marked(marker: &str) -> usize {
            let out = Command::new("ps").args(["-A", "-o", "command="]).output().unwrap();
            String::from_utf8_lossy(&out.stdout).lines().filter(|l| l.contains(marker) && !l.contains("ps -A")).count()
        }

        #[test]
        fn a_launcher_whose_descendant_keeps_the_pipe_open_leaves_nothing_behind() {
            let d = tempfile::tempdir().unwrap();
            // the descendant inherits stdout (the pipe) and outlives the wrapper; the wrapper then stalls
            let m = unique("71");
            let bin = fake(d.path(), "codex", &format!("sleep {m} &\nexec sleep 1{m}"));
            let t = Instant::now();
            let timeout = Duration::from_millis(200);
            let e = fetch_codex_models(&bin, None, timeout).unwrap_err();
            assert!(e.contains("in time"), "{e}");
            assert!(t.elapsed() < timeout + CLEANUP_ALLOWANCE + Duration::from_secs(2), "returned in {:?}", t.elapsed());
            std::thread::sleep(Duration::from_millis(200));
            assert_eq!(marked(&m), 0, "no descendant of the launched tree is left");
        }

        #[test]
        fn a_descendant_left_after_a_good_answer_is_ended_too() {
            let d = tempfile::tempdir().unwrap();
            let m = unique("73");
            let body = format!("sleep {m} &\n{GOOD}");
            let bin = fake(d.path(), "codex", &body);
            let t = Instant::now();
            let ms = fetch_codex_models(&bin, None, Duration::from_secs(30)).unwrap();
            assert_eq!(ms.len(), 1);
            assert!(t.elapsed() < Duration::from_secs(5), "the answer is not held up by the leftover: {:?}", t.elapsed());
            std::thread::sleep(Duration::from_millis(200));
            assert_eq!(marked(&m), 0);
        }

        #[test]
        fn a_list_that_continues_past_the_page_cap_is_an_error_not_a_partial_list() {
            let d = tempfile::tempdir().unwrap();
            let bin = fake(d.path(), "codex", r#"while IFS= read -r l; do case "$l" in *'"initialize"'*) echo '{"id":1,"result":{}}';; *'"id":'*'"model/list"'*) id=$(echo "$l" | sed 's/.*"id":\([0-9]*\).*/\1/'); echo '{"id":'$id',"result":{"data":[{"id":"m"}],"nextCursor":"more"}}';; esac; done"#);
            let e = fetch_codex_models(&bin, None, Duration::from_secs(30)).unwrap_err();
            assert!(e.contains("partial list"), "{e}");
        }

        #[test]
        fn the_deadline_is_enforced_even_for_lines_already_queued() {
            let d = tempfile::tempdir().unwrap();
            let bin = fake(d.path(), "codex", GOOD);
            let t = Instant::now();
            let e = fetch_codex_models(&bin, None, Duration::ZERO).unwrap_err();
            assert!(e.contains("in time"), "{e}");
            assert!(t.elapsed() < CLEANUP_ALLOWANCE + Duration::from_secs(2), "{:?}", t.elapsed());
        }

        #[test]
        fn an_answer_that_comes_after_the_timeout_is_not_used_and_the_call_stays_within_its_allowance() {
            let d = tempfile::tempdir().unwrap();
            let body = format!("sleep 0.6\n{GOOD}");
            let bin = fake(d.path(), "codex", &body);
            let t = Instant::now();
            let timeout = Duration::from_millis(250);
            let e = fetch_codex_models(&bin, None, timeout).unwrap_err();
            assert!(e.contains("in time"), "{e}");
            assert!(t.elapsed() < timeout + CLEANUP_ALLOWANCE + Duration::from_secs(1), "{:?}", t.elapsed());
        }

        #[test]
        fn a_line_over_the_size_limit_is_an_error_and_the_reader_does_not_buffer_it() {
            let d = tempfile::tempdir().unwrap();
            let bin = fake(d.path(), "codex", r#"IFS= read -r l; head -c 3000000 /dev/zero | tr '\0' x; echo; sleep 5"#);
            let e = fetch_codex_models(&bin, None, Duration::from_secs(30)).unwrap_err();
            assert!(e.contains("over"), "{e}");
        }

        #[test]
        fn a_huge_cursor_and_a_server_that_stopped_reading_cannot_block_the_call() {
            let d = tempfile::tempdir().unwrap();
            let m = unique("75");
            let body = format!(
                r#"IFS= read -r l
echo '{{"id":1,"result":{{}}}}'
IFS= read -r l
IFS= read -r l
c=$(head -c 200000 /dev/zero | tr '\0' a)
echo '{{"id":2,"result":{{"data":[{{"id":"m"}}],"nextCursor":"'"$c"'"}}}}'
exec sleep {m}"#
            );
            let bin = fake(d.path(), "codex", &body);
            let t = Instant::now();
            let timeout = Duration::from_secs(3);
            let e = fetch_codex_models(&bin, None, timeout).unwrap_err();
            assert!(e.contains("cursor"), "{e}");
            assert!(t.elapsed() < timeout + CLEANUP_ALLOWANCE + Duration::from_secs(1), "returned in {:?}", t.elapsed());
            std::thread::sleep(Duration::from_millis(200));
            assert_eq!(marked(&m), 0, "the stalled server is ended");
        }

        #[test]
        fn a_missing_binary_is_an_error_not_a_panic() {
            let e = fetch_codex_models(Path::new("/nonexistent/codex"), None, Duration::from_secs(1)).unwrap_err();
            assert!(e.contains("could not start"), "{e}");
        }

        #[test]
        fn an_empty_list_is_an_error_so_the_fallback_is_used() {
            let d = tempfile::tempdir().unwrap();
            let bin = fake(d.path(), "codex", r#"while IFS= read -r l; do case "$l" in *'"initialize"'*) echo '{"id":1,"result":{}}';; *'"model/list"'*) echo '{"id":2,"result":{"data":[]}}';; esac; done"#);
            assert!(fetch_codex_models(&bin, None, Duration::from_secs(30)).unwrap_err().contains("no models"));
        }

        #[test]
        fn the_real_codex_is_found_past_agmsg_own_shim_and_the_override_wins() {
            let d = tempfile::tempdir().unwrap();
            let shim_dir = d.path().join("shim");
            let real_dir = d.path().join("real");
            std::fs::create_dir_all(&shim_dir).unwrap();
            std::fs::create_dir_all(&real_dir).unwrap();
            fake(&shim_dir, "codex", &format!("# {WRAPPER_MARK}\nexit 0"));
            let real = fake(&real_dir, "codex", "exit 0");
            let path = std::env::join_paths([&shim_dir, &real_dir]).unwrap().to_string_lossy().into_owned();
            assert_eq!(find_real_codex(&path, None), Some(real.clone()));
            assert_eq!(find_real_codex(&shim_dir.to_string_lossy(), None), None, "only the shim: nothing real");
            let other = fake(d.path(), "other", "exit 0");
            assert_eq!(find_real_codex(&path, Some(&other.to_string_lossy())), Some(other));
        }
    }

    /// Windows lifecycle check, run by hand on a Windows machine:
    /// `cargo test --lib agent_models::tests::windows_process -- --nocapture`.
    /// A launcher (.cmd) starts a uniquely named copy of ping.exe as its descendant; after a timeout (wrapper still
    /// running) and after the wrapper has already exited, no process with that image name may remain.
    #[cfg(windows)]
    mod windows_process {
        use super::*;

        fn running(image: &str) -> bool {
            let out = Command::new("tasklist").args(["/FI", &format!("IMAGENAME eq {image}"), "/NH"]).output().unwrap();
            String::from_utf8_lossy(&out.stdout).to_lowercase().contains(&image.to_lowercase())
        }

        fn fixture(wrapper_stays: bool) -> (tempfile::TempDir, PathBuf, String) {
            let d = tempfile::tempdir().unwrap();
            let image = format!("agmsgfx{}{}.exe", std::process::id(), if wrapper_stays { "a" } else { "b" });
            let sys = std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".into());
            std::fs::copy(format!("{sys}\\System32\\PING.EXE"), d.path().join(&image)).unwrap();
            let mut body = format!("@echo off\r\nstart /B \"\" \"%~dp0{image}\" -n 60 127.0.0.1 >nul\r\n");
            if wrapper_stays {
                body.push_str(&format!("\"%~dp0{image}\" -n 61 127.0.0.1 >nul\r\n"));
            }
            let bin = d.path().join("codex.cmd");
            std::fs::write(&bin, body).unwrap();
            (d, bin, image)
        }

        #[test]
        fn a_timeout_with_the_wrapper_still_running_leaves_no_descendant() {
            let (_d, bin, image) = fixture(true);
            let e = fetch_codex_models(&bin, None, Duration::from_millis(500)).unwrap_err();
            std::thread::sleep(Duration::from_millis(500));
            assert!(!running(&image), "{image} is still running after: {e}");
        }

        #[test]
        fn a_wrapper_that_already_exited_leaves_no_descendant_behind_either() {
            let (_d, bin, image) = fixture(false);
            let e = fetch_codex_models(&bin, None, Duration::from_millis(500)).unwrap_err();
            std::thread::sleep(Duration::from_millis(500));
            assert!(!running(&image), "{image} is still running after: {e}");
        }
    }
}
