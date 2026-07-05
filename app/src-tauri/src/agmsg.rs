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

/// Resolves the user's home directory across platforms. HOME is a POSIX
/// convention — a native Windows GUI process (launched from the Start Menu
/// or a desktop shortcut, not a shell) doesn't have it set at all, silently
/// falling back to "." and resolving every agmsg path relative to whatever
/// the process's cwd happens to be — confirmed on real Windows hardware
/// (agmsg_is_installed()/run_script() both silently checking/using a
/// "./.agents/skills/agmsg" relative to nothing meaningful, sometimes
/// matching a stray leftover directory from an earlier broken run instead
/// of erroring outright). USERPROFILE is Windows' own always-set
/// equivalent, set by the OS itself regardless of what launched the process.
fn home_dir_string() -> Option<String> {
    std::env::var("HOME").ok().or_else(|| std::env::var("USERPROFILE").ok())
}

/// Base dir of the agmsg install (skill layout: db/, teams/, scripts/, ...).
///
/// `AGMSG_APP_BASE`, when set to a non-empty path, overrides the derived
/// location. This is the command layer's injection point — the test harness
/// points it at a temp dir of fake `scripts/*.sh` (mirrors resolve_bash's
/// `AGMSG_APP_BASH` override). In normal operation it is unset and the base is
/// `<home>/.agents/skills/agmsg`.
fn agmsg_base() -> PathBuf {
    if let Ok(over) = std::env::var("AGMSG_APP_BASE") {
        if !over.is_empty() {
            return PathBuf::from(over);
        }
    }
    let home = home_dir_string().unwrap_or_else(|| ".".into());
    PathBuf::from(home).join(".agents/skills/agmsg")
}

/// Converts to the full POSIX form Git Bash/MSYS resolve internally
/// ("C:/Users/name" -> "/c/Users/name"), matching `cygpath -u` — one step
/// further than agmsg-core's own scripts/lib/storage.sh convention
/// (`cygpath -m`'s mixed "C:/Users/..." form). Belt-and-suspenders: the
/// actual bug this was written for turned out to be resolve_bash() picking
/// up the wrong bash.exe entirely (see there), not the path format, but a
/// real Git Bash accepts both forms and going all the way removes any doubt.
/// A standalone string transform (rather than inline in bash_path below) so
/// it's testable on any host platform, not just Windows — its only
/// non-test caller is behind a Windows-only cfg, hence the dead_code
/// allowance on other platforms.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub(crate) fn to_bash_slashes(s: &str) -> String {
    let s = s.strip_prefix(r"\\?\").unwrap_or(s);
    let s = s.replace('\\', "/");
    let bytes = s.as_bytes();
    if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        format!("/{}{}", (bytes[0] as char).to_ascii_lowercase(), &s[2..])
    } else {
        s
    }
}

/// Converts an MSYS/Git-Bash path ("/c/Users/name") back to native Windows
/// form ("C:\\Users\\name") — the inverse of to_bash_slashes. Team
/// registrations on Windows store `project` in MSYS form (every skill script
/// keys identity on Git Bash's $(pwd)), but that string is worthless to a
/// native Win32 API: handed to create_dir_all or a PTY's cwd, Windows resolves
/// the rootless "/c/Users/..." against the current drive and yields the phantom
/// "C:\\c\\Users\\..." — a genuinely different directory, silently created and
/// spawned into, which splits the app-user and its agents into separate teams
/// whose messages never meet (see issue #315). Only the leading "/<drive>"
/// segment is rewritten; anything already native ("C:\\..." / "C:/...") or
/// relative passes through untouched. A standalone string transform so it's
/// testable on any host — its non-test callers (agmsg_join, pty::pty_spawn) are
/// behind Windows-only cfgs, hence the dead_code allowance elsewhere.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
pub(crate) fn msys_to_native(s: &str) -> String {
    let bytes = s.as_bytes();
    // "/c" or "/c/rest" -> drive letter, but not "/cygdrive/..." or "/home/..."
    // (a multi-char first segment is a real POSIX root, not a drive).
    if bytes.len() >= 2
        && bytes[0] == b'/'
        && bytes[1].is_ascii_alphabetic()
        && (bytes.len() == 2 || bytes[2] == b'/')
    {
        let drive = (bytes[1] as char).to_ascii_uppercase();
        let rest = s[2..].replace('/', "\\");
        format!("{drive}:{rest}")
    } else {
        s.to_string()
    }
}

/// Converts a native path into a form Git Bash on Windows accepts as an
/// argument. Without this, a raw Windows path handed to bash.exe has its
/// backslashes silently eaten by MSYS's argv parsing (backslash is an
/// escape character there) — "C:\Users\x\y.sh" arrives as "C:Usersxy.sh" and
/// bash reports "No such file or directory". Also strips the `\\?\`
/// extended-length prefix Path::canonicalize / Tauri's resource_dir() can
/// return, which bash doesn't understand either. Every path this app hands
/// to bash (install.sh, agmsg-core scripts, ...) must go through this —
/// found in review after first-run install and every agmsg-core script call
/// (join.sh, send.sh, ...) failed identically on real Windows hardware.
#[cfg(target_os = "windows")]
fn bash_path(p: &std::path::Path) -> String {
    to_bash_slashes(&p.to_string_lossy())
}

#[cfg(not(target_os = "windows"))]
fn bash_path(p: &std::path::Path) -> String {
    p.to_string_lossy().into_owned()
}

/// Resolves the actual Git Bash executable rather than trusting PATH to
/// hand back Git Bash for a bare "bash" — Windows 11 ships a WSL bash.exe
/// stub at %LOCALAPPDATA%\Microsoft\WindowsApps\bash.exe that PATH lookup
/// can resolve to ahead of Git Bash, and WSL's bash resolves Windows paths
/// completely differently ("C:/Users/..." doesn't exist there, only
/// "/mnt/c/Users/..."), so every bash invocation failed with a spurious "No
/// such file or directory" despite the target genuinely existing and being
/// runnable via Git Bash's own file association — confirmed on real Windows
/// hardware. Resolution order: an env var override, then deriving from
/// `where git`'s own install root, then the two standard install locations.
#[cfg(target_os = "windows")]
fn resolve_bash() -> Result<PathBuf, String> {
    if let Ok(over) = std::env::var("AGMSG_APP_BASH") {
        if !over.is_empty() && PathBuf::from(&over).is_file() {
            return Ok(PathBuf::from(over));
        }
    }

    let mut where_cmd = std::process::Command::new("where");
    where_cmd.arg("git");
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        where_cmd.creation_flags(CREATE_NO_WINDOW);
    }
    if let Ok(output) = where_cmd.output() {
        if output.status.success() {
            if let Some(first_line) = String::from_utf8_lossy(&output.stdout).lines().next() {
                // git.exe sits at <root>\cmd\git.exe or <root>\bin\git.exe;
                // bash.exe is always at <root>\bin\bash.exe either way.
                if let Some(root) = PathBuf::from(first_line.trim()).parent().and_then(|p| p.parent()) {
                    let candidate = root.join("bin").join("bash.exe");
                    if candidate.is_file() {
                        return Ok(candidate);
                    }
                }
            }
        }
    }

    for candidate in [r"C:\Program Files\Git\bin\bash.exe", r"C:\Program Files (x86)\Git\bin\bash.exe"] {
        let p = PathBuf::from(candidate);
        if p.is_file() {
            return Ok(p);
        }
    }

    Err("Git for Windows (Git Bash) wasn't found. Install it from https://git-scm.com/download/win, then restart the app.".into())
}

#[cfg(not(target_os = "windows"))]
fn resolve_bash() -> Result<PathBuf, String> {
    Ok(PathBuf::from("bash"))
}

/// A bash Command pre-configured for running agmsg-core scripts: resolved
/// via resolve_bash() (not a bare "bash" — see there), --noprofile --norc
/// so it doesn't spend a few seconds sourcing the user's shell profile on
/// every single call (these scripts don't depend on it, on any platform),
/// and on Windows CREATE_NO_WINDOW so spawning it doesn't flash a console
/// window on screen for every command — GUI processes get one by default.
/// Callers add the script path and its args on top of what this returns.
fn bash_command() -> Result<std::process::Command, String> {
    let mut cmd = std::process::Command::new(resolve_bash()?);
    cmd.args(["--noprofile", "--norc"]);
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    // Explicitly attach the PATH import_login_shell_path() resolved at
    // startup (lib.rs), same reasoning as pty::pty_spawn: don't rely on this
    // child implicitly inheriting the process's own (mutated) environment.
    // No-op on Windows / if the import never ran or failed.
    if let Some(path) = crate::imported_path() {
        cmd.env("PATH", path);
    }
    Ok(cmd)
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
    let home = home_dir_string().unwrap_or_else(|| ".".into());
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
    let output = bash_command()?
        .arg(bash_path(&install_sh))
        .output()
        .map_err(|e| e.to_string())?;
    if output.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).into_owned())
    }
}

/// The AGMSG_CORE_REF this build was compiled against (e.g. "v1.1.5") — the
/// same value bundle-core.sh reads at build time, embedded here so the
/// running app can compare against it without shelling out to git.
const PINNED_CORE_REF: &str = include_str!("../../AGMSG_CORE_REF");

/// Parses a leading "X.Y.Z" out of a version string, ignoring anything after
/// (git-describe suffixes like "-3-gabc1234", "-dirty", or a leading "v").
/// None for anything that doesn't start with a clean X.Y.Z — including the
/// literal "unknown" install.sh writes when it can't determine a version.
fn parse_semver(s: &str) -> Option<(u64, u64, u64)> {
    let s = s.trim().trim_start_matches('v');
    let core = s.split(['-', '+']).next().unwrap_or(s);
    let mut parts = core.split('.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let patch = parts.next()?.parse().ok()?;
    Some((major, minor, patch))
}

#[derive(Serialize)]
pub struct CoreVersionStatus {
    installed: Option<String>,
    pinned: String,
    outdated: bool,
}

/// Compares the installed agmsg's VERSION file against the version bundled
/// into this app build. An existing install doesn't go through agmsg_install
/// (that only fires when nothing is installed at all), so an installed
/// agmsg predating a core feature the app needs (e.g. v0.1.0 shipping before
/// agmsg-app's type registration existed) would otherwise fail silently the
/// first time that feature is used. A missing/unparseable VERSION (very old
/// installs, or the literal "unknown") counts as outdated too.
#[tauri::command]
pub fn agmsg_core_version_status() -> CoreVersionStatus {
    let pinned = PINNED_CORE_REF.trim().trim_start_matches('v').to_string();
    let installed = std::fs::read_to_string(agmsg_base().join("VERSION"))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let outdated = match (&installed, parse_semver(&pinned)) {
        (Some(v), Some(pinned_v)) => match parse_semver(v) {
            Some(installed_v) => installed_v < pinned_v,
            None => true,
        },
        (None, _) => true,
        (_, None) => false,
    };

    CoreVersionStatus { installed, pinned, outdated }
}

/// Updates an existing agmsg install to the version bundled into this app,
/// via the bundled install.sh's `--update` flag (preserves db/teams). Unlike
/// agmsg_install, this touches an environment the user already has — it's
/// only ever invoked from an explicit "Update" click, never automatically.
///
/// `--cmd agmsg` is required, not optional: without it, `install.sh --update`
/// updates whichever skill under ~/.agents/skills/* it finds first, which
/// isn't necessarily the one agmsg_base() (and the version check above) is
/// hardcoded to — on a machine with more than one agmsg-like skill install,
/// the wrong one would get updated while ~/.agents/skills/agmsg stays stale
/// and the outdated banner never clears. Found in review.
#[tauri::command]
pub fn agmsg_update_core(app: AppHandle) -> Result<(), String> {
    let install_sh = app
        .path()
        .resource_dir()
        .map_err(|e| e.to_string())?
        .join("agmsg-core")
        .join("install.sh");
    let output = bash_command()?
        .arg(bash_path(&install_sh))
        .args(["--cmd", "agmsg", "--update"])
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
    let output = bash_command()?
        .arg(bash_path(&script))
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
    let home = home_dir_string().ok_or("Couldn't resolve the home directory (HOME/USERPROFILE unset)")?;
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
    // The caller can hand us an MSYS-form path (/c/Users/...) read back from an
    // existing registration (e.g. adding an agent into the app-user's team). On
    // Windows create_dir_all needs the native form, or it silently builds the
    // phantom C:\c\Users\... tree the spawned agent then splits into (#315).
    // No-op for a path that's already native. create_dir_all takes the native
    // form; bash_path is only for the value that crosses into a bash argument
    // below (join.sh's $4).
    #[cfg(target_os = "windows")]
    let project = msys_to_native(&project);
    std::fs::create_dir_all(&project).map_err(|e| e.to_string())?;
    let project = bash_path(std::path::Path::new(&project));
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
    let project = bash_path(std::path::Path::new(&project));
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

#[cfg(test)]
mod tests {
    use super::{agmsg_base, msys_to_native, parse_semver, run_script, to_bash_slashes};
    use serial_test::serial;
    use std::io::Write;

    #[test]
    fn strips_verbatim_prefix_and_converts_to_posix() {
        // The exact shape resource_dir()/canonicalize() produced on the
        // Windows hardware where this was found.
        assert_eq!(
            to_bash_slashes(r"\\?\C:\Users\koichi\AppData\Local\agmsg\agmsg-core\install.sh"),
            "/c/Users/koichi/AppData/Local/agmsg/agmsg-core/install.sh",
        );
    }

    #[test]
    fn converts_mixed_slash_paths_to_posix() {
        // agmsg_base() joins a literal ".agents/skills/agmsg" (forward
        // slashes) onto a platform-joined home dir (backslashes on
        // Windows) — the real path run_script() builds is a mix of both.
        assert_eq!(
            to_bash_slashes(r"C:\Users\koichi\.agents/skills/agmsg\scripts\join.sh"),
            "/c/Users/koichi/.agents/skills/agmsg/scripts/join.sh",
        );
    }

    #[test]
    fn is_a_no_op_on_an_already_posix_style_path() {
        assert_eq!(to_bash_slashes("/Users/koichi/.agents/skills/agmsg/scripts/join.sh"),
            "/Users/koichi/.agents/skills/agmsg/scripts/join.sh");
    }

    #[test]
    fn converts_a_project_dir_argument_to_posix() {
        // Not just the script path — join.sh's $4 and delivery.sh's $3 are
        // project directories that cross the same bash argv boundary.
        assert_eq!(
            to_bash_slashes(r"C:\Users\koichi\agmsg-agents\alice"),
            "/c/Users/koichi/agmsg-agents/alice",
        );
    }

    #[test]
    fn lowercases_the_drive_letter() {
        assert_eq!(to_bash_slashes(r"D:\work\x.sh"), "/d/work/x.sh");
    }

    #[test]
    fn msys_to_native_rewrites_the_drive_segment() {
        // The exact registration shape from issue #315: an MSYS project path
        // must become a native Windows path before it reaches create_dir_all or
        // a PTY cwd, or Windows builds/spawns the phantom C:\c\Users\... dir.
        assert_eq!(
            msys_to_native("/c/Users/kei40/agmsg-agents/Chikamichi"),
            r"C:\Users\kei40\agmsg-agents\Chikamichi",
        );
    }

    #[test]
    fn msys_to_native_uppercases_and_handles_other_drives() {
        assert_eq!(msys_to_native("/d/work/x"), r"D:\work\x");
        assert_eq!(msys_to_native("/c"), "C:");
    }

    #[test]
    fn msys_to_native_is_a_no_op_on_native_and_posix_root_paths() {
        // Already-native paths (either slash style) and genuine multi-segment
        // POSIX roots must pass through untouched — only "/<drive>" is a drive.
        assert_eq!(msys_to_native(r"C:\Users\kei40\x"), r"C:\Users\kei40\x");
        assert_eq!(msys_to_native("C:/Users/kei40/x"), "C:/Users/kei40/x");
        assert_eq!(msys_to_native("/Users/koichi/x"), "/Users/koichi/x");
        assert_eq!(msys_to_native("/home/koichi/x"), "/home/koichi/x");
        assert_eq!(msys_to_native("/cygdrive/c/x"), "/cygdrive/c/x");
    }

    #[test]
    fn msys_to_native_round_trips_with_to_bash_slashes() {
        // The two are inverses across the drive boundary; storage (MSYS) and
        // native (create_dir_all/cwd) must agree so the agent's $(pwd) matches.
        let native = r"C:\Users\kei40\agmsg-agents\Chikamichi";
        assert_eq!(msys_to_native(&to_bash_slashes(native)), native);
    }

    #[test]
    fn parses_clean_semver() {
        assert_eq!(parse_semver("1.1.4"), Some((1, 1, 4)));
        assert_eq!(parse_semver("v1.1.5"), Some((1, 1, 5)));
    }

    #[test]
    fn strips_git_describe_and_prerelease_suffixes() {
        assert_eq!(parse_semver("1.1.4-3-gabc1234"), Some((1, 1, 4)));
        assert_eq!(parse_semver("1.1.4-dirty"), Some((1, 1, 4)));
        assert_eq!(parse_semver("1.1.4+build.5"), Some((1, 1, 4)));
    }

    #[test]
    fn rejects_unparseable_versions() {
        assert_eq!(parse_semver("unknown"), None);
        assert_eq!(parse_semver(""), None);
        assert_eq!(parse_semver("1.1"), None);
    }

    #[test]
    fn compares_by_numeric_value_not_string_order() {
        // String comparison would get "1.1.10" < "1.1.9" wrong; numeric must not.
        assert!(parse_semver("1.1.10") > parse_semver("1.1.9"));
        assert!(parse_semver("1.1.4") < parse_semver("1.2.0"));
        assert!(parse_semver("1.1.4") < parse_semver("2.0.0"));
    }

    // --- command-layer harness (fake agmsg-core scripts) ---
    //
    // run_script() resolves <base>/scripts/<name>, runs it through bash, and maps
    // stdout→Ok / stderr→Err. Pointing AGMSG_APP_BASE at a temp dir of fake
    // scripts lets us exercise that whole path (the 0.1.1→0.1.3 regressions all
    // lived here) without a real agmsg install. AGMSG_APP_BASE is process-global,
    // so any test that reads it is #[serial]; add #[serial] to future ones too.
    // The run_script cases are skipped on Windows: resolve_bash there is Git-Bash
    // -specific and is covered by the windows-latest app-test CI job instead.

    /// Restores an env var to its prior value (or unsets it) on drop, so a
    /// panicking test can't leak an override into the next one — the manual
    /// remove_var-at-end approach loses that on unwind.
    struct EnvGuard {
        key: &'static str,
        prev: Option<String>,
    }
    impl EnvGuard {
        fn set(key: &'static str, val: &str) -> Self {
            let prev = std::env::var(key).ok();
            std::env::set_var(key, val);
            EnvGuard { key, prev }
        }
    }
    impl Drop for EnvGuard {
        fn drop(&mut self) {
            match &self.prev {
                Some(v) => std::env::set_var(self.key, v),
                None => std::env::remove_var(self.key),
            }
        }
    }

    /// A temp install base whose `scripts/` holds the given `(name, body)` fakes,
    /// with AGMSG_APP_BASE pointed at it. Bind it for the test's duration; on drop
    /// the temp dir is removed and AGMSG_APP_BASE is restored.
    struct FakeBase {
        _dir: tempfile::TempDir,
        _env: EnvGuard,
    }
    fn fake_base(scripts: &[(&str, &str)]) -> FakeBase {
        let dir = tempfile::tempdir().expect("tempdir");
        let sdir = dir.path().join("scripts");
        std::fs::create_dir_all(&sdir).unwrap();
        for (name, body) in scripts {
            let mut f = std::fs::File::create(sdir.join(name)).unwrap();
            writeln!(f, "#!/usr/bin/env bash").unwrap();
            f.write_all(body.as_bytes()).unwrap();
        }
        let env = EnvGuard::set("AGMSG_APP_BASE", &dir.path().to_string_lossy());
        FakeBase { _dir: dir, _env: env }
    }

    #[test]
    #[serial]
    fn agmsg_base_honors_the_env_override() {
        let dir = tempfile::tempdir().unwrap();
        let _env = EnvGuard::set("AGMSG_APP_BASE", &dir.path().to_string_lossy());
        assert_eq!(agmsg_base(), dir.path());
    }

    #[test]
    #[serial]
    fn agmsg_base_falls_back_when_override_is_empty() {
        let _env = EnvGuard::set("AGMSG_APP_BASE", "");
        assert!(agmsg_base().ends_with(".agents/skills/agmsg"));
    }

    #[test]
    #[serial]
    #[cfg(not(target_os = "windows"))]
    fn run_script_returns_stdout_on_success() {
        let _base = fake_base(&[("ok.sh", "echo hello-from-fake")]);
        let out = run_script("ok.sh", &[]).expect("should succeed");
        assert_eq!(out.trim(), "hello-from-fake");
    }

    #[test]
    #[serial]
    #[cfg(not(target_os = "windows"))]
    fn run_script_returns_stderr_as_err_on_failure() {
        let _base = fake_base(&[("boom.sh", "echo the-error >&2; exit 1")]);
        let err = run_script("boom.sh", &[]).unwrap_err();
        assert!(err.contains("the-error"), "stderr not surfaced: {err:?}");
    }

    #[test]
    #[serial]
    #[cfg(not(target_os = "windows"))]
    fn run_script_passes_arguments_through_in_order() {
        let _base = fake_base(&[("args.sh", "printf '%s\\n' \"$@\"")]);
        let out = run_script("args.sh", &["a", "b c", "d"]).unwrap();
        assert_eq!(out.lines().collect::<Vec<_>>(), ["a", "b c", "d"]);
    }

    #[test]
    #[serial]
    #[cfg(not(target_os = "windows"))]
    fn run_script_errors_when_the_script_is_missing() {
        let _base = fake_base(&[]);
        assert!(run_script("nope.sh", &[]).is_err());
    }

    // --- #315 Windows spawn-path regression (runs on the windows-latest job) ---

    /// The core #315 guarantee, independent of bash: create_dir_all runs before
    /// run_script and must build the NATIVE dir, not the phantom C:\c\Users\...
    /// Windows would derive from an unconverted MSYS project path. The join.sh
    /// result is ignored so a bash hiccup can't mask the create_dir_all check.
    #[test]
    #[serial]
    #[cfg(target_os = "windows")]
    fn agmsg_join_creates_the_native_dir_not_the_phantom() {
        let _base = fake_base(&[("join.sh", "exit 0")]);
        let tmp = tempfile::tempdir().unwrap();
        let native_proj = tmp.path().join("agmsg-agents").join("alice");
        // MSYS form, as a Windows registration stores it.
        let msys_proj = to_bash_slashes(&native_proj.to_string_lossy());
        let _ = super::agmsg_join("t".into(), "alice".into(), "claude-code".into(), msys_proj);
        assert!(
            native_proj.is_dir(),
            "agmsg_join must create the native dir, not a phantom C:\\c\\Users\\... tree",
        );
    }

    /// End to end through the fake join.sh: the native dir is created AND join.sh
    /// receives the project ($4) in MSYS form, so storage/identity keys stay MSYS
    /// while the filesystem side is native.
    #[test]
    #[serial]
    #[cfg(target_os = "windows")]
    fn agmsg_join_passes_msys_form_to_join_sh() {
        let dir = tempfile::tempdir().unwrap();
        // Forward-slash base so both Rust (agmsg_base) and Git Bash ($AGMSG_APP_BASE
        // expansion / redirect) accept it — a native backslash path gets mangled by
        // MSYS argv/redirect handling.
        let base = dir.path().to_string_lossy().replace('\\', "/");
        let sdir = dir.path().join("scripts");
        std::fs::create_dir_all(&sdir).unwrap();
        std::fs::write(
            sdir.join("join.sh"),
            "#!/usr/bin/env bash\nprintf '%s' \"$4\" > \"$AGMSG_APP_BASE/arg4.txt\"\n",
        )
        .unwrap();
        let _env = EnvGuard::set("AGMSG_APP_BASE", &base);

        let native_proj = dir.path().join("agmsg-agents").join("bob");
        let msys_proj = to_bash_slashes(&native_proj.to_string_lossy());
        super::agmsg_join("t".into(), "bob".into(), "claude-code".into(), msys_proj.clone())
            .expect("join should succeed");

        assert!(native_proj.is_dir(), "native project dir should be created");
        let got = std::fs::read_to_string(dir.path().join("arg4.txt")).unwrap();
        assert_eq!(got, msys_proj, "join.sh $4 should be the MSYS form");
    }
}
