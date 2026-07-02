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

/// One live PTY-backed agent terminal.
struct PtySession {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    /// Child process id, so closing a pane can actually terminate the agent
    /// (and let its SessionEnd hook release the agmsg actas lock).
    pid: Option<u32>,
}

/// All live sessions, keyed by a frontend-chosen id (e.g. "claude-1").
/// `Arc` so the idle-wait injector thread can share the map without unsafe.
#[derive(Default)]
pub struct PtyManager {
    sessions: Arc<Mutex<HashMap<String, PtySession>>>,
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

    let mut builder = CommandBuilder::new(&cmd);
    for a in &args {
        builder.arg(a);
    }
    if let Some(dir) = &cwd {
        builder.cwd(dir);
    }
    builder.env("TERM", "xterm-256color");

    let mut child = pair.slave.spawn_command(builder).map_err(|e| e.to_string())?;
    drop(pair.slave);
    let pid = child.process_id();

    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;

    // Reader thread: stream output to the webview.
    {
        let app = app.clone();
        let id = id.clone();
        thread::spawn(move || {
            let mut buf = [0u8; 8192];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
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

    manager.sessions.lock().unwrap().insert(id, PtySession { master: pair.master, writer, pid });
    Ok(())
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

/// Inject `text` (then Enter) into the agent's stdin — the universal,
/// agent-agnostic agmsg delivery. No idle wait before writing the text; see
/// the module doc comment for why waiting for quiescence was worse than not
/// waiting. The text and Enter are NOT written back-to-back, though: real-
/// machine testing showed codex's TUI reads a same-burst text+Enter as a
/// paste (the trailing newline is swallowed as pasted content rather than
/// submitting), so the Enter is held back a beat after the text — long
/// enough that the agent's input parser has processed the text as typed
/// input first. Runs on a background thread so the ~300ms gap doesn't block
/// the Tauri command handler.
#[tauri::command]
pub fn pty_inject(manager: State<'_, PtyManager>, id: String, text: String) -> Result<(), String> {
    // Fail fast, synchronously, if the pane is already gone.
    if !manager.sessions.lock().unwrap().contains_key(&id) {
        return Err("no such pty session".to_string());
    }
    let sessions = Arc::clone(&manager.sessions);
    thread::spawn(move || {
        if let Some(s) = sessions.lock().unwrap().get_mut(&id) {
            let _ = s.writer.write_all(text.as_bytes());
            let _ = s.writer.flush();
        }
        thread::sleep(Duration::from_millis(300));
        if let Some(s) = sessions.lock().unwrap().get_mut(&id) {
            let _ = s.writer.write_all(b"\r");
            let _ = s.writer.flush();
        }
    });
    Ok(())
}
