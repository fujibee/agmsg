// PTY session manager — the terminal-embedded core of the agmsg desktop app.
//
// The app OWNS each spawned agent's pseudo-terminal: it spawns the agent in a
// real PTY (so full TUIs render), streams output to the webview (xterm.js),
// forwards keystrokes back, and — the strategic bit — can INJECT an agmsg
// message into the agent's stdin once the agent is at an idle/ready prompt.
// That injection is agent-agnostic: it works for any interactive CLI because it
// operates at the PTY layer, not via a per-agent bridge. Proven in poc-inject/.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use base64::Engine;
use portable_pty::{CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use tauri::{AppHandle, Emitter, State};

/// One live PTY-backed agent terminal.
struct PtySession {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    /// Last time the child produced output — basis for quiescence detection.
    last_output: Arc<Mutex<Instant>>,
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

    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = pair.master.take_writer().map_err(|e| e.to_string())?;
    let last_output = Arc::new(Mutex::new(Instant::now()));

    // Reader thread: stream output to the webview + track quiescence.
    {
        let app = app.clone();
        let id = id.clone();
        let last_output = Arc::clone(&last_output);
        thread::spawn(move || {
            let mut buf = [0u8; 8192];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        *last_output.lock().unwrap() = Instant::now();
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

    manager
        .sessions
        .lock()
        .unwrap()
        .insert(id, PtySession { master: pair.master, writer, last_output });
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

/// Drop a session (the child is killed when the master writer/handles close).
#[tauri::command]
pub fn pty_kill(manager: State<'_, PtyManager>, id: String) -> Result<(), String> {
    manager.sessions.lock().unwrap().remove(&id);
    Ok(())
}

/// Inject `text` (then Enter) into the agent's stdin once it has been quiet for
/// `quiet_ms` — the universal, agent-agnostic agmsg delivery. Non-blocking:
/// waits for quiescence on a background thread so the UI stays responsive.
#[tauri::command]
pub fn pty_inject(
    manager: State<'_, PtyManager>,
    id: String,
    text: String,
    quiet_ms: Option<u64>,
    max_wait_ms: Option<u64>,
) -> Result<(), String> {
    let quiet = Duration::from_millis(quiet_ms.unwrap_or(1500));
    let max_wait = Duration::from_millis(max_wait_ms.unwrap_or(20_000));

    // Share what the background thread needs; don't hold the lock while waiting.
    let last_output = {
        let sessions = manager.sessions.lock().unwrap();
        let s = sessions.get(&id).ok_or("no such pty session")?;
        Arc::clone(&s.last_output)
    };
    let sessions = Arc::clone(&manager.sessions);

    thread::spawn(move || {
        let started = Instant::now();
        loop {
            let idle = last_output.lock().unwrap().elapsed() >= quiet;
            let give_up = started.elapsed() >= max_wait;
            if idle || give_up {
                if let Some(s) = sessions.lock().unwrap().get_mut(&id) {
                    let _ = s.writer.write_all(text.as_bytes());
                    let _ = s.writer.write_all(b"\r");
                    let _ = s.writer.flush();
                }
                break;
            }
            thread::sleep(Duration::from_millis(50));
        }
    });
    Ok(())
}
