// poc-inject — Phase 0 (c): the strategic core of the agmsg desktop app.
//
// Prove that by OWNING an interactive CLI agent's PTY we can deliver agmsg
// messages with no per-agent bridge: watch agmsg's SQLite DB, and when a new
// message addressed to the watched agent arrives, wait until the agent's PTY
// is at an idle/ready prompt, then write the message into its stdin. The agent
// reacts as if a human typed it. Works for ANY interactive CLI (claude, codex,
// a python REPL, ...) because the mechanism is PTY-level, not agent-specific.
//
// Config via env (all optional):
//   POC_CMD        program to spawn in the PTY        (default: "bash")
//   POC_ARGS       space-split args for POC_CMD       (default: none)
//   POC_QUIET_MS   idle debounce: ms of PTY silence   (default: 700)
//   POC_PROMPT     extra substring the (de-ANSI'd) tail must contain to count
//                  as "ready" (default: none -> debounce alone decides)
//   POC_MAX_WAIT_MS  give up waiting for idle and inject anyway (default: 15000)
//   POC_RUNTIME_MS   kill the child and exit after N ms (default: run forever).
//                    Lets us demo a non-exiting TUI (claude) without a broad kill.
//
//   Message source — pick ONE:
//   POC_DB + POC_TEAM + POC_TO   watch agmsg DB for new rows to POC_TO
//   POC_INJECT                   synthetic: inject this one string after idle
//
// Everything the child prints is mirrored to our stdout so the run log shows
// the agent's TUI and proves it reacted.

use std::io::{Read, Write};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use portable_pty::{CommandBuilder, PtySize};

/// Shared view of the child's recent output, used to decide quiescence.
struct PtyState {
    last_output: Instant,
    /// Tail of recent output with ANSI escapes stripped, capped in size.
    tail: String,
}

impl PtyState {
    fn new() -> Self {
        PtyState { last_output: Instant::now(), tail: String::new() }
    }

    /// Idle = no output for `quiet` AND (if `need` set) the tail ends with it.
    /// Conservative on purpose: a mid-generation agent keeps emitting bytes, so
    /// the debounce alone already blocks injection until it settles.
    fn is_idle(&self, quiet: Duration, need: &Option<String>) -> bool {
        if self.last_output.elapsed() < quiet {
            return false;
        }
        match need {
            None => true,
            Some(s) => self.tail.trim_end().ends_with(s.as_str()),
        }
    }
}

fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()
}

fn log(msg: &str) {
    // Distinct prefix so PoC events stand out amid the mirrored child output.
    eprintln!("\n[poc {}] {}", now_ms(), msg);
}

/// Strip a useful subset of ANSI/VT control sequences so prompt matching and
/// the tail buffer aren't polluted by cursor moves and colors. Operates on raw
/// bytes and keeps multibyte UTF-8 intact (claude's TUI emits box-drawing etc.).
fn strip_ansi(input: &[u8]) -> String {
    let mut out: Vec<u8> = Vec::with_capacity(input.len());
    let mut i = 0;
    while i < input.len() {
        let b = input[i];
        if b == 0x1b {
            // ESC: skip CSI (ESC [ ... final) or OSC (ESC ] ... BEL/ST) etc.
            if i + 1 < input.len() && input[i + 1] == b'[' {
                i += 2;
                while i < input.len() && !(0x40..=0x7e).contains(&input[i]) {
                    i += 1;
                }
                i += 1; // skip the final byte
            } else if i + 1 < input.len() && input[i + 1] == b']' {
                i += 2;
                while i < input.len() && input[i] != 0x07 {
                    i += 1;
                }
                i += 1;
            } else {
                i += 2; // ESC + one byte (e.g. ESC =)
            }
        } else if b == b'\r' {
            i += 1; // drop carriage returns; keep newlines
        } else {
            out.push(b); // keep the raw byte; UTF-8 sequences pass through
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn env(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|s| !s.is_empty())
}

fn main() -> Result<()> {
    let cmd = env("POC_CMD").unwrap_or_else(|| "bash".to_string());
    let args: Vec<String> =
        env("POC_ARGS").map(|s| s.split_whitespace().map(String::from).collect()).unwrap_or_default();
    let quiet = Duration::from_millis(env("POC_QUIET_MS").and_then(|s| s.parse().ok()).unwrap_or(700));
    let max_wait =
        Duration::from_millis(env("POC_MAX_WAIT_MS").and_then(|s| s.parse().ok()).unwrap_or(15_000));
    let runtime = env("POC_RUNTIME_MS").and_then(|s| s.parse::<u64>().ok()).map(Duration::from_millis);
    let need_prompt = env("POC_PROMPT");

    log(&format!(
        "spawning PTY: cmd={cmd:?} args={args:?} quiet={}ms prompt={:?}",
        quiet.as_millis(),
        need_prompt
    ));

    let pty_system = portable_pty::native_pty_system();
    let pair = pty_system
        .openpty(PtySize { rows: 30, cols: 100, pixel_width: 0, pixel_height: 0 })
        .context("openpty")?;

    let mut builder = CommandBuilder::new(&cmd);
    for a in &args {
        builder.arg(a);
    }
    builder.env("TERM", "xterm-256color");
    let mut child = pair.slave.spawn_command(builder).context("spawn child")?;
    drop(pair.slave);

    let state = Arc::new(Mutex::new(PtyState::new()));
    let mut reader = pair.master.try_clone_reader().context("clone reader")?;
    let mut writer = pair.master.take_writer().context("take writer")?;

    // Reader thread: mirror child output + update quiescence state.
    {
        let state = Arc::clone(&state);
        thread::spawn(move || {
            let mut buf = [0u8; 8192];
            let stdout = std::io::stdout();
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        // mirror raw so the TUI looks right in our terminal/log
                        let mut h = stdout.lock();
                        let _ = h.write_all(&buf[..n]);
                        let _ = h.flush();

                        let clean = strip_ansi(&buf[..n]);
                        let mut st = state.lock().unwrap();
                        st.last_output = Instant::now();
                        st.tail.push_str(&clean);
                        // Cap the tail, cutting only on a UTF-8 char boundary.
                        const CAP: usize = 2048;
                        if st.tail.len() > CAP {
                            let mut cut = st.tail.len() - CAP;
                            while cut < st.tail.len() && !st.tail.is_char_boundary(cut) {
                                cut += 1;
                            }
                            st.tail = st.tail.split_off(cut);
                        }
                    }
                    Err(_) => break,
                }
            }
        });
    }

    // Message source -> channel of bodies to inject.
    let (tx, rx): (Sender<String>, Receiver<String>) = channel();
    spawn_message_source(tx)?;

    // Injector: for each pending message, wait for idle then write to stdin.
    let injector = {
        let state = Arc::clone(&state);
        thread::spawn(move || {
            for body in rx {
                log(&format!("message received -> waiting for idle prompt: {body:?}"));
                let started = Instant::now();
                loop {
                    let idle = { state.lock().unwrap().is_idle(quiet, &need_prompt) };
                    if idle {
                        let waited = started.elapsed().as_millis();
                        log(&format!("idle detected after {waited}ms -> INJECTING into stdin"));
                        // Type the text, then submit with a carriage return.
                        if writer.write_all(body.as_bytes()).is_err() {
                            log("write failed (child gone?)");
                            return;
                        }
                        let _ = writer.write_all(b"\r");
                        let _ = writer.flush();
                        log("injected.");
                        break;
                    }
                    if started.elapsed() > max_wait {
                        log("max wait exceeded; injecting anyway (idle never settled)");
                        let _ = writer.write_all(body.as_bytes());
                        let _ = writer.write_all(b"\r");
                        let _ = writer.flush();
                        break;
                    }
                    thread::sleep(Duration::from_millis(50));
                }
            }
        })
    };

    // Poll for child exit (don't block) so a runtime deadline can fire.
    let deadline = runtime.map(|d| Instant::now() + d);
    loop {
        if let Some(status) = child.try_wait().context("try_wait child")? {
            log(&format!("child exited: {status:?}"));
            break;
        }
        if let Some(d) = deadline {
            if Instant::now() >= d {
                log("runtime deadline reached -> killing child");
                let _ = child.kill();
                let _ = child.wait();
                break;
            }
        }
        thread::sleep(Duration::from_millis(100));
    }
    let _ = injector.join();
    Ok(())
}

/// Decide the message source from env and feed bodies into `tx`.
fn spawn_message_source(tx: Sender<String>) -> Result<()> {
    if let Some(text) = env("POC_INJECT") {
        // Synthetic single-shot: fire after a short delay so the child boots.
        thread::spawn(move || {
            thread::sleep(Duration::from_millis(300));
            let _ = tx.send(text);
        });
        return Ok(());
    }

    let (db, team, to) = match (env("POC_DB"), env("POC_TEAM"), env("POC_TO")) {
        (Some(d), Some(t), Some(a)) => (d, t, a),
        _ => {
            anyhow::bail!("no message source: set POC_INJECT, or POC_DB+POC_TEAM+POC_TO");
        }
    };
    log(&format!("watching agmsg DB {db} for new messages: team={team} to={to}"));

    thread::spawn(move || {
        // Open read-only; the app is a viewer and must never mutate agmsg state.
        let conn = match rusqlite::Connection::open_with_flags(
            &db,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_URI,
        ) {
            Ok(c) => c,
            Err(e) => {
                log(&format!("DB open failed: {e}"));
                return;
            }
        };
        // Baseline: only react to messages that arrive AFTER we start.
        let mut last_id: i64 = conn
            .query_row("SELECT COALESCE(MAX(id),0) FROM messages", [], |r| r.get(0))
            .unwrap_or(0);
        log(&format!("DB baseline last_id={last_id}"));
        loop {
            let rows: Vec<(i64, String, String)> = {
                let mut stmt = match conn.prepare(
                    "SELECT id, from_agent, body FROM messages \
                     WHERE team=?1 AND to_agent=?2 AND id>?3 ORDER BY id",
                ) {
                    Ok(s) => s,
                    Err(_) => return,
                };
                let mapped = stmt
                    .query_map(rusqlite::params![team, to, last_id], |r| {
                        Ok((r.get(0)?, r.get(1)?, r.get(2)?))
                    })
                    .and_then(|it| it.collect::<rusqlite::Result<Vec<_>>>());
                match mapped {
                    Ok(v) => v,
                    Err(_) => Vec::new(),
                }
            };
            for (id, from, body) in rows {
                last_id = id.max(last_id);
                let line = format!("[agmsg {from}] {body}");
                log(&format!("DB new msg id={id} from={from}"));
                if tx.send(line).is_err() {
                    return;
                }
            }
            thread::sleep(Duration::from_millis(800));
        }
    });
    Ok(())
}
