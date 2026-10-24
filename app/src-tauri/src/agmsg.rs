// agmsg data access — VIEW-ONLY reader over the agmsg installation.
//
// The desktop app reads agmsg's own SQLite DB and team config directly; it never
// mutates agmsg state here (sending still goes through agmsg's scripts). This
// powers the default "team room": the whole cross-agent conversation as a
// read-only feed, plus the left-hand member list.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
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

/// Where one team's store is, as agmsg reports it — never as the app guesses.
///
/// The app used to join `db/messages.db` itself, which is why a storage
/// layout change broke it with nothing to notice: a hardcoded path cannot go
/// stale loudly. Asking means the answer follows the layout.
#[derive(Deserialize)]
struct StoreInfo {
    driver: String,
    path: String,
    /// A team that has never been written to has no store yet. Not an error —
    /// it is an empty room.
    exists: bool,
}

/// `api.sh` is the contract; reading the file directly is an optimisation
/// that only applies when the driver is one this app can parse.
///
/// Other drivers, and older cores without the store endpoint, go through
/// `api.sh`. A successful history read is required to initialize that fallback.
const DIRECTLY_READABLE_DRIVER: &str = "sqlite";

fn store_info(team: &str) -> Result<StoreInfo, String> {
    let raw = run_script("api.sh", &["get", "teams", team, "store"])?;
    parse_jsonl::<StoreInfo>(&raw)
        .into_iter()
        .next()
        .ok_or_else(|| format!("no store info for team {team}"))
}

/// A missing SQLite store still has a path to watch from cursor zero.
fn direct_store_path(info: &StoreInfo) -> Option<PathBuf> {
    (info.driver == DIRECTLY_READABLE_DRIVER).then(|| PathBuf::from(&info.path))
}

fn api_fallback_store(team: &str, error: &str) -> StoreInfo {
    eprintln!("agmsg: could not resolve the store for team {team} ({error}); trying API history");
    // No guessed path: this target can only initialize through a successful
    // API history read, including on cores predating the store endpoint.
    StoreInfo { driver: "api".into(), path: String::new(), exists: false }
}

/// New messages, from the event log and the legacy table together.
///
/// The read rule mirrors `storage_list_unread()` in
/// `scripts/drivers/storage/sqlite.sh` (and `storage_history()` for the
/// ordering). `src` breaks ties between a legacy row and an event-log row
/// carrying the same timestamp, so the two spaces interleave in one stable
/// order -- legacy first, matching the facade.
///
/// The core writes every message to BOTH tables, the event carrying the
/// legacy rowid in `events.legacy_id` (#689). A union of the two therefore
/// lists each message twice, so the legacy half marks a row `linked` when its
/// event is in the live space and the reader below leaves it out: the event
/// copy is the one that is emitted. Live space only (`seq > 0`), exactly as in
/// the core: a legacy row projected for push has an event too, but at a
/// negative `seq` below every cursor, which the event half can never return --
/// skipping the legacy row on its account would lose the message.
///
/// A linked row is still FETCHED, and both cursors advance past it. Dropping
/// it in SQL instead would leave `legacy_id` behind it for good, and every
/// later poll would fetch and discard the same rows again.
///
/// NOT enforced: nothing checks that this stays in step with the shell. The
/// tests below assert what this returns, not that the facade agrees, so a
/// change to the core's read will not turn anything red here. Keeping the two
/// aligned is currently a matter of someone remembering.
///
/// Two cursors because there are two id spaces: `events.seq` and the legacy
/// `messages.id` autoincrement. They are unrelated counters, both starting
/// at 1, so a single high-water mark would skip rows in whichever table was
/// behind.
///
/// `linked` is spliced in because the column it reads, `events.legacy_id`, only
/// exists from core 1.2.0: against an older store naming it fails the whole
/// statement. See [`read_new_messages`] for what happens then.
fn messages_since_sql(linked: &str) -> String {
    format!(
        "\
    SELECT id, team, from_agent, to_agent, body, at, src, ord, linked FROM (
      SELECT id AS id, team, from_agent, to_agent, body, at AS at,
             1 AS src, seq AS ord, 0 AS linked
        FROM events
       WHERE type='message_sent' AND seq > ?1
      UNION ALL
      SELECT CAST(id AS TEXT) AS id, team, from_agent, to_agent, body,
             created_at AS at, 0 AS src, id AS ord, {linked} AS linked
        FROM messages
       WHERE id > ?2
    )
    ORDER BY at ASC, src ASC, ord ASC"
    )
}

/// The `linked` test for a store whose `events` has `legacy_id`.
const LINKED_TO_A_LIVE_EVENT: &str = "\
    EXISTS (SELECT 1 FROM events e2
             WHERE e2.legacy_id = messages.id AND e2.seq > 0)";

/// The same read against a store built before the event log, where `events`
/// does not exist and the whole query above fails to prepare.
const MESSAGES_SINCE_LEGACY_ONLY_SQL: &str = "\
    SELECT CAST(id AS TEXT) AS id, team, from_agent, to_agent, body,
           created_at AS at, 0 AS src, id AS ord, 0 AS linked
      FROM messages
     WHERE id > ?2
     ORDER BY at ASC, ord ASC";

/// Where each of the two id spaces has been read up to.
#[derive(Clone, Copy, Default)]
struct Cursors {
    /// `events.seq`
    seq: i64,
    /// legacy `messages.id`
    legacy_id: i64,
}

/// Initial watcher position: history is loaded separately and must not be
/// replayed as fresh notifications when a store is opened or the app reloads.
fn current_cursors(conn: &rusqlite::Connection) -> Cursors {
    Cursors {
        seq: conn
            .query_row("SELECT COALESCE(MAX(seq),0) FROM events", [], |r| r.get(0))
            .unwrap_or(0),
        legacy_id: conn
            .query_row("SELECT COALESCE(MAX(id),0) FROM messages", [], |r| r.get(0))
            .unwrap_or(0),
    }
}

/// Reads rows newer than `cursors`, advances both past them, and returns the
/// messages among them -- a legacy copy of a message whose event is also
/// there is advanced past but not returned (see [`messages_since_sql`]).
///
/// The statement is attempted at three levels, each for an older store than
/// the last:
///
/// 1. both tables, with the legacy copies of live events recognised --
///    needs `events.legacy_id` (core 1.2.0 and later);
/// 2. both tables with no copy recognised -- a store whose `events` predates
///    `legacy_id`, which is the layout of the cores that wrote each message
///    to only one table, so there is nothing to double-count;
/// 3. the legacy table alone -- a store that predates the event log, with no
///    `events` table at all. That is the released layout today: this
///    machine's own store has `messages` with 6,285 rows and no `events`
///    table at all.
fn read_new_messages(
    conn: &rusqlite::Connection,
    cursors: &mut Cursors,
) -> Result<Vec<Message>, rusqlite::Error> {
    let run = |sql: &str| -> Result<Vec<(Message, i64, i64, bool)>, rusqlite::Error> {
        let mut stmt = conn.prepare(sql)?;
        let rows = stmt.query_map(rusqlite::params![cursors.seq, cursors.legacy_id], |r| {
            Ok((
                Message {
                    id: r.get(0)?,
                    team: r.get(1)?,
                    from: r.get(2)?,
                    to: r.get(3)?,
                    body: r.get(4)?,
                    created_at: r.get(5)?,
                },
                r.get::<_, i64>(6)?,
                r.get::<_, i64>(7)?,
                r.get::<_, i64>(8)? != 0,
            ))
        })?;
        rows.collect()
    };

    let rows = match run(&messages_since_sql(LINKED_TO_A_LIVE_EVENT)) {
        Ok(rows) => rows,
        Err(_) => match run(&messages_since_sql("0")) {
            Ok(rows) => rows,
            Err(_) => run(MESSAGES_SINCE_LEGACY_ONLY_SQL)?,
        },
    };

    let mut out = Vec::with_capacity(rows.len());
    for (msg, src, ord, linked) in rows {
        if src == 1 {
            cursors.seq = cursors.seq.max(ord);
        } else {
            cursors.legacy_id = cursors.legacy_id.max(ord);
        }
        if !linked {
            out.push(msg);
        }
    }
    Ok(out)
}

fn open_ro(path: &std::path::Path) -> Result<rusqlite::Connection, String> {
    rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| e.to_string())
}

/// `None` is an initialized, empty API baseline. Uninitialized teams have no
/// entry in WatcherStores, so the first later message must be emitted.
fn messages_after(all: Vec<Message>, last_seen: Option<&str>) -> (Vec<Message>, Option<String>) {
    let watermark = all.last().map(|m| m.id.clone()).or(last_seen.map(str::to_string));
    let Some(last_seen) = last_seen else {
        return (all, watermark);
    };
    let fresh = match all.iter().position(|m| m.id == last_seen) {
        Some(i) => all[i + 1..].to_vec(),
        // The watermark fell out of the bounded API window.
        None => all,
    };
    (fresh, watermark)
}

/// The initial history command and the polling thread share this state. The
/// frontend installs its event listener before requesting initial history.
#[derive(Clone, Default)]
pub struct MessageWatcher(Arc<Mutex<WatcherStores>>);

struct DirectStore {
    path: PathBuf,
    // None means the resolved path did not exist. Retain cursor zero when it
    // appears: taking MAX then would silently skip its first message.
    conn: Option<rusqlite::Connection>,
    cursors: Cursors,
}

#[derive(Clone, PartialEq, Eq)]
enum WatchRoute {
    Direct(PathBuf),
    Api,
}

#[derive(Default)]
struct WatcherStores {
    direct: Vec<DirectStore>,
    // An entry exists only after a successful API baseline read. Its None
    // watermark means that successful read was empty, not "not initialized".
    via_api: Vec<(String, Option<String>)>,
    routes: Vec<(String, WatchRoute)>,
    // Route changes reconcile room history, never replay it into live panes.
    refresh_teams: Vec<String>,
    revision: u64,
}

fn open_existing_ro(path: &std::path::Path) -> Result<Option<rusqlite::Connection>, String> {
    match std::fs::metadata(path) {
        Ok(_) => open_ro(path).map(Some),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("could not inspect {}: {e}", path.display())),
    }
}

impl MessageWatcher {
    fn initial_history_with(
        &self,
        team: &str,
        limit: u32,
        resolve: impl FnOnce() -> Result<StoreInfo, String>,
        mut history: impl FnMut(u32) -> Result<Vec<Message>, String>,
    ) -> Result<Vec<Message>, String> {
        // Keep the lock through baseline and history. Subprocesses can delay a
        // poll/another initial load, but no poll can initialize past a history
        // snapshot and lose a message in the handoff.
        let mut stores = self.0.lock().map_err(|e| e.to_string())?;
        let info = match resolve() {
            Ok(info) => info,
            // A transient lookup failure must not replace a working route.
            // Older cores without this endpoint still get the API fallback
            // when a team has no established watcher yet.
            Err(_) if stores.routes.iter().any(|(t, _)| t == team) => return history(limit),
            Err(e) => api_fallback_store(team, &e),
        };
        stores.initial_history_with(team, limit, info, history)
    }
}

impl WatcherStores {
    fn knows(&self, team: &str, info: &StoreInfo) -> bool {
        let route = direct_store_path(info).map(WatchRoute::Direct).unwrap_or(WatchRoute::Api);
        self.routes.iter().any(|(t, current)| t == team && current == &route)
    }

    fn commit_route(&mut self, team: &str, route: WatchRoute) {
        if let Some((_, current)) = self.routes.iter_mut().find(|(t, _)| t == team) {
            if *current == route { return; }
            *current = route;
            if !self.refresh_teams.iter().any(|t| t == team) {
                self.refresh_teams.push(team.to_string());
            }
        } else {
            self.routes.push((team.to_string(), route));
        }
        self.revision = self.revision.wrapping_add(1);
        self.via_api.retain(|(team, _)| self.routes.iter().any(|(t, r)| t == team && *r == WatchRoute::Api));
        // A shared connection's cursor belongs to every team still using it.
        self.direct.retain(|store| self.routes.iter().any(|(_, route)| {
            matches!(route, WatchRoute::Direct(path) if path == &store.path)
        }));
    }

    fn take_refreshes(&mut self) -> Vec<String> {
        std::mem::take(&mut self.refresh_teams)
    }

    fn discover_if_current(
        &mut self,
        team: &str,
        revision: u64,
        resolved: Result<StoreInfo, String>,
        history: impl FnMut(u32) -> Result<Vec<Message>, String>,
    ) -> Result<(), String> {
        // A history request may have established a newer route while this
        // background resolver ran outside the lock. Retry on the next scan.
        if revision != self.revision { return Ok(()); }
        let info = match resolved {
            Ok(info) => info,
            Err(_) if self.routes.iter().any(|(t, _)| t == team) => return Ok(()),
            Err(e) => api_fallback_store(team, &e),
        };
        if self.knows(team, &info) { return Ok(()); }
        // This snapshot reconciles the room after a route change. Rows that
        // predate the new baseline are history, not new pane kickoffs; live
        // delivery during driver migration remains best effort.
        self.initial_history_with(team, 50, info, history).map(|_| ())
    }

    fn initial_history_with(
        &mut self,
        team: &str,
        limit: u32,
        info: StoreInfo,
        mut history: impl FnMut(u32) -> Result<Vec<Message>, String>,
    ) -> Result<Vec<Message>, String> {
        if let Some(path) = direct_store_path(&info) {
            if let Some(store) = self.direct.iter_mut().find(|s| s.path == path) {
                if store.conn.is_none() {
                    store.conn = open_existing_ro(&path)?;
                }
                if info.exists && store.conn.is_none() {
                    return Err(format!("reported store {} is missing; retry history", path.display()));
                }
                let rows = if store.conn.is_some() { history(limit)? } else { Vec::new() };
                self.commit_route(team, WatchRoute::Direct(path));
                return Ok(rows);
            }

            let conn = open_existing_ro(&path)?;
            if info.exists && conn.is_none() {
                return Err(format!("reported store {} is missing; retry history", path.display()));
            }
            let cursors = match &conn {
                Some(conn) if info.exists => current_cursors(conn),
                _ => Cursors::default(),
            };
            // A missing store is a valid empty snapshot, without invoking an
            // API command that might create it. Register its pending path.
            let rows = if conn.is_some() { history(limit)? } else { Vec::new() };
            self.direct.push(DirectStore { path: path.clone(), conn, cursors });
            self.commit_route(team, WatchRoute::Direct(path));
            return Ok(rows);
        }

        if self.via_api.iter().any(|(t, _)| t == team) {
            return history(limit);
        }
        let baseline = history(50)?;
        let watermark = baseline.last().map(|m| m.id.clone());
        let rows = if limit == 50 { baseline } else { history(limit)? };
        // Resolver failure alone, or API history failure, installs no marker.
        self.via_api.push((team.to_string(), watermark));
        self.commit_route(team, WatchRoute::Api);
        Ok(rows)
    }

    fn poll_direct(&mut self) -> Vec<Message> {
        let mut fresh = Vec::new();
        let routes = &self.routes;
        for store in &mut self.direct {
            if store.conn.is_none() {
                match open_existing_ro(&store.path) {
                    Ok(conn) => store.conn = conn,
                    Err(e) => {
                        eprintln!("agmsg: could not open watched store: {e}");
                        continue;
                    }
                }
            }
            if let Some(conn) = &store.conn {
                match read_new_messages(conn, &mut store.cursors) {
                    Ok(rows) => fresh.extend(rows.into_iter().filter(|message| {
                        match routes.iter().find(|(team, _)| team == &message.team) {
                            // Shared stores can contain a newly created team
                            // before discovery. Do not consume and drop it.
                            None => true,
                            Some((_, WatchRoute::Direct(path))) => path == &store.path,
                            Some((_, WatchRoute::Api)) => false,
                        }
                    })),
                    Err(e) => eprintln!("agmsg: could not poll {}: {e}", store.path.display()),
                }
            }
        }
        fresh
    }

    #[cfg(test)]
    fn poll_api_with(
        &mut self,
        mut history: impl FnMut(&str) -> Result<Vec<Message>, String>,
    ) -> Vec<Message> {
        let teams: Vec<_> = self.via_api.iter().map(|(team, _)| team.clone()).collect();
        teams.into_iter().flat_map(|team| self.poll_api_team_with(&team, || history(&team))).collect()
    }

    fn poll_api_team_with(
        &mut self,
        team: &str,
        history: impl FnOnce() -> Result<Vec<Message>, String>,
    ) -> Vec<Message> {
        let Some((_, seen)) = self.via_api.iter_mut().find(|(t, _)| t == team) else {
            return Vec::new();
        };
        match history() {
            Ok(rows) => {
                let (fresh, watermark) = messages_after(rows, seen.as_deref());
                *seen = watermark;
                fresh
            }
            Err(e) => {
                eprintln!("agmsg: could not poll team {team}: {e}");
                Vec::new()
            }
        }
    }
}

#[derive(Clone, Serialize)]
pub struct Message {
    /// Opaque, per `api.sh`'s own contract: "Every id (message ids included)
    /// is a JSON string, never a bare number — ids are opaque per the driver
    /// interface spec, and today's sqlite integer ids are no exception."
    ///
    /// This was `i64`, which held only while every id came from the legacy
    /// `messages` table's INTEGER PRIMARY KEY. Event-log ids are UUIDs
    /// (`019faa2a-48ae-7067-bb7d-ace26fd8a6df`), so parsing them as an
    /// integer failed — and because the parse sat inside a `filter_map`,
    /// every event-log message was dropped without a trace. Ordering does
    /// not depend on this value; the store returns rows already ordered.
    pub id: String,
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
    /// This type's actas-prompt prefix (manifest `cmd_prefix=`), e.g. "$" for
    /// opencode/codex/gemini/antigravity. None when the manifest omits it,
    /// which means "/" — the same default scripts/lib/boot-command.sh's
    /// agmsg_actas_prompt applies (#1007/#346: the frontend used to hardcode
    /// "/" for every type instead of reading this).
    pub cmd_prefix: Option<String>,
    /// A flag whose VALUE must carry the actas prompt, for a CLI that
    /// rejects it as a bare positional (manifest `prompt_arg=`), e.g.
    /// opencode's `--prompt` or copilot's `--interactive`. None when the
    /// prompt is passed positionally (claude-code). Mirrors the prompt half
    /// of scripts/lib/boot-command.sh's agmsg_role_cli_args.
    pub prompt_arg: Option<String>,
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
            let cmd_prefix = manifest_get(&conf, "cmd_prefix");
            let prompt_arg = manifest_get(&conf, "prompt_arg");
            types.push(AgentType { name, cli, options, cmd_prefix, prompt_arg });
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

/// The bundled agmsg-core version, stripped of its leading "v" (e.g.
/// "1.1.6") — the single source of truth both `agmsg_core_version_status`
/// (below) and the About dialog's version line (see make_menu in lib.rs)
/// read from, so they can never drift from each other.
pub(crate) fn pinned_core_version() -> String {
    PINNED_CORE_REF.trim().trim_start_matches('v').to_string()
}

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

/// The installed agmsg's own VERSION file, trimmed — None if it can't be
/// read (not installed yet, or the file is empty). Shared by
/// `agmsg_core_version_status` and `running_core_version` below so there is
/// exactly one place that reads it.
fn read_installed_core_version() -> Option<String> {
    std::fs::read_to_string(agmsg_base().join("VERSION"))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

/// The core this app is actually driving right now (installed at
/// `agmsg_base()`), for display -- as opposed to `pinned_core_version`, the
/// ref this build happened to bundle at compile time. Falls back to the
/// pinned version when the installed one can't be read, so the About line
/// (see `make_menu` in lib.rs) always has something reasonable to show
/// rather than going blank (#976).
pub(crate) fn running_core_version() -> String {
    read_installed_core_version().unwrap_or_else(pinned_core_version)
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
    let pinned = pinned_core_version();
    let installed = read_installed_core_version();

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
    watcher: tauri::State<'_, MessageWatcher>,
    team: String,
    limit: Option<u32>,
    // Opaque, like the id it pages from — `api.sh` deliberately does not
    // numeric-filter this one, "since event-log ids are UUIDs, not numeric".
    before_id: Option<String>,
) -> Result<Vec<Message>, String> {
    let limit = limit.unwrap_or(30);
    if before_id.is_some() {
        return message_history(&team, limit, before_id.as_deref());
    }
    watcher.initial_history_with(
        &team,
        limit,
        || store_info(&team),
        |limit| message_history(&team, limit, None),
    )
}

fn message_history(team: &str, limit: u32, before_id: Option<&str>) -> Result<Vec<Message>, String> {
    let limit_s = limit.to_string();
    let mut args = vec!["get", "teams", team, "messages", "--limit", &limit_s];
    if let Some(id) = before_id {
        args.push("--before-id");
        args.push(id);
    }
    let raw = run_script("api.sh", &args)?;
    parse_message_history(&raw)
}

fn parse_message_history(raw: &str) -> Result<Vec<Message>, String> {
    // A malformed response must not become a successful empty API baseline.
    raw.lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str::<ApiMessage>(line).map_err(|e| e.to_string()))
        .map(|row| row.map(|m| Message {
            id: m.id,
            team: m.team,
            from: m.from,
            to: m.to,
            body: m.body,
            created_at: m.created_at,
        }))
        .collect()
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

/// Rename a whole team (rename-team.sh; repoints messages, cursors and sync
/// state at the new name).
#[tauri::command]
pub fn agmsg_rename_team(old_team: String, new_team: String) -> Result<(), String> {
    run_script("rename-team.sh", &[&old_team, &new_team]).map(|_| ())
}

/// Delete a team (team.sh --delete --yes, #1475). Confirmation happens in the
/// UI before this is called. Refuses (with the reason on stderr, surfaced as
/// Err by run_script) when members remain, a remote binding is active, or the
/// team uses the jsonl storage driver.
#[tauri::command]
pub fn agmsg_delete_team(team: String) -> Result<(), String> {
    run_script("team.sh", &[&team, "--delete", "--yes"]).map(|_| ())
}

/// Delete a team's message history only, keeping the team and its members
/// (team.sh --purge-messages --yes, #1475). Same refusal/error surfacing as
/// agmsg_delete_team.
#[tauri::command]
pub fn agmsg_purge_team_messages(team: String) -> Result<(), String> {
    run_script("team.sh", &[&team, "--purge-messages", "--yes"]).map(|_| ())
}

/// Delete a team even though members remain, removing them all first
/// (team.sh --delete --force --yes, #1493; --purge-messages stays an
/// independent flag). Confirmed core CLI shape as of this writing (branch
/// fix-1493-delete-force, not yet merged pending final review). Only
/// reachable in the UI after a plain agmsg_delete_team has already failed
/// with the members-remain refusal.
#[tauri::command]
pub fn agmsg_delete_team_force(team: String, purge_messages: bool) -> Result<(), String> {
    let mut args = vec![team.as_str(), "--delete", "--force", "--yes"];
    if purge_messages {
        args.push("--purge-messages");
    }
    run_script("team.sh", &args).map(|_| ())
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
    let watcher = app.state::<MessageWatcher>().inner().clone();
    thread::spawn(move || {
        // Discovery and API polling cost subprocesses; direct reads stay on
        // the fast beat. Initial history also registers its requested team,
        // so a newly joined team need not wait for this rescan.
        let mut ticks_until_rescan = 0u32;
        loop {
            let rescan = ticks_until_rescan == 0;
            if rescan { ticks_until_rescan = 12; }
            ticks_until_rescan -= 1;
            let mut fresh = Vec::new();
            if rescan {
                // Enumerating and resolving stores can be slow. Do both
                // outside the mutex; only each team's baseline/history is
                // serialized with initial loads and cursor advancement.
                if let Ok(raw) = run_script("api.sh", &["get", "teams"]) {
                    for team in parse_jsonl::<ApiTeam>(&raw) {
                        let revision = match watcher.0.lock() {
                            Ok(stores) => stores.revision,
                            Err(_) => continue,
                        };
                        let info = store_info(&team.name);
                        if let Ok(mut stores) = watcher.0.lock() {
                            if let Err(e) = stores.discover_if_current(&team.name, revision, info, |limit| {
                                message_history(&team.name, limit, None)
                            }) {
                                eprintln!("agmsg: could not initialize watcher for {}: {e}", team.name);
                            }
                        }
                    }
                }
                let api_teams: Vec<_> = watcher.0.lock().map(|stores| {
                    stores.via_api.iter().map(|(team, _)| team.clone()).collect()
                }).unwrap_or_default();
                for team in api_teams {
                    if let Ok(mut stores) = watcher.0.lock() {
                        fresh.extend(stores.poll_api_team_with(&team, || message_history(&team, 50, None)));
                    }
                }
            }
            let refresh_teams = if let Ok(mut stores) = watcher.0.lock() {
                fresh.extend(stores.poll_direct());
                stores.take_refreshes()
            } else { Vec::new() };
            // Callbacks can request history; never emit while holding state.
            for team in refresh_teams {
                let _ = app.emit("agmsg-history-refresh", team);
            }
            for message in fresh {
                let _ = app.emit("agmsg-message", message);
            }
            thread::sleep(Duration::from_millis(800));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::{
        agmsg_base, msys_to_native, parse_semver, pinned_core_version, run_script,
        running_core_version, to_bash_slashes,
    };
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
    fn running_core_version_reads_installed_or_falls_back_to_pinned() {
        // Before #976, the About line always read the bundled AGMSG_CORE_REF
        // (pinned_core_version) — the version this build happened to bundle,
        // not the one actually driving every agmsg operation.
        let dir = tempfile::tempdir().unwrap();
        let _env = EnvGuard::set("AGMSG_APP_BASE", &dir.path().to_string_lossy());

        // No VERSION file yet: falls back to the bundled ref rather than
        // going blank.
        assert_eq!(running_core_version(), pinned_core_version());

        // An installed VERSION file wins over the bundled ref — the number a
        // user would actually act on.
        std::fs::write(dir.path().join("VERSION"), "9.9.9\n").unwrap();
        assert_eq!(running_core_version(), "9.9.9");
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

    /// Builds a store the way `storage_init` does: the event log plus the
    /// legacy table beside it, at the path [`super::db_path`] resolves to.
    fn store_with(base: &std::path::Path, events: &[(&str, &str)], legacy: &[&str]) {
        let db = base.join("db");
        std::fs::create_dir_all(&db).unwrap();
        let conn = rusqlite::Connection::open(db.join("messages.db")).unwrap();
        conn.execute_batch(
            "CREATE TABLE events (
               seq INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL,
               id TEXT NOT NULL, team TEXT, from_agent TEXT, to_agent TEXT,
               body TEXT, msg_id TEXT, agent TEXT, at TEXT NOT NULL,
               legacy_id INTEGER);
             CREATE TABLE messages (
               id INTEGER PRIMARY KEY AUTOINCREMENT, team TEXT NOT NULL,
               from_agent TEXT NOT NULL, to_agent TEXT NOT NULL, body TEXT NOT NULL,
               created_at TEXT NOT NULL, read_at TEXT);",
        )
        .unwrap();
        for (id, at) in events {
            conn.execute(
                "INSERT INTO events(type,id,team,from_agent,to_agent,body,at) \
                 VALUES ('message_sent',?1,'t','leader','worker','from the event log',?2)",
                rusqlite::params![id, at],
            )
            .unwrap();
        }
        for at in legacy {
            conn.execute(
                "INSERT INTO messages(team,from_agent,to_agent,body,created_at) \
                 VALUES ('t','leader','worker','from the legacy table',?1)",
                rusqlite::params![at],
            )
            .unwrap();
        }
    }

    /// Writes a message the way the core's `_sqlite_message_sent_sql` does: a
    /// legacy row, then an event row carrying that rowid in `legacy_id`, in one
    /// transaction. `event_seq` of `None` is an ordinary live event; `Some(n)`
    /// places the event at an explicit `seq`, which is how a legacy row
    /// projected for push looks (a negative one, below every read cursor).
    fn add_linked(base: &std::path::Path, event_id: &str, at: &str, event_seq: Option<i64>) {
        let conn = rusqlite::Connection::open(base.join("db/messages.db")).unwrap();
        conn.execute_batch("BEGIN IMMEDIATE").unwrap();
        conn.execute(
            "INSERT INTO messages(team,from_agent,to_agent,body,created_at) \
             VALUES ('t','leader','worker','written to both tables',?1)",
            rusqlite::params![at],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO events(seq,type,id,team,from_agent,to_agent,body,at,legacy_id) \
             VALUES (?1,'message_sent',?2,'t','leader','worker','written to both tables',?3, \
                     last_insert_rowid())",
            rusqlite::params![event_seq, event_id, at],
        )
        .unwrap();
        conn.execute_batch("COMMIT").unwrap();
    }

    /// Goes red if either read-rule failure comes back. Both were silent:
    /// the query ran, the parse "succeeded" by discarding rows, and the app
    /// showed nothing while reporting no error at all.
    ///
    /// - **legacy table only** — the UUID-keyed row is missing.
    /// - **id treated as a number** — the UUID row is the one that
    ///   disappears, because it is the only id that is not numeric.
    ///
    /// - **a message in both tables** — the core writes every message to the
    ///   event log AND the legacy table, the event carrying the legacy rowid
    ///   in `legacy_id` (#689). Read as two messages, each one showed twice in
    ///   the room and was injected twice into its pane (#1511). It must come
    ///   out once, as its event.
    /// - **a legacy row projected for push** — its event sits at a negative
    ///   `seq`, below every cursor, so the event can never be returned; the
    ///   legacy row is then the only copy and must still arrive, once.
    ///
    /// The third failure — opening the wrong file — is a different axis and
    /// is covered by `the_store_path_comes_from_agmsg_not_from_a_guess`.
    ///
    /// It exercises the watcher's own reader, not a copy of its SQL.
    #[test]
    #[serial]
    fn a_sent_message_reaches_the_app_from_both_the_event_log_and_the_legacy_table() {
        let dir = tempfile::tempdir().unwrap();
        let _env = EnvGuard::set("AGMSG_APP_BASE", &dir.path().to_string_lossy());
        store_with(
            dir.path(),
            &[("019faa2a-48ae-7067-bb7d-ace26fd8a6df", "2026-07-28T10:00:01Z")],
            &["2026-07-28T10:00:00Z"],
        );
        // Legacy row 2, its event at seq -1: projected for push.
        add_linked(dir.path(), "019faa2a-0000-7000-8000-00000000000a", "2026-07-28T10:00:02Z", Some(-1));
        // Legacy row 3 and its live event (seq 2): an ordinary message.
        add_linked(dir.path(), "019faa2a-0000-7000-8000-00000000000b", "2026-07-28T10:00:03Z", None);

        let conn = super::open_ro(&dir.path().join("db/messages.db"))
            .expect("the store must open");
        let mut cursors = super::Cursors::default();
        let got = super::read_new_messages(&conn, &mut cursors).expect("read");

        let ids: Vec<&str> = got.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(
            ids,
            vec![
                "1",
                "019faa2a-48ae-7067-bb7d-ace26fd8a6df",
                "2",
                "019faa2a-0000-7000-8000-00000000000b",
            ],
            "each message arrives once, oldest first — a UUID id means the event \
             log is being read and losing it is how this broke before; the \
             live pair is its event only (its legacy copy, row 3, is not a \
             second message); the projected row 2 is its legacy copy, because \
             its event can never be returned"
        );
        assert_eq!(got[1].body, "from the event log");

        // A second poll returns nothing: both cursors advanced, and a
        // shared one would have skipped whichever table was behind. The
        // legacy cursor moved past row 3 although that row was not emitted --
        // were it left behind, every later poll would fetch it again.
        assert_eq!((cursors.seq, cursors.legacy_id), (2, 3));
        let again = super::read_new_messages(&conn, &mut cursors).expect("read");
        assert!(again.is_empty(), "already-seen rows must not be re-emitted");
    }

    #[test]
    fn an_event_store_without_legacy_links_preserves_both_message_sources() {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE events (
               seq INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL,
               id TEXT NOT NULL, team TEXT, from_agent TEXT, to_agent TEXT,
               body TEXT, msg_id TEXT, agent TEXT, at TEXT NOT NULL);
             CREATE TABLE messages (
               id INTEGER PRIMARY KEY AUTOINCREMENT, team TEXT NOT NULL,
               from_agent TEXT NOT NULL, to_agent TEXT NOT NULL, body TEXT NOT NULL,
               created_at TEXT NOT NULL, read_at TEXT);
             INSERT INTO messages VALUES
               (1,'t','leader','worker','legacy','2026-01-01T00:00:00Z',NULL),
               (2,'t','leader','worker','projected','2026-01-01T00:00:02Z',NULL);
             INSERT INTO events(seq,type,id,team,from_agent,to_agent,body,at) VALUES
               (1,'message_sent','event-only','t','leader','worker','event',
                '2026-01-01T00:00:01Z'),
               (-1,'message_sent','projected-copy','t','leader','worker','projected',
                '2026-01-01T00:00:02Z');",
        )
        .unwrap();
        let mut cursors = super::Cursors::default();
        let got = super::read_new_messages(&conn, &mut cursors).unwrap();
        assert_eq!(
            got.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            vec!["1", "event-only", "2"],
            "the middle fallback must retain event-only messages and the legacy \
             copy of a negative projection when legacy_id does not exist"
        );
        assert_eq!((cursors.seq, cursors.legacy_id), (1, 2));
        assert!(super::read_new_messages(&conn, &mut cursors).unwrap().is_empty());
    }

    #[test]
    fn a_live_linked_message_arrives_once_after_startup_and_not_again_on_reload() {
        let dir = tempfile::tempdir().unwrap();
        store_with(
            dir.path(),
            &[("earlier-event", "2026-01-01T00:00:00Z")],
            &["2026-01-01T00:00:00Z", "2026-01-01T00:00:01Z"],
        );
        let conn = super::open_ro(&dir.path().join("db/messages.db")).unwrap();
        let mut cursors = super::current_cursors(&conn);
        assert_eq!((cursors.seq, cursors.legacy_id), (1, 2));
        assert!(super::read_new_messages(&conn, &mut cursors).unwrap().is_empty());

        add_linked(dir.path(), "live-event", "2026-01-01T00:00:02Z", None);
        let got = super::read_new_messages(&conn, &mut cursors).unwrap();
        assert_eq!(
            got.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            vec!["live-event"]
        );
        assert_eq!((cursors.seq, cursors.legacy_id), (2, 3));

        // A lagging legacy cursor advances over the mirror without repeating
        // the event that has already been observed.
        let mut legacy_behind = super::Cursors { seq: 2, legacy_id: 2 };
        assert!(super::read_new_messages(&conn, &mut legacy_behind).unwrap().is_empty());
        assert_eq!((legacy_behind.seq, legacy_behind.legacy_id), (2, 3));

        // The opposite skew must still emit the unseen event.
        let mut event_behind = super::Cursors { seq: 1, legacy_id: 3 };
        let got = super::read_new_messages(&conn, &mut event_behind).unwrap();
        assert_eq!(
            got.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            vec!["live-event"]
        );
        assert_eq!((event_behind.seq, event_behind.legacy_id), (2, 3));

        let mut reloaded = super::current_cursors(&conn);
        assert!(super::read_new_messages(&conn, &mut reloaded).unwrap().is_empty());
    }

    fn sqlite_store_info(path: &std::path::Path, exists: bool) -> super::StoreInfo {
        super::StoreInfo {
            driver: "sqlite".into(),
            path: path.to_string_lossy().into_owned(),
            exists,
        }
    }

    fn api_store_info() -> super::StoreInfo {
        super::StoreInfo { driver: "jsonl".into(), path: "/unused".into(), exists: true }
    }

    fn api_message(id: &str) -> super::Message {
        super::Message {
            id: id.into(), team: "t".into(), from: "leader".into(), to: "worker".into(),
            body: id.into(), created_at: "2026-01-01T00:00:00Z".into(),
        }
    }

    #[test]
    fn watcher_baseline_precedes_history_and_reuses_an_existing_store() {
        let dir = tempfile::tempdir().unwrap();
        store_with(dir.path(), &[("old", "2026-01-01T00:00:00Z")], &[]);
        let path = dir.path().join("db/messages.db");
        let watcher = super::MessageWatcher::default();
        let history = watcher.initial_history_with("t", 30, || Ok(sqlite_store_info(&path, true)), |_| {
            assert!(watcher.0.try_lock().is_err(), "history and polling must share the lock");
            let snapshot = vec![api_message("old")];
            // Arrives after the history snapshot but before the command returns.
            add_linked(dir.path(), "during-history", "2026-01-01T00:00:01Z", None);
            Ok(snapshot)
        }).unwrap();
        assert_eq!(history[0].id, "old");
        let fresh = watcher.0.lock().unwrap().poll_direct();
        assert_eq!(fresh.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["during-history"]);
        assert!(watcher.0.lock().unwrap().poll_direct().is_empty());

        add_linked(dir.path(), "before-reload", "2026-01-01T00:00:02Z", None);
        watcher.initial_history_with("another-team", 30, || Ok(sqlite_store_info(&path, true)), |_| {
            Ok(vec![api_message("before-reload")])
        }).unwrap();
        let mut stores = watcher.0.lock().unwrap();
        assert_eq!(stores.direct.len(), 1, "shared paths retain one connection and cursor pair");
        let fresh = stores.poll_direct();
        assert_eq!(fresh.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["before-reload"]);
    }

    #[test]
    fn watcher_pending_store_delivers_its_first_message_once() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("db/messages.db");
        let watcher = super::MessageWatcher::default();
        let history = watcher.initial_history_with("t", 30, || Ok(sqlite_store_info(&path, false)), |_| {
            panic!("a missing store must return empty without creating it through the API");
        }).unwrap();
        assert!(history.is_empty());
        assert!(!path.exists());
        assert!(watcher.0.lock().unwrap().poll_direct().is_empty());

        store_with(dir.path(), &[], &[]);
        add_linked(dir.path(), "first-send", "2026-01-01T00:00:00Z", None);
        let mut stores = watcher.0.lock().unwrap();
        let fresh = stores.poll_direct();
        assert_eq!(fresh.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["first-send"]);
        assert!(stores.poll_direct().is_empty());
    }

    #[test]
    fn watcher_pending_store_reload_retains_its_saved_zero_cursor() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("db/messages.db");
        let watcher = super::MessageWatcher::default();
        watcher.initial_history_with("t", 30, || Ok(sqlite_store_info(&path, false)), |_| {
            panic!("missing-store history must not run");
        }).unwrap();
        store_with(dir.path(), &[], &[]);
        add_linked(dir.path(), "first-send", "2026-01-01T00:00:00Z", None);
        watcher.initial_history_with("t", 30, || Ok(sqlite_store_info(&path, true)), |_| {
            Ok(vec![api_message("first-send")])
        }).unwrap();
        let fresh = watcher.0.lock().unwrap().poll_direct();
        assert_eq!(fresh.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["first-send"]);
    }

    #[test]
    fn watcher_failed_initialization_leaves_no_marker_and_can_retry() {
        let watcher = super::MessageWatcher::default();
        assert!(watcher.initial_history_with("t", 30, || Err("resolver failed".into()), |_| {
            Err("history also failed".into())
        }).is_err());
        assert!(watcher.0.lock().unwrap().direct.is_empty());
        assert!(watcher.0.lock().unwrap().via_api.is_empty());

        let dir = tempfile::tempdir().unwrap();
        store_with(dir.path(), &[("old", "2026-01-01T00:00:00Z")], &[]);
        let path = dir.path().join("db/messages.db");
        assert!(watcher.initial_history_with("t", 30, || Ok(sqlite_store_info(&path, true)), |_| {
            Err("history failed".into())
        }).is_err());
        assert!(watcher.0.lock().unwrap().direct.is_empty());
        watcher.initial_history_with("t", 30, || Ok(sqlite_store_info(&path, true)), |_| {
            Ok(vec![api_message("old")])
        }).unwrap();
        assert!(watcher.0.lock().unwrap().poll_direct().is_empty(), "old history is not a notification");
    }

    #[test]
    fn watcher_legacy_core_without_store_endpoint_uses_a_successful_api_baseline() {
        let watcher = super::MessageWatcher::default();
        let history = watcher.initial_history_with("t", 30, || Err("unknown endpoint: store".into()), |_| {
            Ok(vec![api_message("old")])
        }).unwrap();
        assert_eq!(history[0].id, "old");
        let mut stores = watcher.0.lock().unwrap();
        assert!(stores.direct.is_empty(), "resolver failure must not guess a database path");
        assert_eq!(stores.via_api, vec![("t".to_string(), Some("old".to_string()))]);
        let fresh = stores.poll_api_with(|_| Ok(vec![api_message("old"), api_message("new")]));
        assert_eq!(fresh.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["new"]);
    }

    #[test]
    fn watcher_api_empty_baseline_is_initialized_and_failures_remain_retryable() {
        let watcher = super::MessageWatcher::default();
        let mut calls = 0;
        assert!(watcher.initial_history_with("t", 30, || Ok(api_store_info()), |_| {
            calls += 1;
            if calls == 1 { Ok(Vec::new()) } else { Err("history failed".into()) }
        }).is_err());
        assert!(watcher.0.lock().unwrap().via_api.is_empty(), "even a successful baseline cannot hide history failure");
        watcher.initial_history_with("t", 30, || Ok(api_store_info()), |_| Ok(Vec::new())).unwrap();
        let mut stores = watcher.0.lock().unwrap();
        assert_eq!(stores.via_api, vec![("t".to_string(), None)]);
        assert!(stores.poll_api_with(|_| Err("temporary API failure".into())).is_empty());
        let fresh = stores.poll_api_with(|_| Ok(vec![api_message("first-send")]));
        assert_eq!(fresh.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["first-send"]);
        assert!(stores.poll_api_with(|_| Ok(vec![api_message("first-send")])).is_empty());
    }

    #[test]
    fn watcher_api_baseline_precedes_history_without_replaying_old_rows() {
        let watcher = super::MessageWatcher::default();
        let mut limits = Vec::new();
        watcher.initial_history_with("t", 30, || Ok(api_store_info()), |limit| {
            limits.push(limit);
            Ok(vec![api_message("old")])
        }).unwrap();
        assert_eq!(limits, [50, 30]);
        let fresh = watcher.0.lock().unwrap().poll_api_with(|_| {
            Ok(vec![api_message("old"), api_message("after-history")])
        });
        assert_eq!(fresh.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["after-history"]);
    }

    #[test]
    fn watcher_api_to_sqlite_transition_emits_each_new_message_once() {
        let dir = tempfile::tempdir().unwrap();
        store_with(dir.path(), &[], &[]);
        let path = dir.path().join("db/messages.db");
        let watcher = super::MessageWatcher::default();
        watcher.initial_history_with("t", 30, || Ok(api_store_info()), |_| Ok(Vec::new())).unwrap();
        add_linked(dir.path(), "before-transition", "2026-01-01T00:00:00Z", None);
        let mut stores = watcher.0.lock().unwrap();
        let revision = stores.revision;
        stores.discover_if_current("t", revision, Ok(sqlite_store_info(&path, true)), |_| {
            Ok(vec![api_message("before-transition")])
        }).unwrap();
        assert_eq!(stores.take_refreshes(), ["t"]);
        assert!(stores.take_refreshes().is_empty(), "refresh notifications are drained once");
        assert!(stores.via_api.is_empty(), "the obsolete API poller must be retired");
        assert!(stores.poll_direct().is_empty(), "transition history is not a pane kickoff");
        add_linked(dir.path(), "after-transition", "2026-01-01T00:00:00Z", None);
        let mut fresh = stores.poll_api_with(|_| panic!("no obsolete API poll"));
        fresh.extend(stores.poll_direct());
        assert_eq!(fresh.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["after-transition"]);
        assert!(stores.poll_direct().is_empty());
    }

    #[test]
    fn watcher_route_transitions_refresh_history_without_replaying_it() {
        for direction in ["api-to-direct", "direct-to-api", "direct-to-direct"] {
            let old = tempfile::tempdir().unwrap();
            let new = tempfile::tempdir().unwrap();
            store_with(old.path(), &[("old", "2026-01-01T00:00:00Z")], &[]);
            store_with(new.path(), &[("old", "2026-01-01T00:00:00Z")], &[]);
            let old_path = old.path().join("db/messages.db");
            let new_path = new.path().join("db/messages.db");
            let watcher = super::MessageWatcher::default();
            watcher.initial_history_with("t", 30, || Ok(if direction == "api-to-direct" {
                api_store_info()
            } else { sqlite_store_info(&old_path, true) }), |_| Ok(vec![api_message("old")])).unwrap();
            assert!(watcher.0.lock().unwrap().take_refreshes().is_empty());
            add_linked(new.path(), "before-transition", "2026-01-01T00:00:01Z", None);
            let to_api = direction == "direct-to-api";
            let mut calls = 0;
            let history = watcher.initial_history_with("t", 30, || Ok(if to_api {
                api_store_info()
            } else { sqlite_store_info(&new_path, true) }), |_| {
                calls += 1;
                if calls == 1 {
                    // The direct cursor/API baseline is already established;
                    // this row is also visible in the returned room history.
                    add_linked(new.path(), "overlap", "2026-01-01T00:00:02Z", None);
                }
                let mut rows = vec![api_message("old"), api_message("before-transition")];
                if !to_api || calls > 1 { rows.push(api_message("overlap")); }
                Ok(rows)
            }).unwrap();
            assert_eq!(history.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
                ["old", "before-transition", "overlap"], "{direction}");
            let mut stores = watcher.0.lock().unwrap();
            assert_eq!(stores.take_refreshes(), ["t"], "{direction}");
            let mut fresh = stores.poll_api_with(|_| Ok(history.clone()));
            fresh.extend(stores.poll_direct());
            assert_eq!(fresh.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["overlap"], "{direction}");
            assert!(stores.poll_api_with(|_| Ok(history.clone())).is_empty());
            assert!(stores.poll_direct().is_empty());
            add_linked(new.path(), "after-transition", "2026-01-01T00:00:03Z", None);
            let later = || { let mut rows = history.clone(); rows.push(api_message("after-transition")); rows };
            let mut fresh = stores.poll_api_with(|_| Ok(later()));
            fresh.extend(stores.poll_direct());
            assert_eq!(fresh.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["after-transition"], "{direction}");
            assert!(stores.poll_api_with(|_| Ok(later())).is_empty());
            assert!(stores.poll_direct().is_empty());
            assert!(stores.take_refreshes().is_empty());
        }
    }

    #[test]
    fn watcher_failed_transition_retains_the_previous_route() {
        for direction in ["api-to-direct", "direct-to-api", "direct-to-direct"] {
            let old = tempfile::tempdir().unwrap();
            let new = tempfile::tempdir().unwrap();
            store_with(old.path(), &[], &[]);
            store_with(new.path(), &[], &[]);
            let old_path = old.path().join("db/messages.db");
            let new_path = new.path().join("db/messages.db");
            let watcher = super::MessageWatcher::default();
            let old_info = || if direction == "api-to-direct" { api_store_info() } else { sqlite_store_info(&old_path, true) };
            watcher.initial_history_with("t", 30, || Ok(old_info()), |_| Ok(Vec::new())).unwrap();
            let mut stores = watcher.0.lock().unwrap();
            let revision = stores.revision;
            assert!(stores.discover_if_current("t", revision, Ok(if direction == "direct-to-api" {
                api_store_info()
            } else { sqlite_store_info(&new_path, true) }), |_| Err("history failed".into())).is_err());
            assert!(stores.knows("t", &old_info()), "{direction}");
            assert_eq!(stores.revision, revision);
            assert!(stores.take_refreshes().is_empty());
            add_linked(old.path(), "still-live", "2026-01-01T00:00:00Z", None);
            let mut fresh = stores.poll_api_with(|_| Ok(vec![api_message("still-live")]));
            fresh.extend(stores.poll_direct());
            assert_eq!(fresh.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["still-live"], "{direction}");
        }
    }

    #[test]
    fn watcher_known_route_survives_resolution_failure() {
        let dir = tempfile::tempdir().unwrap();
        store_with(dir.path(), &[], &[]);
        let path = dir.path().join("db/messages.db");
        let watcher = super::MessageWatcher::default();
        watcher.initial_history_with("t", 30, || Ok(sqlite_store_info(&path, true)), |_| Ok(Vec::new())).unwrap();
        let history = watcher.initial_history_with("t", 30, || Err("temporary lookup error".into()), |_| {
            Ok(vec![api_message("history")])
        }).unwrap();
        assert_eq!(history[0].id, "history");
        assert!(watcher.initial_history_with("t", 30, || Err("lookup failed".into()), |_| Err("history failed".into())).is_err());
        let mut stores = watcher.0.lock().unwrap();
        let revision = stores.revision;
        stores.discover_if_current("t", revision, Err("temporary lookup error".into()), |_| {
            panic!("background resolution failure must retain the established route");
        }).unwrap();
        assert!(stores.knows("t", &sqlite_store_info(&path, true)));
        assert!(stores.via_api.is_empty());
        assert!(stores.take_refreshes().is_empty());
        add_linked(dir.path(), "still-live", "2026-01-01T00:00:00Z", None);
        assert_eq!(stores.poll_direct()[0].id, "still-live");
    }

    #[test]
    fn watcher_shared_store_emits_unknown_team_before_discovery_once() {
        let dir = tempfile::tempdir().unwrap();
        store_with(dir.path(), &[], &[]);
        let path = dir.path().join("db/messages.db");
        let watcher = super::MessageWatcher::default();
        watcher.initial_history_with("t", 30, || Ok(sqlite_store_info(&path, true)), |_| Ok(Vec::new())).unwrap();
        add_linked(dir.path(), "new-team-first-send", "2026-01-01T00:00:00Z", None);
        let writer = rusqlite::Connection::open(&path).unwrap();
        writer.execute_batch("UPDATE messages SET team='new-team'; UPDATE events SET team='new-team';").unwrap();
        let mut stores = watcher.0.lock().unwrap();
        let fresh = stores.poll_direct();
        assert_eq!(fresh.iter().map(|m| (m.team.as_str(), m.id.as_str())).collect::<Vec<_>>(), [("new-team", "new-team-first-send")]);
        let revision = stores.revision;
        stores.discover_if_current("new-team", revision, Ok(sqlite_store_info(&path, true)), |_| Ok(fresh.clone())).unwrap();
        assert!(stores.poll_direct().is_empty());
        assert!(stores.take_refreshes().is_empty(), "first registration needs no route refresh");
    }

    #[test]
    fn watcher_shared_path_retains_cursors_and_filters_teams_that_changed_route() {
        let dir = tempfile::tempdir().unwrap();
        store_with(dir.path(), &[], &[]);
        let path = dir.path().join("db/messages.db");
        let watcher = super::MessageWatcher::default();
        for team in ["t", "other"] {
            watcher.initial_history_with(team, 30, || Ok(sqlite_store_info(&path, true)), |_| Ok(Vec::new())).unwrap();
        }
        add_linked(dir.path(), "old", "2026-01-01T00:00:00Z", None);
        assert_eq!(watcher.0.lock().unwrap().poll_direct().len(), 1);
        watcher.initial_history_with("t", 30, || Ok(api_store_info()), |_| Ok(vec![api_message("old")])).unwrap();
        let mut stores = watcher.0.lock().unwrap();
        assert_eq!(stores.direct.len(), 1, "the other team still references the shared path");
        assert_eq!((stores.direct[0].cursors.seq, stores.direct[0].cursors.legacy_id), (1, 1));
        add_linked(dir.path(), "new-t", "2026-01-01T00:00:01Z", None);
        add_linked(dir.path(), "new-other", "2026-01-01T00:00:02Z", None);
        let writer = rusqlite::Connection::open(&path).unwrap();
        writer.execute_batch("UPDATE messages SET team='other' WHERE id=3; UPDATE events SET team='other' WHERE seq=3;").unwrap();
        let mut fresh = stores.poll_direct();
        assert_eq!(fresh.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["new-other"]);
        fresh.extend(stores.poll_api_with(|_| Ok(vec![api_message("old"), api_message("new-t")])));
        assert_eq!(fresh.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["new-other", "new-t"]);
        assert_eq!((stores.direct[0].cursors.seq, stores.direct[0].cursors.legacy_id), (3, 3));
        stores.initial_history_with("other", 30, api_store_info(), |_| Ok(Vec::new())).unwrap();
        assert!(stores.direct.is_empty(), "the unreferenced direct connection can now retire");
    }

    #[test]
    fn watcher_stale_discovery_cannot_replace_a_newer_route() {
        let dir = tempfile::tempdir().unwrap();
        store_with(dir.path(), &[], &[]);
        let path = dir.path().join("db/messages.db");
        let watcher = super::MessageWatcher::default();
        watcher.initial_history_with("t", 30, || Ok(api_store_info()), |_| Ok(Vec::new())).unwrap();
        let revision = watcher.0.lock().unwrap().revision;
        watcher.initial_history_with("t", 30, || Ok(sqlite_store_info(&path, true)), |_| Ok(Vec::new())).unwrap();
        let mut stores = watcher.0.lock().unwrap();
        stores.discover_if_current("t", revision, Ok(api_store_info()), |_| {
            panic!("a resolver result predating the newer route must be discarded");
        }).unwrap();
        assert!(stores.knows("t", &sqlite_store_info(&path, true)));
        assert!(stores.via_api.is_empty());
    }

    #[test]
    fn watcher_open_errors_are_not_treated_as_missing_stores() {
        let dir = tempfile::tempdir().unwrap();
        let watcher = super::MessageWatcher::default();
        assert!(watcher.initial_history_with("t", 30, || Ok(sqlite_store_info(dir.path(), true)), |_| {
            panic!("opening a directory as a database must fail before history");
        }).is_err());
        assert!(watcher.0.lock().unwrap().direct.is_empty());
    }

    #[test]
    fn watcher_reported_existing_store_missing_is_retryable() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("db/messages.db");
        let watcher = super::MessageWatcher::default();
        assert!(watcher.initial_history_with("t", 30, || Ok(sqlite_store_info(&path, true)), |_| {
            panic!("a vanished reported store must fail before history");
        }).is_err());
        assert!(watcher.0.lock().unwrap().direct.is_empty());

        watcher.initial_history_with("t", 30, || Ok(sqlite_store_info(&path, false)), |_| {
            panic!("a genuinely new store has no history to query");
        }).unwrap();
        assert!(watcher.initial_history_with("t", 30, || Ok(sqlite_store_info(&path, true)), |_| {
            panic!("a pending store reported present but missing is also an error");
        }).is_err());
        let mut stores = watcher.0.lock().unwrap();
        assert_eq!(stores.direct.len(), 1);
        assert!(stores.direct[0].conn.is_none());
        assert_eq!((stores.direct[0].cursors.seq, stores.direct[0].cursors.legacy_id), (0, 0));
        store_with(dir.path(), &[], &[]);
        add_linked(dir.path(), "first-send", "2026-01-01T00:00:00Z", None);
        let fresh = stores.poll_direct();
        assert_eq!(fresh.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["first-send"]);
    }

    #[test]
    fn malformed_history_is_not_a_successful_empty_baseline() {
        assert!(super::parse_message_history("\n  \n").unwrap().is_empty());
        assert!(super::parse_message_history("not json").is_err());
        assert!(super::parse_message_history(r#"{"id":"missing-payload"}"#).is_err());
    }

    /// The released layout: a store from before the event log has no `events`
    /// table at all, so the whole UNION fails to prepare. History must still
    /// come through — the machine this was written on has 6,285 such rows.
    #[test]
    #[serial]
    fn history_still_arrives_from_a_store_that_predates_the_event_log() {
        let dir = tempfile::tempdir().unwrap();
        let _env = EnvGuard::set("AGMSG_APP_BASE", &dir.path().to_string_lossy());
        let db = dir.path().join("db");
        std::fs::create_dir_all(&db).unwrap();
        let conn = rusqlite::Connection::open(db.join("messages.db")).unwrap();
        conn.execute_batch(
            "CREATE TABLE messages (
               id INTEGER PRIMARY KEY AUTOINCREMENT, team TEXT NOT NULL,
               from_agent TEXT NOT NULL, to_agent TEXT NOT NULL, body TEXT NOT NULL,
               created_at TEXT NOT NULL, read_at TEXT);
             INSERT INTO messages(team,from_agent,to_agent,body,created_at)
               VALUES ('t','leader','worker','older than the event log',
                       '2026-06-01T00:00:00Z');",
        )
        .unwrap();
        drop(conn);

        let conn = super::open_ro(&dir.path().join("db/messages.db")).unwrap();
        let mut cursors = super::Cursors::default();
        let got = super::read_new_messages(&conn, &mut cursors).expect("read");

        assert_eq!(got.len(), 1, "a pre-event-log store must not read as empty");
        assert_eq!(got[0].body, "older than the event log");
    }

    /// The third axis: the app must read where agmsg says the store is, not
    /// where the app thinks it should be. Hardcoding the path is what let a
    /// storage-layout change break the app with nothing to notice.
    #[test]
    #[serial]
    fn the_store_path_comes_from_agmsg_not_from_a_guess() {
        let _base = fake_base(&[(
            "api.sh",
            r#"echo '{"team":"alpha","driver":"sqlite","partition":"per-team","path":"/somewhere/else/alpha.db","exists":true}'"#,
        )]);
        assert_eq!(
            super::direct_store_path(&super::store_info("alpha").unwrap()),
            Some(std::path::PathBuf::from("/somewhere/else/alpha.db")),
            "the reported path must be used verbatim — a layout the app has \
             never heard of has to work without the app changing"
        );
    }

    /// A driver this app cannot parse must send it back through `api.sh`,
    /// which is slower and correct. Returning "no messages" instead would be
    /// the same silent-empty failure as the bugs above.
    #[test]
    #[serial]
    fn an_unreadable_driver_falls_back_rather_than_showing_an_empty_room() {
        let _base = fake_base(&[(
            "api.sh",
            r#"echo '{"team":"alpha","driver":"jsonl","partition":"per-team","path":"/x/a.jsonl","exists":true}'"#,
        )]);
        assert_eq!(
            super::direct_store_path(&super::store_info("alpha").unwrap()),
            None,
            "an unknown driver must not be opened as sqlite"
        );
    }

    /// The fallback has to actually deliver, not merely be described.
    ///
    /// Written after noticing the previous commit claimed the watcher "falls
    /// back to going through api.sh" when it did no such thing: teams it
    /// could not read directly were simply skipped, so with no `store`
    /// endpoint deployed the app had no live updates at all. History still
    /// worked, which is exactly what made it invisible.
    #[test]
    #[serial]
    fn a_team_read_through_api_sh_still_delivers_new_messages() {
        let _base = fake_base(&[(
            "api.sh",
            r#"
if [ "$4" = "store" ]; then
  echo '{"team":"alpha","driver":"jsonl","partition":"per-team","path":"/x/a.jsonl","exists":true}'
  exit 0
fi
echo '{"type":"message_sent","id":"m1","team":"alpha","from":"a","to":"b","body":"first","at":"t1"}'
echo '{"type":"message_sent","id":"m2","team":"alpha","from":"a","to":"b","body":"second","at":"t2"}'
"#,
        )]);

        // First sight takes a watermark and emits nothing — the room loads
        // its own history.
        let mut stores = super::WatcherStores::default();
        stores.initial_history_with("alpha", 50, super::store_info("alpha").unwrap(), |limit| {
            super::message_history("alpha", limit, None)
        }).unwrap();
        let fresh = stores.poll_api_with(|team| super::message_history(team, 50, None));
        assert!(fresh.is_empty(), "history must not be replayed as live");
        assert_eq!(stores.via_api[0].1.as_deref(), Some("m2"));

        // A message the app has not seen is delivered.
        let (fresh, mark) = super::messages_after(super::message_history("alpha", 50, None).unwrap(), Some("m1"));
        assert_eq!(
            fresh.iter().map(|m| m.body.as_str()).collect::<Vec<_>>(),
            vec!["second"],
        );
        assert_eq!(mark.as_deref(), Some("m2"));

        // Nothing new means nothing emitted.
        let (fresh, _) = super::messages_after(super::message_history("alpha", 50, None).unwrap(), Some("m2"));
        assert!(fresh.is_empty(), "already-seen rows must not be re-emitted");
    }

    /// A team nobody has written to yet has no store. That is an empty room,
    /// not a failure, and must not be reported as one.
    #[test]
    #[serial]
    fn a_team_with_no_store_yet_is_not_an_error() {
        let _base = fake_base(&[(
            "api.sh",
            r#"echo '{"team":"alpha","driver":"sqlite","partition":"shared","path":"/x/db.sqlite","exists":false}'"#,
        )]);
        assert_eq!(
            super::direct_store_path(&super::store_info("alpha").unwrap()),
            Some(std::path::PathBuf::from("/x/db.sqlite")),
            "a missing direct store must remain watchable from cursor zero",
        );
    }
}
