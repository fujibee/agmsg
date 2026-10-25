//! Open requests from seats: a seat asks the team's app-user, in an ordinary
//! message, to open an add-on pane. The app lists the request and opens it only
//! when the person clicks. Nothing here runs because a message said so, and nothing
//! here grants anything: the pane's own consent card still asks for what it needs.
//!
//! A request is a line of the message body that is, as a whole line,
//!
//! ```text
//! agmsg-app open <addon-id> <pane>
//! agmsg-app open <addon-id> <pane> path=<rest of the line>
//! ```
//!
//! Only a whole line counts: not in the middle of a sentence, not a quoted line
//! (`>`), not inside a fenced code block. Anything else in the body is ignored. A
//! message with several such lines is several requests; a request's id is the
//! message id and the line's index in the body (`<message id>:<index>`).
//!
//! What is read: messages of the team being shown, addressed to its app-user.
//! Other recipients and other teams are never looked at. The sender is whatever
//! the store says; it is not verified, and the bar says so.
//!
//! What is checked, in order, for every request (a refusal is shown, never silent):
//! 1. the add-on is installed (or built in), enabled, and its files match what was pinned;
//! 2. the pane exists and the request carries exactly what that pane's `opens` allows;
//! 3. a path exists on this machine and is not a protected place.
//!
//! `addon_open_request_open` runs all of it again from the store (the UI's copy is
//! never trusted), records the request as handled, and returns what `addon_pane_add`
//! takes. There is no expiry. The record of handled ids is never trimmed (an old
//! message can therefore never become openable again), and one that cannot be read
//! or parsed stops requests from being shown at all (`state_unreadable`) rather than
//! being treated as empty.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tauri::State;

use super::catalog::AddonInfo;
use super::denylist::GrantCheck;
use super::host::AddonHost;
use super::panes::OpenArgs;

pub const VERB: &str = "agmsg-app open";
/// How many request-looking messages to a team's app-user one scan reads (the newest).
pub const SCAN_CAP: usize = 500;
const TYPE_APP: &str = "agmsg-app";

// ---------------------------------------------------------------------------
// The line
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub addon_id: String,
    pub pane: String,
    pub path: Option<String>,
    /// Index of the line in the body (0-based, counting every line).
    pub line: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Refusal {
    pub reason: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Parsed {
    Request(Request),
    /// Starts like a request but is not one the app can read.
    Refused { line: usize, refusal: Refusal },
}

impl Parsed {
    pub fn line(&self) -> usize {
        match self {
            Parsed::Request(r) => r.line,
            Parsed::Refused { line, .. } => *line,
        }
    }
}

fn refused(line: usize, reason: &'static str, detail: impl Into<Option<String>>) -> Parsed {
    Parsed::Refused { line, refusal: Refusal { reason, detail: detail.into() } }
}

fn addon_id_ok(s: &str) -> bool {
    !s.is_empty() && s.len() <= 128 && s != "." && s != ".." && s.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.' | b':' | b'/'))
}

fn pane_ok(s: &str) -> bool {
    !s.is_empty() && s.len() <= 100 && s != "." && s != ".." && s.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-'))
}

fn clip(s: &str) -> String {
    s.chars().take(80).collect()
}

/// Every request-looking line of one message body, in order. A line only counts
/// when it starts with the verb at column 0 (no indent), is not quoted, and is not
/// inside a fenced block; a line that is not a request at all is simply not here.
pub fn parse(body: &str) -> Vec<Parsed> {
    let norm = body.replace("\r\n", "\n");
    let mut out = Vec::new();
    let mut fence: Option<char> = None;
    for (idx, raw) in norm.split('\n').enumerate() {
        let lead = raw.trim_start();
        if lead.starts_with("```") || lead.starts_with("~~~") {
            let ch = lead.chars().next().unwrap();
            match fence {
                None => fence = Some(ch),
                Some(open) if open == ch => fence = None,
                Some(_) => {}
            }
            continue;
        }
        if fence.is_some() || lead.starts_with('>') {
            continue;
        }
        let line = raw.trim_end();
        let Some(rest) = line.strip_prefix(VERB) else { continue };
        if !(rest.is_empty() || rest.starts_with(' ')) {
            continue; // another word that happens to start the same: `agmsg-app opened …`
        }
        out.push(parse_line(idx, rest));
    }
    out
}

fn next_token(s: &str) -> (&str, &str) {
    let s = s.trim_start_matches(' ');
    match s.find(' ') {
        Some(i) => (&s[..i], s[i..].trim_start_matches(' ')),
        None => (s, ""),
    }
}

fn parse_line(idx: usize, rest: &str) -> Parsed {
    let (addon_id, rest) = next_token(rest);
    let (pane, rest) = next_token(rest);
    if addon_id.is_empty() || pane.is_empty() {
        return refused(idx, "missing_pane", None);
    }
    if !addon_id_ok(addon_id) {
        return refused(idx, "bad_addon", clip(addon_id));
    }
    if !pane_ok(pane) {
        return refused(idx, "bad_pane", clip(pane));
    }
    let path = if rest.is_empty() {
        None
    } else {
        let Some(p) = rest.strip_prefix("path=") else { return refused(idx, "bad_option", clip(rest)) };
        if p.is_empty() || p.len() > 4096 || p.contains(char::is_control) || !Path::new(p).is_absolute() {
            return refused(idx, "bad_path", "path: must be an absolute path".to_string());
        }
        Some(p.to_string())
    };
    Parsed::Request(Request { addon_id: addon_id.to_string(), pane: pane.to_string(), path, line: idx })
}

fn id_ok(s: &str) -> bool {
    !s.is_empty() && s.len() <= 128 && s.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.' | b':'))
}

/// The request id of one line of one message.
pub fn request_id(message_id: &str, line: usize) -> String {
    format!("{message_id}:{line}")
}

// ---------------------------------------------------------------------------
// What the app remembers: opened / dismissed, by request id
// ---------------------------------------------------------------------------

/// `<base>/addons/open-requests.tsv`: `request_id, team, state, at`. The app's own
/// record (it never writes the message store).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateRow {
    pub request_id: String,
    pub team: String,
    pub state: String,
    pub at: String,
}

static STATE_LOCK: Mutex<()> = Mutex::new(());

fn state_path(addons: &Path) -> PathBuf {
    addons.join("open-requests.tsv")
}

/// The handled-request record. A missing file is an empty history; a file that cannot be
/// read or has a line that does not parse is an error, never an empty history: the record
/// is what keeps a request from being acted on twice.
fn state_read(addons: &Path) -> io::Result<Vec<StateRow>> {
    let text = match fs::read_to_string(state_path(addons)) {
        Ok(t) => t,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e),
    };
    let mut rows = Vec::new();
    for l in text.lines().filter(|l| !l.trim().is_empty()) {
        let c: Vec<&str> = l.split('\t').collect();
        if !(c.len() == 4 && id_ok(c[0]) && matches!(c[2], "opened" | "dismissed")) {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "open-requests.tsv has a line that does not parse"));
        }
        rows.push(StateRow { request_id: c[0].into(), team: c[1].into(), state: c[2].into(), at: c[3].into() });
    }
    Ok(rows)
}

fn state_write(addons: &Path, rows: &[StateRow]) -> io::Result<()> {
    fs::create_dir_all(addons)?;
    let mut body = String::new();
    for r in rows {
        for f in [&r.request_id, &r.team, &r.at] {
            if f.contains(['\t', '\n', '\r']) {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid state row"));
            }
        }
        body.push_str(&[r.request_id.as_str(), &r.team, &r.state, &r.at].join("\t"));
        body.push('\n');
    }
    let tmp = addons.join(format!(".open-requests.tsv.{}.tmp", std::process::id()));
    {
        let mut f = fs::File::create(&tmp)?;
        f.write_all(body.as_bytes())?;
        f.sync_all()?;
    }
    fs::rename(&tmp, state_path(addons))
}

/// Records one decision, once per request id. Returns false when the id was already handled.
fn state_record(addons: &Path, row: StateRow) -> io::Result<bool> {
    let _g = STATE_LOCK.lock().unwrap();
    let mut all = state_read(addons)?;
    if all.iter().any(|r| r.request_id == row.request_id) {
        return Ok(false);
    }
    // never trimmed: a forgotten id could be acted on again (a row is under a hundred bytes)
    all.push(row);
    state_write(addons, &all)?;
    Ok(true)
}

// ---------------------------------------------------------------------------
// Where the rows come from
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub id: String,
    pub team: String,
    pub from: String,
    pub to: String,
    pub body: String,
    pub created_at: String,
}

fn table_exists(conn: &rusqlite::Connection, name: &str) -> bool {
    conn.query_row("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1", [name], |_| Ok(())).is_ok()
}

/// Messages to `app_user` that contain the verb (oldest first, at most `cap`, plus whether older ones were left out).
pub fn scan_sqlite(conn: &rusqlite::Connection, team: &str, app_user: &str, cap: usize) -> Result<(Vec<Candidate>, bool), String> {
    let limit = (cap + 1) as i64;
    let mut found: Vec<(Candidate, u8, i64)> = Vec::new();

    if table_exists(conn, "events") {
        let mut stmt = conn
            .prepare(
                "SELECT e.id, e.team, e.from_agent, e.to_agent, e.body, e.at, e.seq
                   FROM events e
                  WHERE e.type='message_sent' AND e.team=?1 AND e.to_agent=?2 AND instr(e.body, ?3) > 0
                  ORDER BY e.seq DESC LIMIT ?4",
            )
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(rusqlite::params![team, app_user, VERB, limit], |r| {
                Ok((Candidate { id: r.get(0)?, team: r.get(1)?, from: r.get(2)?, to: r.get(3)?, body: r.get(4)?, created_at: r.get(5)? }, 1u8, r.get::<_, i64>(6)?))
            })
            .map_err(|e| e.to_string())?;
        for r in rows {
            found.push(r.map_err(|e| e.to_string())?);
        }
    }

    if table_exists(conn, "messages") {
        // a legacy row that has a live event is the same message: the event copy is the one read above
        let base = "SELECT CAST(id AS TEXT), team, from_agent, to_agent, body, created_at, id FROM messages
                     WHERE team=?1 AND to_agent=?2 AND instr(body, ?3) > 0";
        let linked = format!("{base} AND NOT EXISTS (SELECT 1 FROM events e2 WHERE e2.legacy_id = messages.id AND e2.seq > 0) ORDER BY id DESC LIMIT ?4");
        let plain = format!("{base} ORDER BY id DESC LIMIT ?4");
        let mut stmt = match conn.prepare(&linked) {
            Ok(s) => s,
            // a store whose events table has no legacy_id (or no events table): there are no linked copies
            Err(_) => conn.prepare(&plain).map_err(|e| e.to_string())?,
        };
        let rows = stmt
            .query_map(rusqlite::params![team, app_user, VERB, limit], |r| {
                Ok((Candidate { id: r.get(0)?, team: r.get(1)?, from: r.get(2)?, to: r.get(3)?, body: r.get(4)?, created_at: r.get(5)? }, 0u8, r.get::<_, i64>(6)?))
            })
            .map_err(|e| e.to_string())?;
        for r in rows {
            found.push(r.map_err(|e| e.to_string())?);
        }
    }

    found.sort_by(|a, b| (&a.0.created_at, a.1, a.2).cmp(&(&b.0.created_at, b.1, b.2)));
    let truncated = found.len() > cap;
    if truncated {
        found.drain(..found.len() - cap);
    }
    Ok((found.into_iter().map(|f| f.0).collect(), truncated))
}

// ---------------------------------------------------------------------------
// The checks
// ---------------------------------------------------------------------------

/// What the app knows about a pane.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PaneState {
    Found { addon_id: String, pane: String, opens: Vec<String> },
    NotInstalled,
    /// Installed but cannot be opened (turned off, files changed, add-ons off on this computer).
    Unavailable(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PathState {
    /// The folder or file, as the machine resolves it.
    Exists(PathBuf),
    Missing,
    Denied,
}

pub trait Env {
    fn pane(&self, addon_id: &str, pane: &str) -> PaneState;
    fn path(&self, path: &str) -> PathState;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenSpec {
    pub addon_id: String,
    pub pane: String,
    pub open_args: OpenArgs,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Ready,
    /// Open disabled; `installTarget` names the add-on to offer.
    NotInstalled,
    Unavailable,
    ArgsNotAllowed,
    NotFoundHere,
    DeniedPath,
    /// The line is malformed (see `refusal`).
    Refused,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Evaluated {
    pub verdict: Verdict,
    pub detail: Option<String>,
    pub install_target: Option<String>,
    pub path_state: Option<&'static str>,
    pub spec: Option<OpenSpec>,
}

impl Evaluated {
    fn new(verdict: Verdict) -> Evaluated {
        Evaluated { verdict, detail: None, install_target: None, path_state: None, spec: None }
    }
}

/// `owner/repo` is something the person could install; a built-in or a developer copy is not.
fn installable(addon_id: &str) -> bool {
    let mut it = addon_id.split('/');
    matches!((it.next(), it.next(), it.next()), (Some(o), Some(r), None) if !o.is_empty() && !r.is_empty() && !o.contains(':'))
}

/// Runs the checks for one parsed request.
pub fn evaluate(req: &Request, env: &dyn Env) -> Evaluated {
    let mut out = Evaluated::new(Verdict::Ready);
    let (addon_id, pane, opens) = match env.pane(&req.addon_id, &req.pane) {
        PaneState::Found { addon_id, pane, opens } => (addon_id, pane, opens),
        PaneState::NotInstalled => {
            out.verdict = Verdict::NotInstalled;
            if installable(&req.addon_id) {
                out.install_target = Some(req.addon_id.clone());
            }
            return out;
        }
        PaneState::Unavailable(why) => {
            out.verdict = Verdict::Unavailable;
            out.detail = Some(why);
            return out;
        }
    };
    // a seat can only name a path; a pane that opens on a url (or on nothing) cannot be asked for here
    let wants_path = opens.iter().any(|o| o == "path");
    let wants_url = opens.iter().any(|o| o == "url");
    if wants_url {
        out.verdict = Verdict::ArgsNotAllowed;
        out.detail = Some("This pane opens on a web address, which a request cannot carry.".into());
        return out;
    }
    if req.path.is_some() && !wants_path {
        out.verdict = Verdict::ArgsNotAllowed;
        out.detail = Some("This pane does not take a path.".into());
        return out;
    }
    if req.path.is_none() && wants_path {
        out.verdict = Verdict::ArgsNotAllowed;
        out.detail = Some("This pane needs a path.".into());
        return out;
    }
    let mut open_args = OpenArgs { path: None, url: None, base: None };
    if let Some(p) = &req.path {
        match env.path(p) {
            PathState::Exists(real) => {
                out.path_state = Some("exists");
                open_args.path = Some(real.to_string_lossy().into_owned());
            }
            PathState::Missing => {
                out.path_state = Some("missing");
                out.verdict = Verdict::NotFoundHere;
                return out;
            }
            PathState::Denied => {
                out.path_state = Some("denied");
                out.verdict = Verdict::DeniedPath;
                out.detail = Some("That location is protected; an add-on pane is never opened on it.".into());
                return out;
            }
        }
    }
    out.spec = Some(OpenSpec { addon_id, pane, open_args });
    out
}

// ---------------------------------------------------------------------------
// One scan
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenRow {
    /// `<message id>:<line index>`.
    pub request_id: String,
    /// The message id.
    pub id: String,
    pub team: String,
    pub from: String,
    #[serde(rename = "created_at")]
    pub created_at: String,
    /// What the line asked for (absent when it was refused before that was known).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub addon_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    pub verdict: Verdict,
    /// Words for the bar when the verdict says why.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub install_target: Option<String>,
    /// `exists` | `missing` | `denied`; absent when the request has no path.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path_state: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refusal: Option<Refusal>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenScan {
    pub app_user: Option<String>,
    pub rows: Vec<OpenRow>,
    /// Older request-looking messages were left out (more than `SCAN_CAP`).
    pub truncated: bool,
    /// Why there is nothing to show, when that is not "nothing was sent".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notice: Option<String>,
}

/// One request line found again from the store by its request id.
struct Found {
    candidate: Candidate,
    parsed: Parsed,
    evaluated: Evaluated,
}

/// Turns candidates into rows, leaving out the ids already handled.
fn assemble(cands: &[Candidate], handled: &HashSet<String>, env: &dyn Env) -> (Vec<OpenRow>, Vec<Found>) {
    let mut rows = Vec::new();
    let mut found = Vec::new();
    for c in cands {
        for p in parse(&c.body) {
            let rid = request_id(&c.id, p.line());
            if handled.contains(&rid) {
                continue;
            }
            let mut row = OpenRow {
                request_id: rid.clone(),
                id: c.id.clone(),
                team: c.team.clone(),
                from: c.from.clone(),
                created_at: c.created_at.clone(),
                addon_id: None,
                pane: None,
                path: None,
                verdict: Verdict::Refused,
                detail: None,
                install_target: None,
                path_state: None,
                refusal: None,
            };
            let ev = match &p {
                // a message id the record could not hold would make the whole record unreadable: never record it
                _ if !id_ok(&rid) => {
                    row.refusal = Some(Refusal { reason: "bad_message_id", detail: None });
                    Evaluated::new(Verdict::Refused)
                }
                Parsed::Refused { refusal, .. } => {
                    row.detail = refusal.detail.clone();
                    row.refusal = Some(refusal.clone());
                    Evaluated::new(Verdict::Refused)
                }
                Parsed::Request(req) => {
                    row.addon_id = Some(req.addon_id.clone());
                    row.pane = Some(req.pane.clone());
                    row.path = req.path.clone();
                    let ev = evaluate(req, env);
                    row.verdict = ev.verdict;
                    row.detail = ev.detail.clone();
                    row.install_target = ev.install_target.clone();
                    row.path_state = ev.path_state;
                    ev
                }
            };
            rows.push(row);
            if id_ok(&rid) {
                found.push(Found { candidate: c.clone(), parsed: p, evaluated: ev });
            }
        }
    }
    (rows, found)
}

// ---------------------------------------------------------------------------
// The host side
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct OpenError {
    pub code: &'static str,
    pub message: String,
}

fn err(code: &'static str, message: impl Into<String>) -> OpenError {
    OpenError { code, message: message.into() }
}

struct HostEnv<'a> {
    host: &'a AddonHost,
    /// Read once, and only if a request gets as far as asking about a pane (it hashes every add-on's files).
    list: std::cell::OnceCell<Vec<AddonInfo>>,
    off: Option<String>,
}

impl<'a> HostEnv<'a> {
    fn new(host: &'a AddonHost) -> HostEnv<'a> {
        let v = host.gate.status();
        let off = (!v.enabled).then(|| format!("add-ons are off on this computer: {}", v.reasons.join("; ")));
        HostEnv { host, list: std::cell::OnceCell::new(), off }
    }
}

impl Env for HostEnv<'_> {
    fn pane(&self, addon_id: &str, pane: &str) -> PaneState {
        if let Some(why) = &self.off {
            return PaneState::Unavailable(why.clone());
        }
        let list = self.list.get_or_init(|| self.host.catalog().list());
        let Some(info) = list.iter().find(|a| a.id == addon_id) else { return PaneState::NotInstalled };
        if !info.enabled {
            return PaneState::Unavailable("That add-on is turned off.".into());
        }
        if !info.digest_ok {
            return PaneState::Unavailable("That add-on's files are incomplete or were changed after install.".into());
        }
        match info.panes.iter().find(|p| p.name == pane) {
            Some(p) => PaneState::Found { addon_id: addon_id.to_string(), pane: pane.to_string(), opens: p.opens.clone() },
            None => PaneState::NotInstalled,
        }
    }

    fn path(&self, path: &str) -> PathState {
        let Ok(real) = fs::canonicalize(path) else { return PathState::Missing };
        self.host.panes.refresh_deny();
        match self.host.panes.deny().check_grant_root(&real) {
            GrantCheck::Denied(_) => PathState::Denied,
            _ => PathState::Exists(real),
        }
    }
}

/// The team's app-user: exactly one member of type `agmsg-app`.
fn app_user_of(team: &str) -> Result<Option<String>, OpenError> {
    let members = crate::agmsg::agmsg_members(team.to_string()).map_err(|e| err("members_failed", e))?;
    let mut apps = members.into_iter().filter(|m| m.types.iter().any(|t| t == TYPE_APP)).map(|m| m.name);
    let first = apps.next();
    if apps.next().is_some() {
        return Err(err("several_app_users", "This team has more than one app-user, so requests are not shown."));
    }
    Ok(first)
}

fn candidates(team: &str, app_user: &str) -> Result<(Vec<Candidate>, bool), OpenError> {
    use crate::agmsg::TeamStore;
    match crate::agmsg::team_store(team) {
        TeamStore::Empty => Ok((Vec::new(), false)),
        TeamStore::Sqlite(path) => {
            let conn = crate::agmsg::open_store_ro(&path).map_err(|e| err("store_failed", e))?;
            scan_sqlite(&conn, team, app_user, SCAN_CAP).map_err(|e| err("store_failed", e))
        }
        TeamStore::Api => {
            let msgs = crate::agmsg::api_recent_messages(team, 200).map_err(|e| err("store_failed", e))?;
            let cands = msgs
                .into_iter()
                .filter(|m| m.team == team && m.to == app_user && m.body.contains(VERB))
                .map(|m| Candidate { id: m.id, team: m.team, from: m.from, to: m.to, body: m.body, created_at: m.created_at })
                .collect();
            Ok((cands, false))
        }
    }
}

fn handled_set(host: &AddonHost) -> Result<HashSet<String>, OpenError> {
    state_read(host.catalog().addons_dir())
        .map(|rows| rows.into_iter().map(|r| r.request_id).collect())
        .map_err(|e| err("state_unreadable", format!("The record of handled requests cannot be read, so requests are not shown: {e}")))
}

fn scan_with(host: &AddonHost, team: &str, app_user: &str) -> Result<(OpenScan, Vec<Found>), OpenError> {
    let (cands, truncated) = candidates(team, app_user)?;
    let handled = handled_set(host)?;
    let env = HostEnv::new(host);
    let (rows, found) = assemble(&cands, &handled, &env);
    Ok((OpenScan { app_user: Some(app_user.to_string()), rows, truncated, notice: None }, found))
}

/// The team's open requests, checked. Call it when the tab opens and when a message to the app-user arrives.
#[tauri::command(async)]
pub fn addon_open_requests(host: State<'_, Arc<AddonHost>>, team: String) -> Result<OpenScan, OpenError> {
    match app_user_of(&team) {
        Ok(Some(user)) => scan_with(&host, &team, &user).map(|(s, _)| s),
        Ok(None) => Ok(OpenScan { app_user: None, rows: Vec::new(), truncated: false, notice: Some("This team has no app-user, so it cannot receive open requests.".into()) }),
        Err(e) if e.code == "several_app_users" => Ok(OpenScan { app_user: None, rows: Vec::new(), truncated: false, notice: Some(e.message) }),
        Err(e) => Err(e),
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RequestIn {
    pub team: String,
    pub request_id: String,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct OpenedRequest {
    pub request_id: String,
    pub from: String,
    /// Pass these to `addon_pane_add` as `spec`.
    pub addon_id: String,
    pub pane: String,
    pub open_args: OpenArgs,
}

fn verdict_message(v: Verdict, detail: &Option<String>) -> String {
    let base = match v {
        Verdict::Ready => "ready",
        Verdict::NotInstalled => "That pane is not installed.",
        Verdict::Unavailable => "That pane cannot be opened right now.",
        Verdict::ArgsNotAllowed => "The request does not match what that pane opens with.",
        Verdict::NotFoundHere => "That path was not found on this computer.",
        Verdict::DeniedPath => "That location is protected.",
        Verdict::Refused => "The request is malformed.",
    };
    match detail {
        Some(d) => format!("{base} {d}"),
        None => base.to_string(),
    }
}

fn now_iso() -> String {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    super::broker::iso8601(secs)
}

/// The click on Open: everything is checked again from the store, the decision is
/// recorded against the request id, and the pane to create is returned.
#[tauri::command(async)]
pub fn addon_open_request_open(host: State<'_, Arc<AddonHost>>, spec: RequestIn) -> Result<OpenedRequest, OpenError> {
    let user = app_user_of(&spec.team)?.ok_or_else(|| err("no_app_user", "This team has no app-user."))?;
    let (_, found) = scan_with(&host, &spec.team, &user)?;
    let hit = found
        .into_iter()
        .find(|f| request_id(&f.candidate.id, f.parsed.line()) == spec.request_id)
        .ok_or_else(|| err("not_found", "That request is no longer there, or was already handled."))?;
    if hit.evaluated.verdict != Verdict::Ready {
        return Err(err("not_openable", verdict_message(hit.evaluated.verdict, &hit.evaluated.detail)));
    }
    let open = hit.evaluated.spec.clone().ok_or_else(|| err("not_openable", "nothing to open"))?;
    let recorded = state_record(host.catalog().addons_dir(), StateRow { request_id: spec.request_id.clone(), team: spec.team.clone(), state: "opened".into(), at: now_iso() })
        .map_err(|e| err("state_failed", e.to_string()))?;
    if !recorded {
        return Err(err("not_found", "That request was already handled."));
    }
    eprintln!("[addons] open request {} from {} → {}/{} (opened)", spec.request_id, hit.candidate.from, open.addon_id, open.pane);
    Ok(OpenedRequest { request_id: spec.request_id, from: hit.candidate.from, addon_id: open.addon_id, pane: open.pane, open_args: open.open_args })
}

/// Dismisses a request (or a refused line) so it is not listed again.
#[tauri::command(async)]
pub fn addon_open_request_dismiss(host: State<'_, Arc<AddonHost>>, spec: RequestIn) -> Result<(), OpenError> {
    let user = app_user_of(&spec.team)?.ok_or_else(|| err("no_app_user", "This team has no app-user."))?;
    let (cands, _) = candidates(&spec.team, &user)?;
    // only a line that is really in this team's store can be recorded: the record is not a place for arbitrary text
    let there = cands.iter().any(|c| parse(&c.body).iter().any(|p| request_id(&c.id, p.line()) == spec.request_id));
    if !there || !id_ok(&spec.request_id) {
        return Err(err("not_found", "That request is no longer there."));
    }
    state_record(host.catalog().addons_dir(), StateRow { request_id: spec.request_id, team: spec.team, state: "dismissed".into(), at: now_iso() }).map_err(|e| err("state_failed", e.to_string()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use std::collections::BTreeMap;

    fn reqs(body: &str) -> Vec<Request> {
        parse(body).into_iter().filter_map(|p| if let Parsed::Request(r) = p { Some(r) } else { None }).collect()
    }

    fn reason(body: &str) -> &'static str {
        match parse(body).as_slice() {
            [Parsed::Refused { refusal, .. }] => refusal.reason,
            other => panic!("not one refusal: {other:?}"),
        }
    }

    // ---- the line ----

    #[test]
    fn a_whole_line_is_a_request() {
        let r = reqs("agmsg-app open builtin:fileview fileview path=/Users/me/my project");
        assert_eq!(r, vec![Request { addon_id: "builtin:fileview".into(), pane: "fileview".into(), path: Some("/Users/me/my project".into()), line: 0 }]);
        let r = reqs("hello,\nplease open it\nagmsg-app open o/r viewer\nthanks");
        assert_eq!(r, vec![Request { addon_id: "o/r".into(), pane: "viewer".into(), path: None, line: 2 }]);
    }

    #[test]
    fn crlf_trailing_spaces_and_extra_spaces_between_words_are_fine() {
        let r = reqs("agmsg-app open  o/r   viewer   path=/a b  \r\nagmsg-app open o/r p\r\n");
        assert_eq!(r.len(), 2);
        assert_eq!(r[0].path.as_deref(), Some("/a b"), "the path is the rest of the line, inner spaces kept, trailing ones dropped");
        assert_eq!(r[1].line, 1);
    }

    #[test]
    fn only_a_whole_line_counts() {
        for b in [
            "please agmsg-app open o/r viewer",
            "I said: agmsg-app open o/r viewer",
            " agmsg-app open o/r viewer",
            "\tagmsg-app open o/r viewer",
            "> agmsg-app open o/r viewer",
            ">agmsg-app open o/r viewer",
            "  > agmsg-app open o/r viewer",
            "```\nagmsg-app open o/r viewer\n```",
            "~~~\nagmsg-app open o/r viewer\n~~~",
            "```text\nagmsg-app open o/r viewer",
            "agmsg-app opened o/r viewer",
            "agmsg-app close o/r viewer",
            "agmsg-app",
            "AGMSG-APP open o/r viewer",
            "agmsg-appopen o/r viewer",
        ] {
            assert!(parse(b).is_empty(), "{b:?}");
        }
    }

    #[test]
    fn a_fence_ends_and_the_lines_after_it_count_again() {
        let b = "```\nagmsg-app open o/r a\n```\nagmsg-app open o/r b\n~~~\nagmsg-app open o/r c\n~~~\nagmsg-app open o/r d";
        let ids: Vec<(String, usize)> = reqs(b).into_iter().map(|r| (r.pane, r.line)).collect();
        assert_eq!(ids, vec![("b".into(), 3), ("d".into(), 7)]);
        // a different fence marker inside a fence does not close it
        assert!(parse("```\n~~~\nagmsg-app open o/r a\n```").is_empty());
    }

    #[test]
    fn several_lines_are_several_requests_with_the_line_index_in_the_id() {
        let r = reqs("agmsg-app open o/r a\n\nagmsg-app open o/r b path=/x");
        assert_eq!(r.iter().map(|r| r.line).collect::<Vec<_>>(), vec![0, 2]);
        assert_eq!(request_id("m-9", r[1].line), "m-9:2");
    }

    #[test]
    fn a_line_that_starts_right_but_is_not_readable_is_refused_with_a_reason() {
        assert_eq!(reason("agmsg-app open"), "missing_pane");
        assert_eq!(reason("agmsg-app open o/r"), "missing_pane");
        assert_eq!(reason("agmsg-app open o/r viewer extra"), "bad_option");
        assert_eq!(reason("agmsg-app open o/r viewer url=https://x"), "bad_option");
        assert_eq!(reason("agmsg-app open o/r viewer path="), "bad_path");
        assert_eq!(reason("agmsg-app open o/r viewer path=relative/dir"), "bad_path");
        assert_eq!(reason("agmsg-app open o/r viewer path=/a\u{0}b"), "bad_path");
        assert_eq!(reason("agmsg-app open o;r viewer"), "bad_addon");
        assert_eq!(reason("agmsg-app open .. viewer"), "bad_addon");
        assert_eq!(reason("agmsg-app open o/r vie/wer"), "bad_pane");
        assert_eq!(reason(&format!("agmsg-app open o/r viewer path=/{}", "a".repeat(5000))), "bad_path");
        assert_eq!(reason(&format!("agmsg-app open {} viewer", "a".repeat(200))), "bad_addon");
    }

    // ---- the checks ----

    struct FakeEnv {
        panes: BTreeMap<(String, String), PaneState>,
        paths: BTreeMap<String, PathState>,
    }

    impl Env for FakeEnv {
        fn pane(&self, id: &str, pane: &str) -> PaneState {
            self.panes.get(&(id.to_string(), pane.to_string())).cloned().unwrap_or(PaneState::NotInstalled)
        }
        fn path(&self, p: &str) -> PathState {
            self.paths.get(p).cloned().unwrap_or(PathState::Missing)
        }
    }

    fn env() -> FakeEnv {
        let mut panes = BTreeMap::new();
        let found = |id: &str, pane: &str, opens: &[&str]| (( id.to_string(), pane.to_string()), PaneState::Found { addon_id: id.into(), pane: pane.into(), opens: opens.iter().map(|s| s.to_string()).collect() });
        panes.extend([
            found("builtin:fileview", "fileview", &["path"]),
            found("o/r", "viewer", &[]),
            found("o/r", "webview", &["url"]),
        ]);
        panes.insert(("o/r".into(), "off".into()), PaneState::Unavailable("That add-on is turned off.".into()));
        let mut paths = BTreeMap::new();
        paths.insert("/proj".into(), PathState::Exists(PathBuf::from("/real/proj")));
        paths.insert("/ssh".into(), PathState::Denied);
        FakeEnv { panes, paths }
    }

    fn req(id: &str, pane: &str, path: Option<&str>) -> Request {
        Request { addon_id: id.into(), pane: pane.into(), path: path.map(String::from), line: 0 }
    }

    #[test]
    fn a_request_is_ready_only_when_every_check_passes() {
        let e = env();
        let ok = evaluate(&req("builtin:fileview", "fileview", Some("/proj")), &e);
        assert_eq!(ok.verdict, Verdict::Ready);
        assert_eq!(ok.spec.unwrap().open_args.path.as_deref(), Some("/real/proj"), "the resolved path is what opens");
        let ok = evaluate(&req("o/r", "viewer", None), &e);
        assert_eq!(ok.verdict, Verdict::Ready);
        assert_eq!(evaluate(&req("builtin:fileview", "fileview", Some("/gone")), &e).verdict, Verdict::NotFoundHere);
        assert_eq!(evaluate(&req("builtin:fileview", "fileview", Some("/ssh")), &e).verdict, Verdict::DeniedPath);
        assert_eq!(evaluate(&req("builtin:fileview", "fileview", None), &e).verdict, Verdict::ArgsNotAllowed);
        assert_eq!(evaluate(&req("o/r", "viewer", Some("/proj")), &e).verdict, Verdict::ArgsNotAllowed);
        assert_eq!(evaluate(&req("o/r", "webview", None), &e).verdict, Verdict::ArgsNotAllowed);
        assert_eq!(evaluate(&req("o/r", "off", None), &e).verdict, Verdict::Unavailable);
        assert_eq!(evaluate(&req("o/r", "nope", None), &e).verdict, Verdict::NotInstalled);
    }

    #[test]
    fn only_an_owner_repo_is_offered_for_install() {
        let e = env();
        assert_eq!(evaluate(&req("someone/viewer", "p", None), &e).install_target.as_deref(), Some("someone/viewer"));
        assert_eq!(evaluate(&req("builtin:nothing", "p", None), &e).install_target, None);
        assert_eq!(evaluate(&req("dev:x", "p", None), &e).install_target, None);
    }

    // ---- one scan ----

    fn cand(id: &str, from: &str, body: &str) -> Candidate {
        Candidate { id: id.into(), team: "t".into(), from: from.into(), to: "me".into(), body: body.into(), created_at: format!("2026-10-25T00:00:0{id}Z") }
    }

    #[test]
    fn rows_carry_what_the_bar_needs_and_handled_ids_are_left_out() {
        let e = env();
        let cands = [cand("1", "alice", "agmsg-app open builtin:fileview fileview path=/proj\nagmsg-app open o/r viewer")];
        let (rows, found) = assemble(&cands, &HashSet::new(), &e);
        assert_eq!(rows.iter().map(|r| r.request_id.as_str()).collect::<Vec<_>>(), vec!["1:0", "1:1"]);
        assert_eq!(found.len(), 2);
        let j = serde_json::to_value(&rows[0]).unwrap();
        assert_eq!(j["verdict"], "ready");
        assert_eq!(j["from"], "alice");
        assert_eq!(j["team"], "t");
        assert_eq!(j["addonId"], "builtin:fileview");
        assert_eq!(j["pane"], "fileview");
        assert_eq!(j["path"], "/proj");
        assert_eq!(j["pathState"], "exists");
        assert_eq!(j["created_at"], "2026-10-25T00:00:01Z");
        assert!(j.get("body").is_none(), "the message text is not sent to the UI");
        let handled: HashSet<String> = ["1:0".to_string()].into();
        let (rows, found) = assemble(&cands, &handled, &e);
        assert_eq!(rows.iter().map(|r| r.request_id.as_str()).collect::<Vec<_>>(), vec!["1:1"]);
        assert_eq!(found.len(), 1);
    }

    #[test]
    fn a_refused_line_is_a_row_with_its_reason_and_can_be_handled_too() {
        let e = env();
        let (rows, found) = assemble(&[cand("1", "alice", "agmsg-app open o/r viewer junk")], &HashSet::new(), &e);
        assert_eq!(rows[0].verdict, Verdict::Refused);
        assert_eq!(rows[0].refusal.as_ref().map(|r| r.reason), Some("bad_option"));
        assert_eq!(found.len(), 1, "it can be dismissed");
        let handled: HashSet<String> = ["1:0".to_string()].into();
        assert!(assemble(&[cand("1", "alice", "agmsg-app open o/r viewer junk")], &handled, &e).0.is_empty());
    }

    #[test]
    fn a_message_id_the_record_cannot_hold_is_refused_and_never_dismissable() {
        let e = env();
        let (rows, found) = assemble(&[cand("a\tb", "alice", "agmsg-app open o/r viewer")], &HashSet::new(), &e);
        assert_eq!(rows[0].verdict, Verdict::Refused);
        assert_eq!(rows[0].refusal.as_ref().map(|r| r.reason), Some("bad_message_id"));
        assert!(found.is_empty());
    }

    // ---- the store ----

    fn store(with_legacy_id: bool) -> Connection {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch(&format!(
            "CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, id TEXT NOT NULL, team TEXT, from_agent TEXT, to_agent TEXT, body TEXT, msg_id TEXT, agent TEXT, at TEXT NOT NULL{});
             CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, team TEXT NOT NULL, from_agent TEXT NOT NULL, to_agent TEXT NOT NULL, body TEXT NOT NULL, created_at TEXT NOT NULL, read_at TEXT);",
            if with_legacy_id { ", legacy_id INTEGER" } else { "" }
        ))
        .unwrap();
        c
    }

    fn event(c: &Connection, id: &str, team: &str, from: &str, to: &str, body: &str, at: &str) {
        c.execute("INSERT INTO events (type, id, team, from_agent, to_agent, body, at) VALUES ('message_sent', ?1, ?2, ?3, ?4, ?5, ?6)", rusqlite::params![id, team, from, to, body, at]).unwrap();
    }

    const LINE: &str = "agmsg-app open o/r viewer";

    #[test]
    fn only_this_teams_messages_to_the_app_user_are_read() {
        let c = store(true);
        event(&c, "e1", "t", "alice", "me", LINE, "2026-10-25T00:00:01Z");
        event(&c, "e2", "t", "alice", "someone-else", LINE, "2026-10-25T00:00:02Z");
        event(&c, "e3", "other", "alice", "me", LINE, "2026-10-25T00:00:03Z");
        event(&c, "e4", "t", "alice", "me", "an ordinary message", "2026-10-25T00:00:04Z");
        c.execute("INSERT INTO messages (team, from_agent, to_agent, body, created_at) VALUES ('t','bob','me',?1,'2026-10-25T00:00:05Z')", [LINE]).unwrap();
        c.execute("INSERT INTO messages (team, from_agent, to_agent, body, created_at) VALUES ('other','bob','me',?1,'2026-10-25T00:00:06Z')", [LINE]).unwrap();
        c.execute("INSERT INTO messages (team, from_agent, to_agent, body, created_at) VALUES ('t','bob','x',?1,'2026-10-25T00:00:07Z')", [LINE]).unwrap();
        let (cands, truncated) = scan_sqlite(&c, "t", "me", 10).unwrap();
        assert!(!truncated);
        assert_eq!(cands.iter().map(|c| (c.id.as_str(), c.from.as_str())).collect::<Vec<_>>(), vec![("e1", "alice"), ("1", "bob")]);
    }

    #[test]
    fn a_legacy_row_that_has_a_live_event_is_one_message() {
        let c = store(true);
        c.execute("INSERT INTO messages (team, from_agent, to_agent, body, created_at) VALUES ('t','alice','me',?1,'2026-10-25T00:00:01Z')", [LINE]).unwrap();
        c.execute("INSERT INTO events (type, id, team, from_agent, to_agent, body, at, legacy_id) VALUES ('message_sent','e1','t','alice','me',?1,'2026-10-25T00:00:01Z', 1)", [LINE]).unwrap();
        let (cands, _) = scan_sqlite(&c, "t", "me", 10).unwrap();
        assert_eq!(cands.len(), 1);
        assert_eq!(cands[0].id, "e1");
        // a store with no legacy_id column has no linked copies and still reads
        let c = store(false);
        c.execute("INSERT INTO messages (team, from_agent, to_agent, body, created_at) VALUES ('t','alice','me',?1,'2026-10-25T00:00:01Z')", [LINE]).unwrap();
        assert_eq!(scan_sqlite(&c, "t", "me", 10).unwrap().0.len(), 1);
    }

    #[test]
    fn a_long_history_is_cut_at_the_newest_and_says_so() {
        let c = store(true);
        for i in 0..5 {
            event(&c, &format!("e{i}"), "t", "alice", "me", LINE, &format!("2026-10-25T00:00:0{i}Z"));
        }
        let (cands, truncated) = scan_sqlite(&c, "t", "me", 3).unwrap();
        assert!(truncated);
        assert_eq!(cands.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(), vec!["e2", "e3", "e4"]);
    }

    // ---- the state file ----

    fn row(id: &str) -> StateRow {
        StateRow { request_id: id.into(), team: "t".into(), state: "opened".into(), at: "2026-10-25T00:00:00Z".into() }
    }

    #[test]
    fn a_decision_is_recorded_once_and_survives_a_restart() {
        let d = tempfile::tempdir().unwrap();
        assert!(state_record(d.path(), row("m1:0")).unwrap());
        assert!(!state_record(d.path(), row("m1:0")).unwrap(), "the second click on the same id does nothing");
        assert!(state_record(d.path(), row("m1:1")).unwrap());
        let ids: HashSet<String> = state_read(d.path()).unwrap().into_iter().map(|r| r.request_id).collect();
        assert_eq!(ids, ["m1:0".to_string(), "m1:1".to_string()].into());
    }

    #[test]
    fn a_record_that_cannot_be_read_is_an_error_not_an_empty_history() {
        let d = tempfile::tempdir().unwrap();
        assert!(state_read(d.path()).unwrap().is_empty(), "no file yet is an empty history");
        fs::write(state_path(d.path()), "m3:0\tt\topened\tat\n").unwrap();
        assert_eq!(state_read(d.path()).unwrap().len(), 1);
        for bad in ["m1:0\tt\topened\n", "\u{0}bad\n", "m2 x\tt\topened\tat\n", "m1:0\tt\tweird\tat\n", "m1:0\tt\topened\tat\textra\n"] {
            fs::write(state_path(d.path()), format!("m3:0\tt\topened\tat\n{bad}")).unwrap();
            assert!(state_read(d.path()).is_err(), "{bad:?}");
            // and a new decision is not recorded on top of a record that cannot be trusted
            assert!(state_record(d.path(), row("m9:0")).is_err());
        }
        // a path that is a directory is unreadable too
        let d = tempfile::tempdir().unwrap();
        fs::create_dir(state_path(d.path())).unwrap();
        assert!(state_read(d.path()).is_err());
    }

    #[test]
    fn handled_ids_are_never_forgotten() {
        let d = tempfile::tempdir().unwrap();
        for i in 0..400 {
            assert!(state_record(d.path(), row(&format!("m{i}:0"))).unwrap());
        }
        assert!(!state_record(d.path(), row("m0:0")).unwrap(), "the oldest id is still on record");
        assert_eq!(state_read(d.path()).unwrap().len(), 400);
    }

    #[test]
    fn a_state_row_with_a_control_character_is_not_written() {
        let d = tempfile::tempdir().unwrap();
        let mut r = row("m1:0");
        r.team = "t\tx".into();
        assert!(state_record(d.path(), r).is_err());
        assert!(state_read(d.path()).unwrap().is_empty());
    }

    #[test]
    fn the_scan_leaves_handled_requests_out_through_the_record() {
        let d = tempfile::tempdir().unwrap();
        state_record(d.path(), row("e1:0")).unwrap();
        let handled: HashSet<String> = state_read(d.path()).unwrap().into_iter().map(|r| r.request_id).collect();
        let (rows, _) = assemble(&[cand("1", "a", LINE)], &handled, &env());
        assert_eq!(rows.len(), 1, "a different message is a different request");
        let (rows, _) = assemble(&[Candidate { id: "e1".into(), ..cand("1", "a", LINE) }], &handled, &env());
        assert!(rows.is_empty());
    }
}
