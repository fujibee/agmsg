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

/// Starts `binary app-server` over stdio, asks `model/list` once (includeHidden false), and ends the process.
/// The child inherits this app's environment as it is (`CODEX_HOME` included), so the list is the one the CLI the
/// app starts for an agent would show. It has no port, socket or daemon, and the whole read is bounded by `timeout`.
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
    let mut child = cmd.spawn().map_err(|e| format!("could not start codex app-server: {e}"))?;
    let mut stdin = child.stdin.take().ok_or("no stdin")?;
    let stdout = child.stdout.take().ok_or("no stdout")?;
    let (tx, rx) = mpsc::channel::<String>();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let result = (|| -> Result<Vec<ModelOption>, String> {
        let wait_for = |id: u64| -> Result<Value, String> {
            loop {
                let left = deadline.saturating_duration_since(Instant::now());
                let line = rx.recv_timeout(left).map_err(|_| "codex app-server did not answer in time".to_string())?;
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
        let send = |stdin: &mut std::process::ChildStdin, s: String| stdin.write_all(s.as_bytes()).and_then(|_| stdin.flush()).map_err(|e| format!("codex app-server closed its input: {e}"));
        send(&mut stdin, rpc(1, "initialize", json!({ "clientInfo": { "name": "agmsg-app", "title": "agmsg", "version": env!("CARGO_PKG_VERSION") } })))?;
        wait_for(1)?;
        send(&mut stdin, format!("{}\n", json!({ "method": "initialized" })))?;
        let mut models = Vec::new();
        let mut cursor: Option<String> = None;
        for page in 0..MAX_PAGES {
            let id = 2 + page as u64;
            send(&mut stdin, rpc(id, "model/list", json!({ "includeHidden": false, "cursor": cursor })))?;
            let (mut got, next) = parse_model_page(&wait_for(id)?)?;
            models.append(&mut got);
            match next {
                Some(c) => cursor = Some(c),
                None => break,
            }
        }
        if models.is_empty() {
            return Err("codex app-server returned no models".into());
        }
        Ok(models)
    })();
    drop(stdin); // the server exits when its input closes
    let end = Instant::now() + Duration::from_secs(2);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            _ if Instant::now() >= end => {
                let _ = child.kill();
                let _ = child.wait();
                break;
            }
            _ => std::thread::sleep(Duration::from_millis(10)),
        }
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
            let ms = fetch_codex_models(&bin, None, Duration::from_secs(5)).unwrap();
            assert_eq!(ms.len(), 1);
            assert_eq!(ms[0].id, "gpt-x");
        }

        #[test]
        fn the_client_sends_initialize_then_initialized_then_model_list_without_hidden_models() {
            let d = tempfile::tempdir().unwrap();
            let log = d.path().join("seen.log");
            let body = format!("{{ while IFS= read -r l; do echo \"$l\" >> '{}'; case \"$l\" in *'\"initialize\"'*) echo '{{\"id\":1,\"result\":{{}}}}';; *'\"model/list\"'*) echo '{{\"id\":2,\"result\":{{\"data\":[{{\"id\":\"m\"}}]}}}}';; esac; done; }}", log.display());
            let bin = fake(d.path(), "codex", &body);
            fetch_codex_models(&bin, None, Duration::from_secs(5)).unwrap();
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
            let e = fetch_codex_models(&bin, None, Duration::from_secs(5)).unwrap_err();
            assert!(e.contains("-32600") && e.contains("restart Codex"), "{e}");
        }

        #[test]
        fn a_server_that_never_answers_is_stopped_at_the_timeout() {
            let d = tempfile::tempdir().unwrap();
            let bin = fake(d.path(), "codex", "sleep 30");
            let t = Instant::now();
            let e = fetch_codex_models(&bin, None, Duration::from_millis(300)).unwrap_err();
            assert!(e.contains("in time"), "{e}");
            assert!(t.elapsed() < Duration::from_secs(10), "the read is bounded");
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
            assert!(fetch_codex_models(&bin, None, Duration::from_secs(5)).unwrap_err().contains("no models"));
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
}
