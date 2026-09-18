// PTY session manager — the terminal-embedded core of the agmsg desktop app.
//
// The app OWNS each spawned agent's pseudo-terminal: it spawns the agent in a
// real PTY (so full TUIs render), streams output to the webview (xterm.js),
// forwards keystrokes back, and — the strategic bit — can INJECT an agmsg
// message straight into the agent's stdin. That injection is agent-agnostic:
// it works for any interactive CLI because it operates at the PTY layer, not
// via a per-agent bridge. Proven in poc-inject/.
//
// pty_inject used to wait for the PTY to go quiet before writing, on the
// theory that writing mid-generation could corrupt an in-flight response.
// Real-world testing (see conversation history) showed the opposite problem
// dominates: claude Code's multi-session launcher UI redraws a spinner
// nonstop even when otherwise idle, so the quiet-period never arrived and
// injection always hit the forced-timeout path — mid-spin, where the
// trailing Enter wasn't reliably registered as "submit". Every agent type
// tested handles a fresh task line as a new queued item regardless of
// whatever else is in flight, so there's nothing to wait for: inject writes
// immediately.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use base64::Engine;
use portable_pty::{CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};

use crate::agent_state::{DetectionTracker, PaneState, TailBuffer, DETECTION_INTERVAL};

/// One live PTY-backed agent terminal.
struct PtySession {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    /// Child process id, so closing a pane can actually terminate the agent
    /// (and let its SessionEnd hook release the agmsg actas lock).
    pid: Option<u32>,
    tail: Arc<Mutex<TailBuffer>>,
    detection: Arc<Mutex<DetectionTracker>>,
    /// Serializes concurrent pty_inject calls into this pane: two messages
    /// arriving close together must not interleave their text/Enter writes
    /// (text-A text-B Enter Enter submits a mangled line, then an Enter on
    /// an empty composer).
    inject_lock: Arc<Mutex<()>>,
}

/// All live sessions, keyed by a frontend-chosen id (e.g. "claude-1").
/// `Arc` so the idle-wait injector thread can share the map without unsafe.
#[derive(Default)]
pub struct PtyManager {
    sessions: Arc<Mutex<HashMap<String, PtySession>>>,
}

impl PtyManager {
    pub fn start_detection_tick(&self, app: AppHandle) {
        let sessions = Arc::clone(&self.sessions);
        thread::spawn(move || loop {
            thread::sleep(DETECTION_INTERVAL);
            let snapshots: Vec<(String, Arc<Mutex<TailBuffer>>, Arc<Mutex<DetectionTracker>>)> = sessions
                .lock()
                .unwrap()
                .iter()
                .map(|(id, session)| {
                    (id.clone(), Arc::clone(&session.tail), Arc::clone(&session.detection))
                })
                .collect();
            let now = std::time::Instant::now();
            for (id, tail, detection) in snapshots {
                let tail = tail.lock().unwrap().detection_tail();
                if let Some(state) = detection.lock().unwrap().observe(&tail, now) {
                    let _ = app.emit("agent-state", AgentStateEvent { id, state });
                }
            }
        });
    }
}

#[derive(Clone, Serialize)]
struct AgentStateEvent {
    id: String,
    state: PaneState,
}

#[derive(Clone, Serialize)]
struct OutputEvent {
    id: String,
    /// base64 of the raw PTY bytes (keeps multibyte/escape sequences intact).
    b64: String,
}

#[derive(Clone, Serialize)]
struct ExitEvent {
    id: String,
}

/// Windows-only: turn a spawn cwd from a team registration (MSYS form,
/// /c/Users/...) into a native path, and refuse it if it isn't a real directory.
/// CreateProcessW resolves a rootless /c/Users/... against the current drive ->
/// the phantom C:\c\Users\... dir; the agent then boots there, its own $(pwd)
/// matches no registration, and it splits into a phantom team whose messages
/// never reach the app (#315). Erroring (instead of booting into a mangled dir)
/// surfaces in the terminal pane via the frontend's failed-spawn handler. Split
/// out from pty_spawn so it's unit-testable without a Tauri AppHandle.
#[cfg(target_os = "windows")]
fn resolve_windows_cwd(dir: &str) -> Result<String, String> {
    let native = crate::agmsg::msys_to_native(dir);
    if !std::path::Path::new(&native).is_dir() {
        return Err(format!(
            "agent working directory doesn't exist: {native} (from registration \
             path {dir}). Re-add the agent so its project points at a real folder."
        ));
    }
    Ok(native)
}

/// On Windows a bare agent CLI name can't be handed to CreateProcessW directly:
/// npm installs an extensionless POSIX shim ("claude") next to "claude.cmd", and
/// portable-pty's search_path prefers the exact extensionless match — so the
/// shell script reaches CreateProcessW and fails with os error 193 ("not a valid
/// Win32 application"), issues #314 / #313 (claude leg). A Store-installed
/// "codex" is worse: a WindowsApps execution alias (a 0-byte reparse point) that
/// only resolves when invoked *by name* through a shell, so a direct full-path
/// spawn fails os error 2 — #313 (codex leg). Routing the launch through
/// `cmd.exe /d /c <name> <args>` hands name resolution to cmd, which honors
/// PATHEXT and execution aliases and fixes both.
///
/// Quoting: cmd only strips the outer quote pair when the command string
/// *begins* with a quote. The agent name has no spaces so portable-pty leaves it
/// unquoted, the string begins with the name's first letter, cmd's strip rule
/// never fires — and a space-bearing arg like "/agmsg actas Ami" survives as a
/// single token addressed to the agent. `/d` skips any user AutoRun so a stray
/// registry command can't corrupt the launch. Standalone (not inlined) so it's
/// unit-testable on any host; its only caller is behind a Windows cfg, hence the
/// dead_code allowance elsewhere.
#[cfg_attr(not(target_os = "windows"), allow(dead_code))]
fn windows_shell_argv(cmd: &str, args: &[String]) -> Vec<String> {
    let mut argv = vec!["/d".to_string(), "/c".to_string(), cmd.to_string()];
    argv.extend(args.iter().cloned());
    argv
}

/// Spawn `cmd args` in a fresh PTY and stream its output to the webview as
/// `pty-output` events. Stores the session under `id`.
#[tauri::command]
pub fn pty_spawn(
    app: AppHandle,
    manager: State<'_, PtyManager>,
    id: String,
    cmd: String,
    args: Vec<String>,
    cwd: Option<String>,
    rows: Option<u16>,
    cols: Option<u16>,
) -> Result<(), String> {
    let pty_system = portable_pty::native_pty_system();
    let size = PtySize {
        rows: rows.unwrap_or(30),
        cols: cols.unwrap_or(100),
        pixel_width: 0,
        pixel_height: 0,
    };
    let pair = pty_system.openpty(size).map_err(|e| e.to_string())?;

    // On Windows, launch the agent through cmd.exe so PATHEXT / execution-alias
    // resolution happens (see windows_shell_argv); elsewhere spawn it directly.
    #[cfg(target_os = "windows")]
    let mut builder = {
        let comspec = std::env::var("ComSpec").unwrap_or_else(|_| "cmd.exe".to_string());
        let mut b = CommandBuilder::new(comspec);
        for a in windows_shell_argv(&cmd, &args) {
            b.arg(a);
        }
        b
    };
    #[cfg(not(target_os = "windows"))]
    let mut builder = {
        let mut b = CommandBuilder::new(&cmd);
        for a in &args {
            b.arg(a);
        }
        b
    };
    if let Some(dir) = &cwd {
        #[cfg(target_os = "windows")]
        builder.cwd(resolve_windows_cwd(dir)?);
        #[cfg(not(target_os = "windows"))]
        builder.cwd(dir);
    }
    builder.env("TERM", "xterm-256color");
    // Explicitly set PATH from what import_login_shell_path() resolved at
    // startup (lib.rs) rather than relying on this child implicitly
    // inheriting the process's own (mutated) environment — a real
    // Finder-launch hardware gate still failed to find `claude`/`codex` even
    // after that process-level import, so this removes any dependence on
    // environment-inheritance behavior we can't fully control. No-op (falls
    // back to whatever this process's own PATH already is) if the import
    // never ran or failed, e.g. on Windows or if the login shell couldn't be
    // queried.
    if let Some(path) = crate::imported_path() {
        builder.env("PATH", path);
    }

    let mut child = pair.slave.spawn_command(builder).map_err(|e| e.to_string())?;
    drop(pair.slave);
    let pid = child.process_id();

    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
    let tail = Arc::new(Mutex::new(TailBuffer::default()));
    let agent_type = std::path::Path::new(&cmd)
        .file_stem()
        .and_then(|name| name.to_str())
        .unwrap_or(&cmd)
        .to_ascii_lowercase();
    let detection = Arc::new(Mutex::new(DetectionTracker::new(agent_type)));

    // Reader thread: stream output to the webview.
    {
        let app = app.clone();
        let id = id.clone();
        let reader_tail = Arc::clone(&tail);
        thread::spawn(move || {
            let mut buf = [0u8; 8192];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        reader_tail.lock().unwrap().push(&buf[..n]);
                        let b64 = base64::engine::general_purpose::STANDARD.encode(&buf[..n]);
                        let _ = app.emit("pty-output", OutputEvent { id: id.clone(), b64 });
                    }
                    Err(_) => break,
                }
            }
            // Reap the child and notify the webview the pane is gone.
            let _ = child.wait();
            let _ = app.emit("pty-exit", ExitEvent { id: id.clone() });
        });
    }

    manager.sessions.lock().unwrap().insert(
        id,
        PtySession {
            master: pair.master,
            writer,
            pid,
            tail,
            detection,
            inject_lock: Arc::new(Mutex::new(())),
        },
    );
    Ok(())
}

#[tauri::command]
pub fn agent_state(manager: State<'_, PtyManager>, id: String) -> Result<PaneState, String> {
    let sessions = manager.sessions.lock().unwrap();
    let session = sessions.get(&id).ok_or("no such pty session")?;
    let state = session.detection.lock().unwrap().state();
    Ok(state)
}

/// Forward keystrokes/data from xterm.js into the PTY.
#[tauri::command]
pub fn pty_write(manager: State<'_, PtyManager>, id: String, data: String) -> Result<(), String> {
    let mut sessions = manager.sessions.lock().unwrap();
    let s = sessions.get_mut(&id).ok_or("no such pty session")?;
    s.writer.write_all(data.as_bytes()).map_err(|e| e.to_string())?;
    s.writer.flush().map_err(|e| e.to_string())
}

/// Resize the PTY when the xterm viewport changes.
#[tauri::command]
pub fn pty_resize(
    manager: State<'_, PtyManager>,
    id: String,
    rows: u16,
    cols: u16,
) -> Result<(), String> {
    let sessions = manager.sessions.lock().unwrap();
    let s = sessions.get(&id).ok_or("no such pty session")?;
    s.master
        .resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
        .map_err(|e| e.to_string())
}

/// Close a pane: actually terminate the agent so it exits — its SessionEnd hook
/// then releases the agmsg actas lock (and even if the hook doesn't run, a dead
/// owner makes the lock stale and reclaimable, so the role can be re-spawned).
/// SIGHUP first (like closing a terminal, so a well-behaved CLI runs its
/// shutdown hooks), then SIGKILL after a grace period if it's still alive. The
/// reader thread reaps the child and emits pty-exit when it goes.
#[tauri::command]
pub fn pty_kill(manager: State<'_, PtyManager>, id: String) -> Result<(), String> {
    let pid = manager.sessions.lock().unwrap().remove(&id).and_then(|s| s.pid);
    if let Some(pid) = pid {
        let pid_s = pid.to_string();
        let _ = std::process::Command::new("kill").arg("-HUP").arg(&pid_s).status();
        // Fallback: force-kill if it hasn't exited after a grace period.
        thread::spawn(move || {
            thread::sleep(Duration::from_secs(4));
            let _ = std::process::Command::new("kill").arg("-KILL").arg(&pid_s).status();
        });
    }
    Ok(())
}

/// What the post-inject verify loop should do given the pane's detected
/// state. Pure decision so it's unit-testable without a PTY.
///
/// Verification is by STATE TRANSITION, not by screen content, on purpose.
/// An earlier revision of this fix looked for the injected text still
/// sitting in the composer (a screen-scrape needle), and real captures
/// killed it twice over: codex's redraw path drops non-ASCII characters
/// (the kickoff's own em dash), and on Windows its title-escape churn
/// (#383) floods the tail buffer with escape-only frames, aging the echo
/// out of any byte-capped window within seconds — the stuck text was
/// invisible to the buffer while plainly on screen. The state signal has
/// neither problem: a submission always drives the pane Working (for codex
/// that's the title-bar spinner, which detection already tracks), and it's
/// exactly as observable under churn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum VerifyAction {
    /// Working: the submission (or something) took — the agent is running;
    /// nothing further to verify. Blocked: a permission/approval dialog owns
    /// the keyboard — an Enter could accept it; never touch the pane.
    Settled,
    /// Unknown (e.g. detection's startup grace): can't act safely either
    /// way; keep watching.
    Wait,
    /// Still Idle after the Enter should have landed: the Enter was
    /// swallowed (codex reads a stall-batched text+Enter as a paste and
    /// suppresses the Enter). Press Enter again — at a genuinely idle,
    /// empty composer a lone Enter is a no-op, so a false retry is safe.
    Retry,
}

fn verify_action(state: PaneState) -> VerifyAction {
    match state {
        PaneState::Working | PaneState::Blocked => VerifyAction::Settled,
        PaneState::Unknown => VerifyAction::Wait,
        PaneState::Idle => VerifyAction::Retry,
    }
}

/// Submit whatever is in the agent's composer: Right-arrow, a beat, Enter.
///
/// The cursor key is the load-bearing half. Codex classifies any fast run of
/// input as a paste burst, and while that classification is live an Enter is
/// ACCUMULATED as a newline — and each Enter keeps the burst alive (its
/// paste_burst.rs: `append_newline_if_active` / "Keep burst window alive"),
/// so once a stall has batched text+Enter together, no amount of waiting and
/// no number of further bare Enters ever submits (reproduced on a real
/// machine: five spaced retry Enters over 15s each just added a newline).
/// A non-char key is the documented way out: codex force-flushes the burst
/// buffer and clears the suppression window before handling it
/// (`flush_before_modified_input` + `clear_window_after_non_char`), after
/// which Enter submits normally — even when the whole sequence arrives in
/// one batched read. A Right-arrow at the end of the composer text is a
/// cursor no-op in every TUI this app spawns, so it's safe universally.
fn write_submit(sessions: &Arc<Mutex<HashMap<String, PtySession>>>, id: &str) {
    if let Some(s) = sessions.lock().unwrap().get_mut(id) {
        let _ = s.writer.write_all(b"\x1b[C");
        let _ = s.writer.flush();
    }
    thread::sleep(Duration::from_millis(50));
    if let Some(s) = sessions.lock().unwrap().get_mut(id) {
        let _ = s.writer.write_all(b"\r");
        let _ = s.writer.flush();
    }
}

/// Inject `text` (then submit) into the agent's stdin — the universal,
/// agent-agnostic agmsg delivery. No idle wait before writing the text; see
/// the module doc comment for why waiting for quiescence was worse than not
/// waiting.
///
/// The submission is NOT a bare trailing Enter. Codex classifies fast input
/// as a paste burst *in its own read timeline*: any event-loop stall
/// spanning the text→Enter gap (CPU contention from agmsg's own hook
/// subprocess storms on Windows #449, other agents, a busy machine) makes it
/// read text+Enter in one batch, swallow the Enter as pasted newline, and
/// leave the message sitting unsubmitted in the composer. Measured on a real
/// Windows machine: with all cores busy, the old fixed 300ms gap failed 3/5
/// and a 1000ms gap failed 5/5 — no open-loop delay survives a sustained
/// stall, and once swallowed, later bare Enters only pile up newlines (the
/// burst state self-extends; see write_submit). So the sequence is
/// text → gap → Right-arrow → Enter (write_submit), which deterministically
/// ends any paste classification before the Enter: 11/11 submitted across
/// stalled / loaded / batched reproductions where the old sequence went
/// 0-for-all. The gap stays as typed-input pacing for other agents.
///
/// After submitting, verify by state and retry: a submission always drives
/// the pane Working, so if it instead sits Idle at spaced checkpoints, run
/// write_submit again (harmless at an idle empty composer); a pane that
/// goes Blocked is never touched — a stray Enter could accept the dialog.
/// Runs on a background thread so none of the waiting blocks the Tauri
/// command handler.
#[tauri::command]
pub fn pty_inject(manager: State<'_, PtyManager>, id: String, text: String) -> Result<(), String> {
    // Fail fast, synchronously, if the pane is already gone.
    if !manager.sessions.lock().unwrap().contains_key(&id) {
        return Err("no such pty session".to_string());
    }
    let sessions = Arc::clone(&manager.sessions);
    thread::spawn(move || {
        // One injection at a time per pane; a second message must not
        // interleave its writes with this one's text/Enter/verify sequence.
        // Clone the lock handle out so the sessions map isn't held while
        // waiting (pty_write/pty_kill must stay responsive).
        let Some(lock) = sessions.lock().unwrap().get(&id).map(|s| Arc::clone(&s.inject_lock))
        else {
            return;
        };
        let _guard = lock.lock().unwrap();

        if let Some(s) = sessions.lock().unwrap().get_mut(&id) {
            let _ = s.writer.write_all(text.as_bytes());
            let _ = s.writer.flush();
        }
        thread::sleep(Duration::from_millis(300));
        write_submit(&sessions, &id);

        // Verify-and-retry: sample the pane state (200ms, finer than the
        // 400ms detection tick) so a Working/Blocked transition is caught
        // even if it's brief, and press Enter again at spaced checkpoints
        // while the pane still sits Idle. Checkpoints stretch out so a slow
        // wake (heavily stalled machine) still gets re-checked late.
        const RETRY_AT_MS: [u64; 5] = [1000, 3000, 6000, 10000, 15000];
        let started = std::time::Instant::now();
        let mut next_retry = 0;
        while next_retry < RETRY_AT_MS.len() {
            thread::sleep(Duration::from_millis(200));
            let Some(state) =
                sessions.lock().unwrap().get(&id).map(|s| s.detection.lock().unwrap().state())
            else {
                return;
            };
            match verify_action(state) {
                VerifyAction::Settled => return,
                VerifyAction::Wait => continue,
                VerifyAction::Retry => {
                    if started.elapsed() >= Duration::from_millis(RETRY_AT_MS[next_retry]) {
                        next_retry += 1;
                        write_submit(&sessions, &id);
                    }
                }
            }
        }
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{verify_action, windows_shell_argv, VerifyAction};
    use crate::agent_state::PaneState;

    #[test]
    fn an_idle_pane_after_the_enter_means_it_was_swallowed() {
        // The reproduced failure: a stall makes codex read text+Enter as one
        // paste burst and suppress the Enter — the pane never leaves Idle.
        // Retrying Enter is safe even on a false positive (an Enter at an
        // idle empty composer is a no-op).
        assert_eq!(verify_action(PaneState::Idle), VerifyAction::Retry);
    }

    #[test]
    fn a_working_pane_means_the_submission_took() {
        assert_eq!(verify_action(PaneState::Working), VerifyAction::Settled);
    }

    #[test]
    fn never_enter_into_a_blocked_pane() {
        // A permission/approval dialog owns the keyboard — a stray Enter
        // could accept it. Hands off entirely.
        assert_eq!(verify_action(PaneState::Blocked), VerifyAction::Settled);
    }

    #[test]
    fn unknown_state_neither_retries_nor_concludes() {
        // e.g. detection's startup grace window — keep watching.
        assert_eq!(verify_action(PaneState::Unknown), VerifyAction::Wait);
    }

    #[test]
    fn wraps_the_agent_name_through_cmd_slash_c() {
        // The name stays a bare (unquoted) token so cmd's strip-first/last-quote
        // rule never fires; the space-bearing boot prompt must survive as ONE
        // argv element addressed to the agent (issues #314 / #313).
        let args = vec![
            "--permission-mode".to_string(),
            "acceptEdits".to_string(),
            "/agmsg actas Ami".to_string(),
        ];
        assert_eq!(
            windows_shell_argv("claude", &args),
            vec!["/d", "/c", "claude", "--permission-mode", "acceptEdits", "/agmsg actas Ami"],
        );
    }

    #[test]
    fn wraps_an_argless_launch() {
        assert_eq!(windows_shell_argv("codex", &[]), vec!["/d", "/c", "codex"]);
    }

    // resolve_windows_cwd is behind cfg(windows); this test runs on the
    // windows-latest app-test CI job (a compile-pass elsewhere isn't validation
    // — the 0.1.2 lesson). Exercises the #315 phantom-cwd guard end to end.
    #[cfg(target_os = "windows")]
    #[test]
    fn resolve_windows_cwd_rejects_phantom_and_accepts_a_real_dir() {
        use super::resolve_windows_cwd;
        // A nonexistent MSYS-form cwd (the phantom-splitting registration) is
        // rejected rather than booted into.
        assert!(resolve_windows_cwd("/c/no/such/agmsg/project/dir").is_err());
        // A real dir addressed in MSYS form resolves to native and is accepted.
        let tmp = tempfile::tempdir().unwrap();
        let msys = crate::agmsg::to_bash_slashes(&tmp.path().to_string_lossy());
        let native = resolve_windows_cwd(&msys).expect("a real dir should be accepted");
        assert!(std::path::Path::new(&native).is_dir());
    }
}
