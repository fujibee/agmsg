// agmsg data access — VIEW-ONLY reader over the agmsg installation.
//
// The desktop app reads agmsg's own SQLite DB and team config directly; it never
// mutates agmsg state here (sending still goes through agmsg's scripts). This
// powers the default "team room": the whole cross-agent conversation as a
// read-only feed, plus the left-hand member list.

use std::path::PathBuf;
use std::thread;
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter};

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
            types.push(AgentType { name, cli });
        }
    }
    types.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(types)
}

/// List team names (directories under teams/ that have a config.json).
#[tauri::command]
pub fn agmsg_teams() -> Result<Vec<String>, String> {
    let dir = agmsg_base().join("teams");
    let mut teams = Vec::new();
    let entries = std::fs::read_dir(&dir).map_err(|e| e.to_string())?;
    for entry in entries.flatten() {
        if entry.path().join("config.json").is_file() {
            if let Some(name) = entry.file_name().to_str() {
                teams.push(name.to_string());
            }
        }
    }
    teams.sort();
    Ok(teams)
}

/// Members of a team, read from teams/<team>/config.json.
#[tauri::command]
pub fn agmsg_members(team: String) -> Result<Vec<Member>, String> {
    let path = agmsg_base().join("teams").join(&team).join("config.json");
    let raw = std::fs::read_to_string(&path).map_err(|e| e.to_string())?;
    let cfg: serde_json::Value = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
    let mut members = Vec::new();
    if let Some(agents) = cfg.get("agents").and_then(|a| a.as_object()) {
        for (name, info) in agents {
            let regs = info.get("registrations").and_then(|r| r.as_array());
            let mut types: Vec<String> = regs
                .map(|arr| {
                    arr.iter()
                        .filter_map(|r| r.get("type").and_then(|t| t.as_str()).map(String::from))
                        .collect()
                })
                .unwrap_or_default();
            types.sort();
            types.dedup();
            let project = regs
                .and_then(|arr| arr.first())
                .and_then(|r| r.get("project"))
                .and_then(|p| p.as_str())
                .unwrap_or("")
                .to_string();
            members.push(Member { name: name.clone(), types, project });
        }
    }
    members.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(members)
}

/// Most recent `limit` messages for a team (oldest-first), for the team room.
#[tauri::command]
pub fn agmsg_messages(team: String, limit: Option<u32>) -> Result<Vec<Message>, String> {
    let limit = limit.unwrap_or(200);
    let conn = open_ro()?;
    let mut stmt = conn
        .prepare(
            "SELECT id, team, from_agent, to_agent, body, created_at FROM messages \
             WHERE team=?1 ORDER BY id DESC LIMIT ?2",
        )
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map(rusqlite::params![team, limit], |r| {
            Ok(Message {
                id: r.get(0)?,
                team: r.get(1)?,
                from: r.get(2)?,
                to: r.get(3)?,
                body: r.get(4)?,
                created_at: r.get(5)?,
            })
        })
        .map_err(|e| e.to_string())?;
    let mut out: Vec<Message> = rows.filter_map(|r| r.ok()).collect();
    out.reverse(); // oldest-first for display
    Ok(out)
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

/// Poll the DB for new rows and emit each as an `agmsg-message` event so the
/// team room updates live (and so spawned panes can be fed via stdin-inject).
pub fn start_watcher(app: AppHandle) {
    thread::spawn(move || {
        let conn = match open_ro() {
            Ok(c) => c,
            Err(_) => return,
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
