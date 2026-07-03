// agmsg data access — VIEW-ONLY reader over the agmsg installation.
//
// The desktop app reads agmsg's own SQLite DB and team config directly; it never
// mutates agmsg state here (sending still goes through agmsg's scripts). This
// powers the default "team room": the whole cross-agent conversation as a
// read-only feed, plus the left-hand member list.

use std::path::PathBuf;
use std::thread;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager};

/// Base dir of the agmsg install (skill layout: db/, teams/, scripts/, ...).
fn agmsg_base() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".agents/skills/agmsg")
}

fn db_path() -> PathBuf {
    agmsg_base().join("db/messages.db")
}

fn open_ro() -> Result<rusqlite::Connection, String> {
    rusqlite::Connection::open_with_flags(
        db_path(),
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(|e| e.to_string())
}

#[derive(Clone, Serialize)]
pub struct Message {
    pub id: i64,
    pub team: String,
    pub from: String,
    pub to: String,
    pub body: String,
    pub created_at: String,
}

#[derive(Clone, Serialize)]
pub struct Member {
    pub name: String,
    /// Agent types registered under this name (claude-code, codex, ...).
    pub types: Vec<String>,
    /// First registration's project dir (used as the cwd when spawning a pane).
    pub project: String,
}

/// A spawnable agent type, read from its type.conf manifest.
#[derive(Clone, Serialize)]
pub struct AgentType {
    /// The type name (directory under scripts/drivers/types/), e.g. "claude-code".
    pub name: String,
    /// The CLI binary to launch (manifest `cli=`), e.g. "claude".
    pub cli: String,
    /// Extra CLI argv tokens for this type from agmsg's spawn-options file
    /// (see scripts/lib/spawn-options.sh), e.g. ["--permission-mode",
    /// "acceptEdits"]. Spliced before the actas boot prompt, same relative
    /// position `agmsg spawn` uses, so a pane spawned from the app gets the
    /// same extra flags a CLI-driven spawn would.
    pub options: Vec<String>,
}

/// Read one key from a type.conf manifest (read-only key=value data, never
/// sourced). Returns the trimmed value, or None if absent.
fn manifest_get(path: &std::path::Path, key: &str) -> Option<String> {
    let raw = std::fs::read_to_string(path).ok()?;
    for line in raw.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            if k.trim() == key {
                return Some(v.trim().trim_matches('"').to_string());
            }
        }
    }
    None
}

/// Resolve the spawn-options file: $AGMSG_SPAWN_OPTIONS_FILE, else
/// ~/.agmsg/config/spawn_options.yaml (same resolution as
/// scripts/lib/spawn-options.sh:agmsg_spawn_options_file).
fn spawn_options_file() -> std::path::PathBuf {
    if let Ok(p) = std::env::var("AGMSG_SPAWN_OPTIONS_FILE") {
        if !p.is_empty() {
            return std::path::PathBuf::from(p);
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    std::path::PathBuf::from(home).join(".agmsg/config/spawn_options.yaml")
}

/// Extra CLI argv tokens for `agent_type` from the spawn-options YAML: a flat
/// "type:" header followed by 2-space-indented "key: value" lines (same
/// minimal dialect as agmsg's config.yaml — no nesting, no quoting). Mirrors
/// scripts/lib/spawn-options.sh:agmsg_spawn_options_tokens exactly: `false`
/// suppresses the flag, `true` emits the key alone, anything else emits
/// `key` then `value` as two tokens. A missing file/section is a no-op.
fn spawn_options_tokens(agent_type: &str) -> Vec<String> {
    let raw = match std::fs::read_to_string(spawn_options_file()) {
        Ok(s) => s,
        Err(_) => return Vec::new(),
    };
    let header = format!("{agent_type}:");
    let mut tokens = Vec::new();
    let mut in_section = false;
    for line in raw.lines() {
        if !line.starts_with(' ') && !line.starts_with('#') && !line.trim().is_empty() {
            in_section = line.starts_with(&header);
            continue;
        }
        if !in_section {
            continue;
        }
        let Some(body) = line.strip_prefix("  ") else { continue };
        if body.starts_with(' ') {
            continue; // deeper nesting isn't part of this flat dialect
        }
        let Some((key, rest)) = body.split_once(':') else { continue };
        let val = rest.split('#').next().unwrap_or("").trim();
        if val == "false" {
            continue;
        }
        tokens.push(key.trim().to_string());
        if !val.is_empty() && val != "true" {
            tokens.push(val.to_string());
        }
    }
    tokens
}

/// List the agent types the app can spawn: those whose manifest declares
/// `spawnable=yes` and a `cli=` binary. Read straight from agmsg's type
/// registry (scripts/drivers/types/*/type.conf) so the app never hardcodes the
/// list — a newly installed type shows up automatically.
#[tauri::command]
pub fn agmsg_spawnable_types() -> Result<Vec<AgentType>, String> {
    let dir = agmsg_base().join("scripts/drivers/types");
    let mut types = Vec::new();
    let entries = std::fs::read_dir(&dir).map_err(|e| e.to_string())?;
    for entry in entries.flatten() {
        let conf = entry.path().join("type.conf");
        if !conf.is_file() {
            continue;
        }
        if manifest_get(&conf, "spawnable").as_deref() != Some("yes") {
            continue;
        }
        let cli = match manifest_get(&conf, "cli") {
            Some(c) if !c.is_empty() => c,
            _ => continue,
        };
        let name = manifest_get(&conf, "name")
            .filter(|s| !s.is_empty())
            .or_else(|| entry.file_name().to_str().map(String::from))
            .unwrap_or_default();
        if !name.is_empty() {
            let options = spawn_options_tokens(&name);
            types.push(AgentType { name, cli, options });
        }
    }
    types.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(types)
}

/// Parse each non-empty line of `raw` as JSON into `T`, skipping lines that
/// fail to parse rather than failing the whole batch — a single malformed
/// record (a future schema field this build doesn't know about, say)
/// shouldn't blank out an entire team room.
fn parse_jsonl<T: for<'de> Deserialize<'de>>(raw: &str) -> Vec<T> {
    raw.lines()
        .filter(|l| !l.trim().is_empty())
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}

/// Wire shape of `api.sh get teams <team> members` — see scripts/api.sh.
/// `project` is nullable there (a member with zero registrations); `Member`
/// itself keeps a plain `String` for the frontend, so this is mapped rather
/// than deriving Deserialize directly on `Member`.
#[derive(Deserialize)]
struct ApiMember {
    name: String,
    #[serde(default)]
    types: Vec<String>,
    project: Option<String>,
}

/// Wire shape of `api.sh get teams <team> messages` — matches the
/// `message_sent` event schema the (in-progress, unmerged as of this
/// writing) storage-axis design defines for a future `storage_history`, so
/// this struct (and the `at` rename) is what will need to keep working once
/// that lands, not what needs to change. `id` is a JSON *string* on the
/// wire — api.sh CASTs it, since the driver interface treats every message
/// id as opaque (a legacy sqlite int today, potentially a UUIDv7 or
/// Redis-stream-id tomorrow) — parsed back to `i64` below for `Message`,
/// which is a Tauri-IPC-only contract with the frontend, not agmsg's.
#[derive(Deserialize)]
struct ApiMessage {
    id: String,
    team: String,
    from: String,
    to: String,
    body: String,
    #[serde(rename = "at")]
    created_at: String,
}

/// Wire shape of `api.sh get teams` — one `{"name": "..."}` object per line.
#[derive(Deserialize)]
struct ApiTeam {
    name: String,
}

/// Cheap existence check, not a full health check — gates the first-run
/// auto-install flow below. Any other failure (broken install, bad DB, ...)
/// still surfaces as a real error from agmsg_teams rather than triggering
/// a reinstall.
#[tauri::command]
pub fn agmsg_is_installed() -> bool {
    agmsg_base().join("scripts").join("api.sh").is_file()
}

/// First-run bootstrap: run the agmsg-core install.sh bundled into the app
/// (see scripts/bundle-core.sh, AGMSG_CORE_REF) directly — no network access
/// at runtime. The bundled ref is fixed at build time and audited via git
/// history; this command only ever executes that local copy, never fetches
/// anything itself. install.sh is safe to re-run (preserves db/teams on an
/// existing install), but this command is only ever called when
/// agmsg_is_installed() is false.
#[tauri::command]
pub fn agmsg_install(app: AppHandle) -> Result<(), String> {
    let install_sh = app
        .path()
        .resource_dir()
        .map_err(|e| e.to_string())?
        .join("agmsg-core")
        .join("install.sh");
    let output = std::process::Command::new("bash")
        .arg(&install_sh)
        .output()
        .map_err(|e| e.to_string())?;
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).into_owned())
    }
}

/// List team names. Shells out to api.sh rather than reading teams/
/// directly — see scripts/api.sh's own header for why this exists
/// (storage abstraction / non-bash consumers); the team registry itself
/// stays file-based behind api.sh (out of scope for the storage axis)
/// rather than becoming a driver.
#[tauri::command]
pub fn agmsg_teams() -> Result<Vec<String>, String> {
    let raw = run_script("api.sh", &["get", "teams"])?;
    let mut teams: Vec<String> =
        parse_jsonl::<ApiTeam>(&raw).into_iter().map(|t| t.name).collect();
    teams.sort();
    Ok(teams)
}

/// Members of a team, via `api.sh get teams <team> members`.
#[tauri::command]
pub fn agmsg_members(team: String) -> Result<Vec<Member>, String> {
    let raw = run_script("api.sh", &["get", "teams", &team, "members"])?;
    let mut members: Vec<Member> = parse_jsonl::<ApiMember>(&raw)
        .into_iter()
        .map(|m| {
            let mut types = m.types;
            types.sort();
            types.dedup();
            Member { name: m.name, types, project: m.project.unwrap_or_default() }
        })
        .collect();
    members.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(members)
}

/// Most recent `limit` messages for a team (oldest-first), for the team room.
/// Paged by id: pass `before_id` (the currently-oldest loaded message's id) to
/// fetch the next page further back, for "load more" on scroll-up. Defaults
/// to the 30 most recent when `before_id` is omitted. Via
/// `api.sh get teams <team> messages`, which already returns oldest-first —
/// no local re-sort needed (see that command's own ordering note).
#[tauri::command]
pub fn agmsg_messages(
    team: String,
    limit: Option<u32>,
    before_id: Option<i64>,
) -> Result<Vec<Message>, String> {
    let limit_s = limit.unwrap_or(30).to_string();
    let mut args = vec!["get", "teams", &team, "messages", "--limit", &limit_s];
    let before_id_s;
    if let Some(id) = before_id {
        before_id_s = id.to_string();
        args.push("--before-id");
        args.push(&before_id_s);
    }
    let raw = run_script("api.sh", &args)?;
    Ok(parse_jsonl::<ApiMessage>(&raw)
        .into_iter()
        .filter_map(|m| Some(Message {
            id: m.id.parse().ok()?,
            team: m.team,
            from: m.from,
            to: m.to,
            body: m.body,
            created_at: m.created_at,
        }))
        .collect())
}

/// Run an agmsg script (scripts/<name>) with args. All registry mutations go
/// through agmsg's own scripts — the app never writes the DB or team config
/// itself. Returns stdout on success, stderr on failure.
fn run_script(name: &str, args: &[&str]) -> Result<String, String> {
    let script = agmsg_base().join("scripts").join(name);
    let output = std::process::Command::new("bash")
        .arg(script)
        .args(args)
        .output()
        .map_err(|e| e.to_string())?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).into_owned())
    }
}

/// Send a message AS the app user via agmsg's own send.sh. `from` is the
/// app-user identity; it must already be a member of `team`.
#[tauri::command]
pub fn agmsg_send(team: String, from: String, to: String, body: String) -> Result<(), String> {
    run_script("send.sh", &[&team, &from, &to, &body]).map(|_| ())
}

/// The installed agmsg slash-command name (basename of the skill dir). Used to
/// build the `/<cmd> actas <name>` boot prompt, exactly as spawn.sh derives it,
/// so a custom install (e.g. `/m`) still boots the right command.
#[tauri::command]
pub fn agmsg_command_name() -> String {
    agmsg_base()
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("agmsg")
        .to_string()
}

/// Default project dir for a freshly-added agent: <HOME>/agmsg-agents/<name>.
#[tauri::command]
pub fn agmsg_default_project(name: String) -> Result<String, String> {
    let home = std::env::var("HOME").map_err(|e| e.to_string())?;
    Ok(format!("{home}/agmsg-agents/{name}"))
}

/// Add an agent to a team (also used to add the app-user with type `agmsg-app`).
/// Creates the team and the project dir if needed. Spawning the agent's PTY pane
/// is a separate step.
#[tauri::command]
pub fn agmsg_join(
    team: String,
    name: String,
    agent_type: String,
    project: String,
) -> Result<(), String> {
    std::fs::create_dir_all(&project).map_err(|e| e.to_string())?;
    run_script("join.sh", &[&team, &name, &agent_type, &project]).map(|_| ())
}

/// Rename a member in a team (updates team config + rewrites message history).
#[tauri::command]
pub fn agmsg_rename(team: String, old_name: String, new_name: String) -> Result<(), String> {
    run_script("rename.sh", &[&team, &old_name, &new_name]).map(|_| ())
}

/// Remove a member from a team (leave.sh; removes the team if it becomes empty).
#[tauri::command]
pub fn agmsg_leave(team: String, name: String) -> Result<(), String> {
    run_script("leave.sh", &[&team, &name]).map(|_| ())
}

/// The actual delivery mode for (agent_type, project): "monitor", "turn",
/// "both", or "off". Shells out to `delivery.sh status` — agmsg's own
/// source of truth (it derives the mode from the project's hooks file,
/// e.g. .claude/settings.local.json or .codex/hooks.json) — rather than
/// re-deriving it here, so this never drifts from core's logic (including
/// per-type paths like codex's opt-in app-server bridge "monitor" mode,
/// which a static type.conf flag can't see).
#[tauri::command]
pub fn agmsg_delivery_mode(agent_type: String, project: String) -> Result<String, String> {
    let output = run_script("delivery.sh", &["status", &agent_type, &project])?;
    for line in output.lines() {
        if let Some(mode) = line.strip_prefix("mode:") {
            return Ok(mode.trim().to_string());
        }
    }
    Ok("off".to_string())
}

/// Poll the DB for new rows and emit each as an `agmsg-message` event so the
/// team room updates live (and so spawned panes can be fed via stdin-inject).
pub fn start_watcher(app: AppHandle) {
    thread::spawn(move || {
        // agmsg may not be installed yet at startup — the first-run flow
        // installs it (and creates the DB) after this thread has already
        // started. Retry instead of giving up once, so that session isn't
        // permanently missing live updates and stdin-inject delivery.
        let conn = loop {
            match open_ro() {
                Ok(c) => break c,
                Err(_) => thread::sleep(Duration::from_millis(800)),
            }
        };
        let mut last_id: i64 = conn
            .query_row("SELECT COALESCE(MAX(id),0) FROM messages", [], |r| r.get(0))
            .unwrap_or(0);
        loop {
            let new_rows: Vec<Message> = {
                let mut stmt = match conn.prepare(
                    "SELECT id, team, from_agent, to_agent, body, created_at FROM messages \
                     WHERE id>?1 ORDER BY id",
                ) {
                    Ok(s) => s,
                    Err(_) => return,
                };
                let mapped = stmt.query_map(rusqlite::params![last_id], |r| {
                    Ok(Message {
                        id: r.get(0)?,
                        team: r.get(1)?,
                        from: r.get(2)?,
                        to: r.get(3)?,
                        body: r.get(4)?,
                        created_at: r.get(5)?,
                    })
                });
                match mapped {
                    Ok(it) => it.filter_map(|r| r.ok()).collect(),
                    Err(_) => Vec::new(),
                }
            };
            for m in new_rows {
                last_id = m.id.max(last_id);
                let _ = app.emit("agmsg-message", m);
            }
            thread::sleep(Duration::from_millis(800));
        }
    });
}
