use serde::{Deserialize, Serialize};
use std::process::Command;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum SessionState {
    Active,
    Draining,
    Inactive,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum SessionResult {
    Pass,
    Deny,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum Presence {
    Present,
    Absent,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum FinalAck {
    Acknowledged,
    Pending,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorktreeInventory {
    pub status: Presence,
    pub dirty: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionInventory {
    pub registration: Presence,
    pub process: Presence,
    pub pane: Presence,
    pub worktree: WorktreeInventory,
    pub generation: Option<u64>,
    pub active_turn: Option<bool>,
    pub final_ack: Option<FinalAck>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManagedSessionResponse {
    pub schema_version: String,
    pub state: SessionState,
    pub result: SessionResult,
    pub reason_code: Option<String>,
    pub session_id: String,
    pub inventory: Option<SessionInventory>,
}

fn required_env(name: &str) -> Result<String, String> {
    std::env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("{name} is not configured"))
}

fn run_runtime(project: String, args: Vec<String>) -> Result<ManagedSessionResponse, String> {
    if project.trim().is_empty() {
        return Err("managed session project is empty".into());
    }

    let binary = required_env("AASES_SESSION_BIN")?;
    let runtime_root = required_env("AASES_SESSION_RUNTIME_ROOT")?;
    let mut command = Command::new(binary);
    command
        .args(args)
        .env("AASES_SESSION_RUNTIME_ROOT", runtime_root)
        .env("AASES_SESSION_PROJECT_ROOT", project);
    if let Some(path) = crate::imported_path() {
        command.env("PATH", path);
    }

    let output = command
        .output()
        .map_err(|error| format!("could not run AASES session runtime: {error}"))?;
    let response: ManagedSessionResponse = serde_json::from_slice(&output.stdout).map_err(|error| {
        let stderr = String::from_utf8_lossy(&output.stderr);
        format!("invalid AASES session response: {error}; stderr: {}", stderr.trim())
    })?;
    if response.schema_version != "1" {
        return Err(format!(
            "unsupported AASES session schema: {}",
            response.schema_version
        ));
    }
    Ok(response)
}

#[tauri::command]
pub fn managed_session_start(
    project: String,
    team: String,
    director_argv: Vec<String>,
) -> Result<ManagedSessionResponse, String> {
    if team.trim().is_empty() || director_argv.is_empty() {
        return Err("managed session start requires a team and director argv".into());
    }
    let mut args = vec!["start".into(), team, "--".into()];
    args.extend(director_argv);
    run_runtime(project, args)
}

#[tauri::command]
pub fn managed_session_status(project: String) -> Result<ManagedSessionResponse, String> {
    run_runtime(project, vec!["status".into()])
}

#[tauri::command]
pub fn managed_session_turn(
    project: String,
    signal: String,
    generation: u64,
) -> Result<ManagedSessionResponse, String> {
    if signal != "active" && signal != "idle" {
        return Err("managed session turn signal must be active or idle".into());
    }
    run_runtime(
        project,
        vec!["turn".into(), signal, generation.to_string()],
    )
}

#[tauri::command]
pub fn managed_session_ack(
    project: String,
    generation: u64,
) -> Result<ManagedSessionResponse, String> {
    run_runtime(project, vec!["ack".into(), generation.to_string()])
}

#[tauri::command]
pub fn managed_session_end(project: String) -> Result<ManagedSessionResponse, String> {
    run_runtime(project, vec!["end".into()])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_known_deny_as_a_typed_response() {
        let response: ManagedSessionResponse = serde_json::from_str(
            r#"{
                "schema_version":"1",
                "state":"ACTIVE",
                "result":"DENY",
                "reason_code":"ACTIVE_TURN",
                "session_id":"aases-session-123",
                "inventory":{
                    "registration":"PRESENT",
                    "process":"PRESENT",
                    "pane":"PRESENT",
                    "worktree":{"status":"PRESENT","dirty":false},
                    "generation":1,
                    "active_turn":true,
                    "final_ack":"PENDING"
                }
            }"#,
        )
        .unwrap();

        assert_eq!(response.result, SessionResult::Deny);
        assert_eq!(response.reason_code.as_deref(), Some("ACTIVE_TURN"));
        assert_eq!(response.inventory.unwrap().active_turn, Some(true));
    }

    #[test]
    fn rejects_an_inventory_with_unrecognized_fields() {
        let parsed = serde_json::from_str::<ManagedSessionResponse>(
            r#"{
                "schema_version":"1",
                "state":"INACTIVE",
                "result":"PASS",
                "reason_code":null,
                "session_id":"aases-session-123",
                "inventory":{
                    "registration":"ABSENT",
                    "process":"ABSENT",
                    "pane":"ABSENT",
                    "worktree":{"status":"ABSENT","dirty":null},
                    "generation":null,
                    "active_turn":null,
                    "final_ack":null,
                    "unexpected":true
                }
            }"#,
        );

        assert!(parsed.is_err());
    }
}
