//! Open requests from seats: the app side of the `ctrl.app_open_pane` control
//! request. A seat asks the team's app-user to open a pane; the app lists the
//! request and opens it only when the person clicks. Nothing here runs because a
//! message said so, and nothing here grants anything: the pane's own consent card
//! still asks for what it needs.
//!
//! Interim 1.6 carrier (the store has no `kind` column yet): the message body is
//!
//! ```text
//! agmsg-ctrl v1 ctrl.app_open_pane
//! {"pane":"diffview","args":{"path":"/abs/path","base":"main"},"requester":{"member_id":"…","token":"…"},"request_id":"…"}
//! ```
//!
//! Line 1 is exact; line 2 is one JSON object of at most 2 KB; anything else that is
//! not blank is refused (`extra_content`). The reason codes are the ones the UI's own
//! parser (`app/src/addons/openRequest.ts`) uses; this side is the one that decides.
//!
//! What is checked, in order, for every row (a refusal is shown, never silent):
//! 1. addressed to the team's app-user (a team with none, or more than one, has no requests);
//! 2. **origin**: the row was accepted on this machine. A row that came through sync
//!    (`sync_messages` direction `pull`) or whose origin cannot be established (a legacy
//!    row with no event, a store only `api.sh` can read) never gets an Open;
//! 3. **requester**: `requester.member_id` equals the row's accepted `from`. The token
//!    cannot be checked without agmsgd's `send_commits`; its hash is recorded and the bar
//!    must call the name unverified (`tokenCheck: "unverified"`);
//! 4. the pane is built in or installed (and enabled, and its files match what was pinned);
//! 5. the args are exactly what that pane's `opens` allows;
//! 6. a path exists on this machine and is not a protected place.
//!
//! `addon_ctrl_open` runs 1–6 again from the store (the UI's copy is never trusted),
//! records `opened` against the request id, and returns what `addon_pane_add` takes.
//! There is no expiry yet: the time is shown, an unhandled request is listed
//! again after a restart. A request id is acted on once; the same id with other content
//! is refused (`request_id_reused`).

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tauri::State;

use super::catalog::AddonInfo;
use super::denylist::GrantCheck;
use super::digest::sha256_hex;
use super::host::AddonHost;
use super::panes::OpenArgs;

pub const HEADER: &str = "agmsg-ctrl v1 ctrl.app_open_pane";
pub const MAX_PAYLOAD_BYTES: usize = 2048;
/// How many request-looking messages to a team's app-user one scan reads (the newest).
pub const SCAN_CAP: usize = 500;
const STATE_CAP: usize = 5000;
const TYPE_APP: &str = "agmsg-app";

// ---------------------------------------------------------------------------
// The envelope
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Fileview,
    Diffview,
    Browser,
    Addon { owner: String, repo: String, pane: String },
}

fn name_ok(s: &str, first_alnum: bool, max: usize) -> bool {
    let b = s.as_bytes();
    !b.is_empty() && b.len() <= max && s != "." && s != ".." && b.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'-' || (!first_alnum && (*c == b'.' || *c == b'_'))) && (!first_alnum || b[0].is_ascii_alphanumeric())
}

impl Target {
    pub fn parse(pane: &str) -> Option<Target> {
        match pane {
            "fileview" => return Some(Target::Fileview),
            "diffview" => return Some(Target::Diffview),
            "browser" => return Some(Target::Browser),
            _ => {}
        }
        let rest = pane.strip_prefix("addon:")?;
        let mut it = rest.split('/');
        let (owner, repo, p) = (it.next()?, it.next()?, it.next()?);
        if it.next().is_some() {
            return None;
        }
        let tail_ok = |s: &str| !s.is_empty() && s.len() <= 100 && s != "." && s != ".." && s.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'.' | b'_' | b'-'));
        (name_ok(owner, true, 39) && tail_ok(repo) && tail_ok(p)).then(|| Target::Addon { owner: owner.into(), repo: repo.into(), pane: p.into() })
    }

    /// The catalog id and pane name, or `None` for a pane that does not ship yet.
    fn catalog_key(&self) -> Option<(String, String)> {
        match self {
            Target::Fileview => Some(("builtin:fileview".into(), "fileview".into())),
            Target::Diffview => Some(("builtin:diffview".into(), "diffview".into())),
            Target::Browser => None,
            Target::Addon { owner, repo, pane } => Some((format!("{owner}/{repo}"), pane.clone())),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Args {
    pub path: Option<String>,
    pub url: Option<String>,
    pub base: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    /// As sent.
    pub pane: String,
    pub target: Target,
    pub args: Args,
    pub member_id: String,
    pub token: String,
    pub request_id: String,
    /// sha256 of the exact payload line: a second request with this id must carry the same.
    pub payload_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Refusal {
    pub reason: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Parsed {
    /// An ordinary message (including another `agmsg-ctrl` kind, which this side never reads).
    None,
    Request(Box<Request>),
    Refused(Refusal),
}

fn refuse(reason: &'static str, detail: impl Into<Option<String>>) -> Parsed {
    Parsed::Refused(Refusal { reason, detail: detail.into() })
}

fn id_ok(s: &str) -> bool {
    !s.is_empty() && s.len() <= 128 && s.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.' | b':'))
}

fn plain_text(s: &str, max: usize) -> bool {
    !s.is_empty() && s.len() <= max && !s.contains(['\0', '\n', '\r', '\t'])
}

pub fn parse(body: &str) -> Parsed {
    let norm = body.replace("\r\n", "\n");
    let mut lines = norm.split('\n');
    if lines.next() != Some(HEADER) {
        return Parsed::None;
    }
    let payload = match lines.next() {
        Some(p) if !p.trim().is_empty() => p,
        _ => return refuse("missing_payload", None),
    };
    if lines.any(|l| !l.trim().is_empty()) {
        return refuse("extra_content", None);
    }
    if payload.len() > MAX_PAYLOAD_BYTES {
        return refuse("too_large", None);
    }
    let Ok(json) = serde_json::from_str::<Value>(payload) else { return refuse("bad_json", None) };
    let Some(obj) = json.as_object() else { return refuse("bad_shape", None) };
    if let Some(k) = obj.keys().find(|k| !matches!(k.as_str(), "pane" | "args" | "requester" | "request_id")) {
        // `deadline` is among these: no TTL is implemented, so a request that carries one is not guessed at
        return refuse("bad_shape", format!("unknown key `{k}`"));
    }
    let Some(pane) = obj.get("pane").and_then(Value::as_str) else { return refuse("bad_pane", None) };
    let Some(target) = Target::parse(pane) else { return refuse("bad_pane", pane.chars().take(120).collect::<String>()) };

    let Some(raw_args) = obj.get("args").and_then(Value::as_object) else { return refuse("bad_shape", "args".to_string()) };
    let mut args = Args::default();
    for (k, v) in raw_args {
        let slot = match k.as_str() {
            "path" => &mut args.path,
            "url" => &mut args.url,
            "base" => &mut args.base,
            _ => return refuse("unknown_arg_key", k.chars().take(60).collect::<String>()),
        };
        match v.as_str() {
            Some(s) if !s.is_empty() && s.len() <= 4096 && !s.contains('\0') => *slot = Some(s.to_string()),
            _ => return refuse("bad_arg_value", k.clone()),
        }
    }
    if let Some(p) = &args.path {
        if !Path::new(p).is_absolute() {
            return refuse("bad_arg_value", "path: must be an absolute path".to_string());
        }
    }
    if let Some(u) = &args.url {
        // what a pane shows or fetches for the person: a web address, never a local file or a script
        if !(u.starts_with("https://") || u.starts_with("http://")) || u.contains(char::is_whitespace) || u.contains(char::is_control) {
            return refuse("bad_arg_value", "url: must be an http or https address".to_string());
        }
    }
    if let Some(b) = &args.base {
        // a ref name, not an option for a later git call
        if b.starts_with('-') || b.contains(char::is_whitespace) || b.contains(char::is_control) {
            return refuse("bad_arg_value", "base: not a ref name".to_string());
        }
    }

    let Some(r) = obj.get("requester").and_then(Value::as_object) else { return refuse("bad_requester", None) };
    let (Some(member_id), Some(token)) = (r.get("member_id").and_then(Value::as_str), r.get("token").and_then(Value::as_str)) else { return refuse("bad_requester", None) };
    if r.len() != 2 || !plain_text(member_id, 256) || !plain_text(token, 256) {
        return refuse("bad_requester", None);
    }
    let Some(request_id) = obj.get("request_id").and_then(Value::as_str) else { return refuse("bad_request_id", None) };
    if !id_ok(request_id) {
        return refuse("bad_request_id", None);
    }
    Parsed::Request(Box::new(Request { pane: pane.to_string(), target, args, member_id: member_id.to_string(), token: token.to_string(), request_id: request_id.to_string(), payload_sha256: sha256_hex(payload.as_bytes()) }))
}

// ---------------------------------------------------------------------------
// What the app remembers: opened / dismissed, by request id
// ---------------------------------------------------------------------------

/// `<base>/addons/ctrl-state.tsv`: `request_id, team, state, at, payload_sha256, token_sha256`.
/// The app's own record (it never writes the message store). The token is kept as a
/// hash: enough to tell two requests apart in an audit, nothing a reader could replay.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateRow {
    pub request_id: String,
    pub team: String,
    pub state: String,
    pub at: String,
    pub payload_sha256: String,
    pub token_sha256: String,
}

static STATE_LOCK: Mutex<()> = Mutex::new(());

fn state_path(addons: &Path) -> PathBuf {
    addons.join("ctrl-state.tsv")
}

fn state_read(addons: &Path) -> Vec<StateRow> {
    let Ok(text) = fs::read_to_string(state_path(addons)) else { return Vec::new() };
    text.lines()
        .filter_map(|l| {
            let c: Vec<&str> = l.split('\t').collect();
            (c.len() == 6 && id_ok(c[0]) && matches!(c[2], "opened" | "dismissed")).then(|| StateRow { request_id: c[0].into(), team: c[1].into(), state: c[2].into(), at: c[3].into(), payload_sha256: c[4].into(), token_sha256: c[5].into() })
        })
        .collect()
}

fn state_write(addons: &Path, rows: &[StateRow]) -> io::Result<()> {
    fs::create_dir_all(addons)?;
    let mut body = String::new();
    for r in rows {
        for f in [&r.team, &r.at, &r.payload_sha256, &r.token_sha256] {
            if f.contains(['\t', '\n', '\r']) {
                return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid state row"));
            }
        }
        body.push_str(&[r.request_id.as_str(), &r.team, &r.state, &r.at, &r.payload_sha256, &r.token_sha256].join("\t"));
        body.push('\n');
    }
    let tmp = addons.join(format!(".ctrl-state.tsv.{}.tmp", std::process::id()));
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
    let mut all = state_read(addons);
    if all.iter().any(|r| r.request_id == row.request_id) {
        return Ok(false);
    }
    all.push(row);
    if all.len() > STATE_CAP {
        let drop = all.len() - STATE_CAP;
        all.drain(..drop);
    }
    state_write(addons, &all)?;
    Ok(true)
}

// ---------------------------------------------------------------------------
// Where the rows come from
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Origin {
    /// Accepted on this machine, and not a row that sync brought in.
    Local,
    /// Brought in by sync (`sync_messages` direction `pull`).
    Synced,
    /// Cannot be established: a legacy row with no event, or a store only `api.sh` can read.
    Unproven,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Candidate {
    pub id: String,
    pub team: String,
    pub from: String,
    pub to: String,
    pub body: String,
    pub created_at: String,
    pub origin: Origin,
}

fn table_exists(conn: &rusqlite::Connection, name: &str) -> bool {
    conn.query_row("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1", [name], |_| Ok(())).is_ok()
}

/// Request-looking messages to `app_user` (oldest first, at most `cap`, plus whether older ones were left out).
pub fn scan_sqlite(conn: &rusqlite::Connection, team: &str, app_user: &str, cap: usize) -> Result<(Vec<Candidate>, bool), String> {
    let limit = (cap + 1) as i64;
    let mut found: Vec<(Candidate, u8, i64)> = Vec::new();

    if table_exists(conn, "events") {
        // a store that never synced has no sync_messages table: nothing could have been pulled into it
        let synced = if table_exists(conn, "sync_messages") { "EXISTS (SELECT 1 FROM sync_messages s WHERE s.local_id = e.id AND s.direction = 'pull')" } else { "0" };
        let sql = format!(
            "SELECT e.id, e.team, e.from_agent, e.to_agent, e.body, e.at, {synced}, e.seq
               FROM events e
              WHERE e.type='message_sent' AND e.team=?1 AND e.to_agent=?2 AND substr(e.body,1,14)='agmsg-ctrl v1 '
              ORDER BY e.seq DESC LIMIT ?3"
        );
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map(rusqlite::params![team, app_user, limit], |r| {
                Ok((
                    Candidate { id: r.get(0)?, team: r.get(1)?, from: r.get(2)?, to: r.get(3)?, body: r.get(4)?, created_at: r.get(5)?, origin: if r.get::<_, i64>(6)? != 0 { Origin::Synced } else { Origin::Local } },
                    1u8,
                    r.get::<_, i64>(7)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        for r in rows {
            found.push(r.map_err(|e| e.to_string())?);
        }
    }

    if table_exists(conn, "messages") {
        // a legacy row that has a live event is the same message: the event copy is the one read above
        let base = "SELECT CAST(id AS TEXT), team, from_agent, to_agent, body, created_at, id FROM messages
                     WHERE team=?1 AND to_agent=?2 AND substr(body,1,14)='agmsg-ctrl v1 '";
        let linked = format!("{base} AND NOT EXISTS (SELECT 1 FROM events e2 WHERE e2.legacy_id = messages.id AND e2.seq > 0) ORDER BY id DESC LIMIT ?3");
        let plain = format!("{base} ORDER BY id DESC LIMIT ?3");
        let mut stmt = match conn.prepare(&linked) {
            Ok(s) => s,
            // a store whose events table has no legacy_id (or no events table): there are no linked copies
            Err(_) => conn.prepare(&plain).map_err(|e| e.to_string())?,
        };
        let rows = stmt
            .query_map(rusqlite::params![team, app_user, limit], |r| Ok((Candidate { id: r.get(0)?, team: r.get(1)?, from: r.get(2)?, to: r.get(3)?, body: r.get(4)?, created_at: r.get(5)?, origin: Origin::Unproven }, 0u8, r.get::<_, i64>(6)?)))
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
    Found { addon_id: String, pane: String, opens: Vec<String>, git_read: bool },
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
    fn pane(&self, target: &Target) -> PaneState;
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
    BadRequester,
    NotFoundHere,
    DeniedPath,
    /// Came through sync: never opened here.
    Synced,
    /// Origin cannot be established: never opened.
    Unproven,
    /// The envelope is malformed (see `refusal`).
    Refused,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Evaluated {
    pub verdict: Verdict,
    pub detail: Option<String>,
    pub install_target: Option<String>,
    pub requester_matches: bool,
    pub path_state: Option<&'static str>,
    pub spec: Option<OpenSpec>,
}

impl Evaluated {
    fn new(verdict: Verdict) -> Evaluated {
        Evaluated { verdict, detail: None, install_target: None, requester_matches: false, path_state: None, spec: None }
    }
}

fn allowed_and_required(opens: &[String], git_read: bool, has_path: bool) -> (Vec<&'static str>, Vec<&'static str>) {
    let mut allowed = Vec::new();
    let mut required = Vec::new();
    for k in ["path", "url"] {
        if opens.iter().any(|o| o == k) {
            allowed.push(k);
            required.push(k);
        }
    }
    if git_read && has_path {
        allowed.push("base");
    }
    (allowed, required)
}

/// Runs checks 2–6 for one parsed request.
pub fn evaluate(origin: Origin, from: &str, req: &Request, env: &dyn Env) -> Evaluated {
    match origin {
        Origin::Synced => return Evaluated::new(Verdict::Synced),
        Origin::Unproven => return Evaluated::new(Verdict::Unproven),
        Origin::Local => {}
    }
    let mut out = Evaluated::new(Verdict::Ready);
    out.requester_matches = req.member_id == from;
    if !out.requester_matches {
        out.verdict = Verdict::BadRequester;
        out.detail = Some(format!("The request names {} but was sent by {}.", req.member_id, from));
        return out;
    }
    let (addon_id, pane, opens, git_read) = match env.pane(&req.target) {
        PaneState::Found { addon_id, pane, opens, git_read } => (addon_id, pane, opens, git_read),
        PaneState::NotInstalled => {
            out.verdict = Verdict::NotInstalled;
            if let Target::Addon { owner, repo, .. } = &req.target {
                out.install_target = Some(format!("{owner}/{repo}"));
            }
            return out;
        }
        PaneState::Unavailable(why) => {
            out.verdict = Verdict::Unavailable;
            out.detail = Some(why);
            return out;
        }
    };
    let (allowed, required) = allowed_and_required(&opens, git_read, req.args.path.is_some());
    let given: Vec<&str> = [("path", &req.args.path), ("url", &req.args.url), ("base", &req.args.base)].iter().filter(|(_, v)| v.is_some()).map(|(k, _)| *k).collect();
    if let Some(k) = given.iter().find(|k| !allowed.contains(k)) {
        out.verdict = Verdict::ArgsNotAllowed;
        out.detail = Some(format!("This pane does not take `{k}`."));
        return out;
    }
    if let Some(k) = required.iter().find(|k| !given.contains(k)) {
        out.verdict = Verdict::ArgsNotAllowed;
        out.detail = Some(format!("This pane needs `{k}`."));
        return out;
    }
    let mut open_args = OpenArgs { path: None, url: req.args.url.clone(), base: req.args.base.clone() };
    if let Some(p) = &req.args.path {
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
pub struct CtrlRow {
    /// The message id.
    pub id: String,
    pub team: String,
    pub from: String,
    pub to: String,
    pub body: String,
    #[serde(rename = "created_at")]
    pub created_at: String,
    pub origin: Origin,
    pub verdict: Verdict,
    /// Words for the bar when the verdict says why.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub install_target: Option<String>,
    /// `member_id` equals the accepted `from`.
    pub requester_matches: bool,
    /// `exists` | `missing` | `denied`; absent when the request has no path.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path_state: Option<&'static str>,
    /// Always `unverified` in this build: the token is recorded, not proven (see the module notes).
    pub token_check: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refusal: Option<Refusal>,
    /// The request id, when the envelope parsed far enough to have one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CtrlScan {
    pub app_user: Option<String>,
    pub rows: Vec<CtrlRow>,
    /// Request ids already opened or dismissed (their rows are left out of `rows`).
    pub handled: Vec<String>,
    /// Older request-looking messages were left out (more than `SCAN_CAP`).
    pub truncated: bool,
    /// Why there is nothing to show, when that is not "nothing was sent".
    #[serde(skip_serializing_if = "Option::is_none")]
    pub notice: Option<String>,
}

fn row_of(c: &Candidate, ev: Evaluated, refusal: Option<Refusal>, request_id: Option<String>) -> CtrlRow {
    CtrlRow {
        id: c.id.clone(),
        team: c.team.clone(),
        from: c.from.clone(),
        to: c.to.clone(),
        body: c.body.clone(),
        created_at: c.created_at.clone(),
        origin: c.origin,
        verdict: ev.verdict,
        detail: ev.detail,
        install_target: ev.install_target,
        requester_matches: ev.requester_matches,
        path_state: ev.path_state,
        token_check: "unverified",
        refusal,
        request_id,
    }
}

/// A request that can be opened, found again from the store by its request id.
struct Found {
    candidate: Candidate,
    request: Request,
    evaluated: Evaluated,
}

/// Turns candidates into rows: identical repeats of a request id are one request,
/// the same id with other content is refused, handled ids are left out.
fn assemble(cands: &[Candidate], state: &[StateRow], env: &dyn Env) -> (Vec<CtrlRow>, Vec<String>, Vec<Found>) {
    let handled_map: HashMap<&str, &StateRow> = state.iter().map(|r| (r.request_id.as_str(), r)).collect();
    let mut first: HashMap<String, String> = HashMap::new();
    let mut rows = Vec::new();
    let mut handled = Vec::new();
    let mut found = Vec::new();
    for c in cands {
        match parse(&c.body) {
            Parsed::None => {}
            Parsed::Refused(r) => {
                // provenance still comes first: a synced row never shows even a malformed note about itself
                let mut ev = Evaluated::new(match c.origin {
                    Origin::Synced => Verdict::Synced,
                    Origin::Unproven => Verdict::Unproven,
                    Origin::Local => Verdict::Refused,
                });
                if ev.verdict == Verdict::Refused {
                    ev.detail = r.detail.clone();
                }
                let refusal = (ev.verdict == Verdict::Refused).then_some(r);
                rows.push(row_of(c, ev, refusal, None));
            }
            Parsed::Request(req) => {
                if c.origin == Origin::Local {
                    if let Some(prev) = first.get(&req.request_id) {
                        if *prev == req.payload_sha256 {
                            continue; // the same request again: one request
                        }
                        let mut ev = Evaluated::new(Verdict::Refused);
                        ev.detail = Some("That request id was already used with other content.".into());
                        rows.push(row_of(c, ev, Some(Refusal { reason: "request_id_reused", detail: None }), Some(req.request_id.clone())));
                        continue;
                    }
                    first.insert(req.request_id.clone(), req.payload_sha256.clone());
                    if let Some(h) = handled_map.get(req.request_id.as_str()) {
                        if h.payload_sha256 == req.payload_sha256 {
                            handled.push(req.request_id.clone());
                            continue;
                        }
                        let mut ev = Evaluated::new(Verdict::Refused);
                        ev.detail = Some("That request id was already used with other content.".into());
                        rows.push(row_of(c, ev, Some(Refusal { reason: "request_id_reused", detail: None }), Some(req.request_id.clone())));
                        continue;
                    }
                }
                let ev = evaluate(c.origin, &c.from, &req, env);
                rows.push(row_of(c, ev.clone(), None, Some(req.request_id.clone())));
                if c.origin == Origin::Local {
                    found.push(Found { candidate: c.clone(), request: *req, evaluated: ev });
                }
            }
        }
    }
    (rows, handled, found)
}

// ---------------------------------------------------------------------------
// The host side
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct CtrlError {
    pub code: &'static str,
    pub message: String,
}

fn err(code: &'static str, message: impl Into<String>) -> CtrlError {
    CtrlError { code, message: message.into() }
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
        HostEnv::with(host, off)
    }

    fn with(host: &'a AddonHost, off: Option<String>) -> HostEnv<'a> {
        HostEnv { host, list: std::cell::OnceCell::new(), off }
    }
}

impl Env for HostEnv<'_> {
    fn pane(&self, target: &Target) -> PaneState {
        let Some((id, pane)) = target.catalog_key() else { return PaneState::NotInstalled };
        if let Some(why) = &self.off {
            return PaneState::Unavailable(why.clone());
        }
        let list = self.list.get_or_init(|| self.host.catalog().list());
        let Some(info) = list.iter().find(|a| a.id == id) else { return PaneState::NotInstalled };
        if !info.enabled {
            return PaneState::Unavailable("That add-on is turned off.".into());
        }
        if !info.digest_ok {
            return PaneState::Unavailable("That add-on's files are incomplete or were changed after install.".into());
        }
        match info.panes.iter().find(|p| p.name == pane) {
            Some(p) => PaneState::Found { addon_id: id, pane, opens: p.opens.clone(), git_read: p.permissions.iter().any(|x| x == "git:read") },
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
fn app_user_of(team: &str) -> Result<Option<String>, CtrlError> {
    let members = crate::agmsg::agmsg_members(team.to_string()).map_err(|e| err("members_failed", e))?;
    let mut apps = members.into_iter().filter(|m| m.types.iter().any(|t| t == TYPE_APP)).map(|m| m.name);
    let first = apps.next();
    if apps.next().is_some() {
        return Err(err("several_app_users", "This team has more than one app-user, so requests are not shown."));
    }
    Ok(first)
}

fn candidates(team: &str, app_user: &str) -> Result<(Vec<Candidate>, bool), CtrlError> {
    use crate::agmsg::TeamStore;
    match crate::agmsg::team_store(team) {
        TeamStore::Empty => Ok((Vec::new(), false)),
        TeamStore::Sqlite(path) => {
            let conn = crate::agmsg::open_store_ro(&path).map_err(|e| err("store_failed", e))?;
            scan_sqlite(&conn, team, app_user, SCAN_CAP).map_err(|e| err("store_failed", e))
        }
        TeamStore::Api => {
            // `api.sh` does not say where a row came from, so nothing here can be opened
            let msgs = crate::agmsg::api_recent_messages(team, 200).map_err(|e| err("store_failed", e))?;
            let cands = msgs
                .into_iter()
                .filter(|m| m.to == app_user && m.body.starts_with("agmsg-ctrl v1 "))
                .map(|m| Candidate { id: m.id, team: m.team, from: m.from, to: m.to, body: m.body, created_at: m.created_at, origin: Origin::Unproven })
                .collect();
            Ok((cands, false))
        }
    }
}

fn scan_with(host: &AddonHost, team: &str, app_user: &str) -> Result<(CtrlScan, Vec<Found>), CtrlError> {
    let (cands, truncated) = candidates(team, app_user)?;
    let state = state_read(host.catalog().addons_dir());
    let env = HostEnv::new(host);
    let (rows, handled, found) = assemble(&cands, &state, &env);
    Ok((CtrlScan { app_user: Some(app_user.to_string()), rows, handled, truncated, notice: None }, found))
}

/// The team's requests, checked. Call it when the tab opens and when a message to the app-user arrives.
#[tauri::command(async)]
pub fn addon_ctrl_rows(host: State<'_, Arc<AddonHost>>, team: String) -> Result<CtrlScan, CtrlError> {
    match app_user_of(&team) {
        Ok(Some(user)) => scan_with(&host, &team, &user).map(|(s, _)| s),
        Ok(None) => Ok(CtrlScan { app_user: None, rows: Vec::new(), handled: Vec::new(), truncated: false, notice: Some("This team has no app-user, so it cannot receive open requests.".into()) }),
        Err(e) if e.code == "several_app_users" => Ok(CtrlScan { app_user: None, rows: Vec::new(), handled: Vec::new(), truncated: false, notice: Some(e.message) }),
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
pub struct CtrlOpened {
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
        Verdict::BadRequester => "The request does not match who sent it.",
        Verdict::NotFoundHere => "That path was not found on this computer.",
        Verdict::DeniedPath => "That location is protected.",
        Verdict::Synced => "Requests from other computers are not opened here.",
        Verdict::Unproven => "This request cannot be shown to have been sent on this computer.",
        Verdict::Refused => "The request is malformed.",
    };
    match detail {
        Some(d) => format!("{base} {d}"),
        None => base.to_string(),
    }
}

/// The click on Open: everything is checked again from the store, the decision is
/// recorded against the request id, and the pane to create is returned.
#[tauri::command(async)]
pub fn addon_ctrl_open(host: State<'_, Arc<AddonHost>>, spec: RequestIn) -> Result<CtrlOpened, CtrlError> {
    let user = app_user_of(&spec.team)?.ok_or_else(|| err("no_app_user", "This team has no app-user."))?;
    let (_, found) = scan_with(&host, &spec.team, &user)?;
    let hit = found.into_iter().find(|f| f.request.request_id == spec.request_id).ok_or_else(|| err("not_found", "That request is no longer there, or was already handled."))?;
    if hit.evaluated.verdict != Verdict::Ready {
        return Err(err("not_openable", verdict_message(hit.evaluated.verdict, &hit.evaluated.detail)));
    }
    let open = hit.evaluated.spec.clone().ok_or_else(|| err("not_openable", "nothing to open"))?;
    let recorded = state_record(
        host.catalog().addons_dir(),
        StateRow { request_id: hit.request.request_id.clone(), team: spec.team.clone(), state: "opened".into(), at: now_iso(), payload_sha256: hit.request.payload_sha256.clone(), token_sha256: sha256_hex(hit.request.token.as_bytes()) },
    )
    .map_err(|e| err("state_failed", e.to_string()))?;
    if !recorded {
        return Err(err("not_found", "That request was already handled."));
    }
    eprintln!("[addons] open request {} from {} → {} (opened)", hit.request.request_id, hit.candidate.from, hit.request.pane);
    Ok(CtrlOpened { request_id: hit.request.request_id, from: hit.candidate.from, addon_id: open.addon_id, pane: open.pane, open_args: open.open_args })
}

#[tauri::command(async)]
pub fn addon_ctrl_dismiss(host: State<'_, Arc<AddonHost>>, spec: RequestIn) -> Result<(), CtrlError> {
    let user = app_user_of(&spec.team)?.ok_or_else(|| err("no_app_user", "This team has no app-user."))?;
    let (cands, _) = candidates(&spec.team, &user)?;
    // only a request that is really in this team's store can be recorded: the state file is not a place for arbitrary text
    let req = cands
        .iter()
        .filter(|c| c.origin == Origin::Local)
        .find_map(|c| match parse(&c.body) {
            Parsed::Request(r) if r.request_id == spec.request_id => Some(r),
            _ => None,
        })
        .ok_or_else(|| err("not_found", "That request is no longer there."))?;
    state_record(host.catalog().addons_dir(), StateRow { request_id: req.request_id.clone(), team: spec.team.clone(), state: "dismissed".into(), at: now_iso(), payload_sha256: req.payload_sha256.clone(), token_sha256: sha256_hex(req.token.as_bytes()) }).map_err(|e| err("state_failed", e.to_string()))?;
    Ok(())
}

fn now_iso() -> String {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    super::broker::iso8601(secs)
}

/// Ids already handled, for the tests and for anything that needs them without a scan.
#[allow(dead_code)]
pub fn handled_ids(addons: &Path) -> HashSet<String> {
    state_read(addons).into_iter().map(|r| r.request_id).collect()
}


#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use std::collections::BTreeMap;

    fn body(payload: &str) -> String {
        format!("{HEADER}\n{payload}")
    }

    fn payload(pane: &str, args: &str, member: &str, id: &str) -> String {
        format!(r#"{{"pane":"{pane}","args":{args},"requester":{{"member_id":"{member}","token":"tok-1"}},"request_id":"{id}"}}"#)
    }

    fn req(b: &str) -> Request {
        match parse(b) {
            Parsed::Request(r) => *r,
            other => panic!("not a request: {other:?}"),
        }
    }

    fn reason(b: &str) -> &'static str {
        match parse(b) {
            Parsed::Refused(r) => r.reason,
            other => panic!("not refused: {other:?}"),
        }
    }

    #[test]
    fn a_well_formed_request_parses() {
        let r = req(&body(&payload("diffview", r#"{"path":"/tmp/x","base":"main"}"#, "alice", "r-1")));
        assert_eq!(r.target, Target::Diffview);
        assert_eq!(r.args.path.as_deref(), Some("/tmp/x"));
        assert_eq!(r.args.base.as_deref(), Some("main"));
        assert_eq!((r.member_id.as_str(), r.request_id.as_str()), ("alice", "r-1"));
        assert_eq!(r.payload_sha256.len(), 64);
        // CRLF and trailing blank lines are fine
        let crlf = format!("{HEADER}\r\n{}\r\n\r\n", payload("fileview", r#"{"path":"/tmp/x"}"#, "alice", "r-2"));
        assert_eq!(req(&crlf).request_id, "r-2");
    }

    #[test]
    fn anything_that_is_not_exactly_the_header_is_an_ordinary_message() {
        let p = payload("fileview", r#"{"path":"/tmp/x"}"#, "alice", "r-1");
        for b in ["hello", "", &format!("{HEADER} "), &format!(" {HEADER}\n{p}"), &format!("agmsg-ctrl v2 ctrl.app_open_pane\n{p}"), &format!("note\n{}", body(&p)), &format!("agmsg-ctrl v1 ctrl.despawn\n{p}")] {
            assert_eq!(parse(b), Parsed::None, "{b:?}");
        }
    }

    #[test]
    fn refusals_carry_the_reason_the_bar_shows() {
        let p = |pane: &str, args: &str| body(&payload(pane, args, "alice", "r-1"));
        assert_eq!(reason(HEADER), "missing_payload");
        assert_eq!(reason(&format!("{HEADER}\n")), "missing_payload");
        assert_eq!(reason(&format!("{}\nmore text", p("fileview", r#"{"path":"/tmp"}"#))), "extra_content");
        assert_eq!(reason(&format!("{HEADER}\n{}", "x".repeat(MAX_PAYLOAD_BYTES + 1))), "too_large");
        assert_eq!(reason(&format!("{HEADER}\n{{nope")), "bad_json");
        assert_eq!(reason(&format!("{HEADER}\n[1]")), "bad_shape");
        assert_eq!(reason(&p("shell", "{}")), "bad_pane");
        assert_eq!(reason(&p("addon:a/b", "{}")), "bad_pane");
        assert_eq!(reason(&p("addon:a/b/c/d", "{}")), "bad_pane");
        assert_eq!(reason(&p("addon:../b/c", "{}")), "bad_pane");
        assert_eq!(reason(&p("fileview", r#"{"path":"/tmp","cwd":"/"}"#)), "unknown_arg_key");
        assert_eq!(reason(&p("fileview", r#"{"path":""}"#)), "bad_arg_value");
        assert_eq!(reason(&p("addon:o/r/viewer", r#"{"url":"file:///etc/passwd"}"#)), "bad_arg_value");
        assert_eq!(reason(&p("addon:o/r/viewer", r#"{"url":"javascript:alert(1)"}"#)), "bad_arg_value");
        assert_eq!(req(&p("addon:o/r/viewer", r#"{"url":"https://example.com/a?b=1"}"#)).args.url.as_deref(), Some("https://example.com/a?b=1"));
        assert_eq!(reason(&p("fileview", r#"{"path":5}"#)), "bad_arg_value");
        assert_eq!(reason(&p("fileview", r#"{"path":"relative/dir"}"#)), "bad_arg_value");
        assert_eq!(reason(&p("diffview", r#"{"path":"/tmp","base":"--output=/x"}"#)), "bad_arg_value");
        assert_eq!(reason(&p("diffview", r#"{"path":"/tmp","base":"a b"}"#)), "bad_arg_value");
        assert_eq!(reason(&body(r#"{"pane":"fileview","args":{"path":"/tmp"},"request_id":"r"}"#)), "bad_requester");
        assert_eq!(reason(&body(r#"{"pane":"fileview","args":{"path":"/tmp"},"requester":{"member_id":"a","token":"t","x":1},"request_id":"r"}"#)), "bad_requester");
        assert_eq!(reason(&body(r#"{"pane":"fileview","args":{"path":"/tmp"},"requester":{"member_id":"a","token":"t"}}"#)), "bad_request_id");
        assert_eq!(reason(&body(r#"{"pane":"fileview","args":{"path":"/tmp"},"requester":{"member_id":"a","token":"t"},"request_id":"a b"}"#)), "bad_request_id");
        // no TTL exists, so a deadline is not guessed at
        assert_eq!(reason(&body(r#"{"pane":"fileview","args":{"path":"/tmp"},"requester":{"member_id":"a","token":"t"},"request_id":"r","deadline":{"at":"x"}}"#)), "bad_shape");
    }

    #[test]
    fn pane_names_cover_builtins_and_addons() {
        assert_eq!(Target::parse("fileview"), Some(Target::Fileview));
        assert_eq!(Target::parse("browser"), Some(Target::Browser));
        assert_eq!(Target::parse("addon:shinshin86/agmsg-office/agmsg-office"), Some(Target::Addon { owner: "shinshin86".into(), repo: "agmsg-office".into(), pane: "agmsg-office".into() }));
        assert_eq!(Target::parse("addon:-x/r/p"), None);
        assert_eq!(Target::parse("FileView"), None);
        assert_eq!(Target::Fileview.catalog_key(), Some(("builtin:fileview".into(), "fileview".into())));
        assert_eq!(Target::Browser.catalog_key(), None);
    }

    // ---- the checks ----

    struct FakeEnv {
        panes: BTreeMap<String, PaneState>,
        paths: BTreeMap<String, PathState>,
    }

    impl Env for FakeEnv {
        fn pane(&self, t: &Target) -> PaneState {
            let key = match t {
                Target::Fileview => "fileview".to_string(),
                Target::Diffview => "diffview".to_string(),
                Target::Browser => "browser".to_string(),
                Target::Addon { owner, repo, pane } => format!("{owner}/{repo}/{pane}"),
            };
            self.panes.get(&key).cloned().unwrap_or(PaneState::NotInstalled)
        }
        fn path(&self, p: &str) -> PathState {
            self.paths.get(p).cloned().unwrap_or(PathState::Missing)
        }
    }

    fn env() -> FakeEnv {
        let mut panes = BTreeMap::new();
        panes.insert("fileview".into(), PaneState::Found { addon_id: "builtin:fileview".into(), pane: "fileview".into(), opens: vec!["path".into()], git_read: false });
        panes.insert("diffview".into(), PaneState::Found { addon_id: "builtin:diffview".into(), pane: "diffview".into(), opens: vec!["path".into()], git_read: true });
        panes.insert("o/r/viewer".into(), PaneState::Found { addon_id: "o/r".into(), pane: "viewer".into(), opens: vec![], git_read: false });
        panes.insert("o/r/off".into(), PaneState::Unavailable("That add-on is turned off.".into()));
        let mut paths = BTreeMap::new();
        paths.insert("/proj".into(), PathState::Exists(PathBuf::from("/real/proj")));
        paths.insert("/secret".into(), PathState::Denied);
        FakeEnv { panes, paths }
    }

    fn verdict(origin: Origin, from: &str, b: &str) -> Evaluated {
        evaluate(origin, from, &req(b), &env())
    }

    #[test]
    fn a_ready_request_opens_the_real_path_with_only_what_was_asked() {
        let e = verdict(Origin::Local, "alice", &body(&payload("diffview", r#"{"path":"/proj","base":"main"}"#, "alice", "r1")));
        assert_eq!(e.verdict, Verdict::Ready);
        assert_eq!(e.path_state, Some("exists"));
        let spec = e.spec.unwrap();
        assert_eq!((spec.addon_id.as_str(), spec.pane.as_str()), ("builtin:diffview", "diffview"));
        assert_eq!(spec.open_args, OpenArgs { path: Some("/real/proj".into()), url: None, base: Some("main".into()) });
    }

    #[test]
    fn origin_decides_before_anything_else() {
        let b = body(&payload("fileview", r#"{"path":"/proj"}"#, "alice", "r1"));
        assert_eq!(verdict(Origin::Synced, "alice", &b).verdict, Verdict::Synced);
        assert_eq!(verdict(Origin::Unproven, "alice", &b).verdict, Verdict::Unproven);
        assert!(verdict(Origin::Synced, "alice", &b).spec.is_none());
    }

    #[test]
    fn the_requester_must_be_the_accepted_sender() {
        let b = body(&payload("fileview", r#"{"path":"/proj"}"#, "alice", "r1"));
        let e = verdict(Origin::Local, "mallory", &b);
        assert_eq!(e.verdict, Verdict::BadRequester);
        assert!(!e.requester_matches && e.spec.is_none());
    }

    #[test]
    fn panes_that_are_missing_or_unavailable_say_so() {
        let e = verdict(Origin::Local, "a", &body(&payload("addon:x/y/z", "{}", "a", "r1")));
        assert_eq!((e.verdict, e.install_target.as_deref()), (Verdict::NotInstalled, Some("x/y")));
        let e = verdict(Origin::Local, "a", &body(&payload("browser", r#"{"url":"https://example.com"}"#, "a", "r2")));
        assert_eq!((e.verdict, e.install_target), (Verdict::NotInstalled, None));
        let e = verdict(Origin::Local, "a", &body(&payload("addon:o/r/off", "{}", "a", "r3")));
        assert_eq!(e.verdict, Verdict::Unavailable);
    }

    #[test]
    fn args_must_match_what_the_pane_opens_with() {
        let v = |pane: &str, args: &str| verdict(Origin::Local, "a", &body(&payload(pane, args, "a", "r1"))).verdict;
        assert_eq!(v("fileview", r#"{"path":"/proj"}"#), Verdict::Ready);
        assert_eq!(v("fileview", r#"{"path":"/proj","base":"main"}"#), Verdict::ArgsNotAllowed); // no git:read
        assert_eq!(v("fileview", "{}"), Verdict::ArgsNotAllowed); // path is required
        assert_eq!(v("fileview", r#"{"url":"https://x"}"#), Verdict::ArgsNotAllowed);
        assert_eq!(v("diffview", r#"{"base":"main"}"#), Verdict::ArgsNotAllowed); // base only with a path
        assert_eq!(v("addon:o/r/viewer", "{}"), Verdict::Ready);
        assert_eq!(v("addon:o/r/viewer", r#"{"path":"/proj"}"#), Verdict::ArgsNotAllowed);
    }

    #[test]
    fn a_path_must_exist_and_not_be_protected() {
        let v = |path: &str| verdict(Origin::Local, "a", &body(&payload("fileview", &format!(r#"{{"path":"{path}"}}"#), "a", "r1")));
        assert_eq!(v("/proj").verdict, Verdict::Ready);
        let missing = v("/nope");
        assert_eq!((missing.verdict, missing.path_state), (Verdict::NotFoundHere, Some("missing")));
        let denied = v("/secret");
        assert_eq!((denied.verdict, denied.path_state), (Verdict::DeniedPath, Some("denied")));
        assert!(denied.spec.is_none());
    }

    // ---- assembling rows ----

    fn cand(id: &str, from: &str, b: &str, origin: Origin) -> Candidate {
        Candidate { id: id.into(), team: "t".into(), from: from.into(), to: "me".into(), body: b.into(), created_at: format!("2026-10-23T00:00:{id:0>2}Z"), origin }
    }

    fn state_row(id: &str, payload_sha: &str) -> StateRow {
        StateRow { request_id: id.into(), team: "t".into(), state: "dismissed".into(), at: "2026-10-23T00:00:00Z".into(), payload_sha256: payload_sha.into(), token_sha256: "h".into() }
    }

    #[test]
    fn identical_repeats_are_one_request_and_reuse_with_other_content_is_refused() {
        let a = body(&payload("fileview", r#"{"path":"/proj"}"#, "alice", "r1"));
        let other = body(&payload("fileview", r#"{"path":"/secret"}"#, "alice", "r1"));
        let (rows, handled, found) = assemble(&[cand("1", "alice", &a, Origin::Local), cand("2", "alice", &a, Origin::Local), cand("3", "alice", &other, Origin::Local)], &[], &env());
        assert!(handled.is_empty());
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].verdict, Verdict::Ready);
        assert_eq!((rows[1].verdict, rows[1].refusal.as_ref().map(|r| r.reason)), (Verdict::Refused, Some("request_id_reused")));
        assert_eq!(found.len(), 1);
    }

    #[test]
    fn a_handled_request_leaves_the_list_and_its_id_cannot_be_reused() {
        let a = body(&payload("fileview", r#"{"path":"/proj"}"#, "alice", "r1"));
        let sha = req(&a).payload_sha256;
        let (rows, handled, found) = assemble(&[cand("1", "alice", &a, Origin::Local)], &[state_row("r1", &sha)], &env());
        assert!(rows.is_empty() && found.is_empty());
        assert_eq!(handled, vec!["r1".to_string()]);
        // the same id carrying other content after it was handled
        let other = body(&payload("fileview", r#"{"path":"/secret"}"#, "alice", "r1"));
        let (rows, _, found) = assemble(&[cand("2", "alice", &other, Origin::Local)], &[state_row("r1", &sha)], &env());
        assert_eq!(rows[0].refusal.as_ref().map(|r| r.reason), Some("request_id_reused"));
        assert!(found.is_empty());
    }

    #[test]
    fn synced_and_unproven_rows_are_listed_but_never_openable() {
        let a = body(&payload("fileview", r#"{"path":"/proj"}"#, "alice", "r1"));
        let bad = format!("{HEADER}\nnot json");
        let (rows, _, found) = assemble(&[cand("1", "alice", &a, Origin::Synced), cand("2", "alice", &a, Origin::Unproven), cand("3", "alice", &bad, Origin::Synced), cand("4", "alice", &bad, Origin::Local)], &[], &env());
        let v: Vec<Verdict> = rows.iter().map(|r| r.verdict).collect();
        assert_eq!(v, vec![Verdict::Synced, Verdict::Unproven, Verdict::Synced, Verdict::Refused]);
        assert!(found.is_empty());
        assert!(rows[2].refusal.is_none(), "a synced row does not get a note about its own body");
        assert_eq!(rows[3].refusal.as_ref().map(|r| r.reason), Some("bad_json"));
        // a synced copy of an id never makes the local one a duplicate or a handled request
        let (rows, _, found) = assemble(&[cand("1", "alice", &a, Origin::Synced), cand("2", "alice", &a, Origin::Local)], &[], &env());
        assert_eq!(rows.iter().map(|r| r.verdict).collect::<Vec<_>>(), vec![Verdict::Synced, Verdict::Ready]);
        assert_eq!(found.len(), 1);
    }

    #[test]
    fn every_row_says_the_token_is_unverified() {
        let a = body(&payload("fileview", r#"{"path":"/proj"}"#, "alice", "r1"));
        let (rows, _, _) = assemble(&[cand("1", "alice", &a, Origin::Local)], &[], &env());
        let j = serde_json::to_value(&rows[0]).unwrap();
        assert_eq!(j["tokenCheck"], "unverified");
        assert_eq!(j["verdict"], "ready");
        assert_eq!(j["origin"], "local");
        assert_eq!(j["requesterMatches"], true);
        assert_eq!(j["pathState"], "exists");
        assert_eq!(j["created_at"], "2026-10-23T00:00:01Z");
    }

    // ---- the state file ----

    #[test]
    fn a_decision_is_recorded_once_and_survives_a_restart() {
        let d = tempfile::tempdir().unwrap();
        let row = |id: &str| StateRow { request_id: id.into(), team: "t".into(), state: "opened".into(), at: "2026-10-23T00:00:00Z".into(), payload_sha256: "p".into(), token_sha256: "h".into() };
        assert!(state_record(d.path(), row("r1")).unwrap());
        assert!(!state_record(d.path(), row("r1")).unwrap(), "the second click on the same id does nothing");
        assert!(state_record(d.path(), row("r2")).unwrap());
        let ids = handled_ids(d.path());
        assert!(ids.contains("r1") && ids.contains("r2") && ids.len() == 2);
        // the token is never written, only its hash
        let text = fs::read_to_string(state_path(d.path())).unwrap();
        assert!(!text.contains("tok-1"));
    }

    #[test]
    fn a_line_that_does_not_parse_is_not_a_decision() {
        let d = tempfile::tempdir().unwrap();
        fs::write(state_path(d.path()), "r1\tt\topened\n\u{0}bad\nr2 x\tt\topened\tat\tp\th\nr3\tt\topened\tat\tp\th\n").unwrap();
        let ids = handled_ids(d.path());
        assert_eq!(ids.len(), 1);
        assert!(ids.contains("r3"));
    }

    #[test]
    fn the_state_file_keeps_the_newest_rows() {
        let d = tempfile::tempdir().unwrap();
        let mut rows: Vec<StateRow> = (0..STATE_CAP).map(|i| state_row(&format!("old-{i}"), "p")).collect();
        rows.push(state_row("keep", "p"));
        state_write(d.path(), &rows[1..]).unwrap();
        assert!(state_record(d.path(), state_row("new", "p")).unwrap());
        let ids = handled_ids(d.path());
        assert_eq!(ids.len(), STATE_CAP);
        assert!(ids.contains("new") && ids.contains("keep") && !ids.contains("old-1"));
    }

    // ---- the store ----

    fn store(with_sync: bool, with_legacy_id: bool) -> Connection {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch(&format!(
            "CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT NOT NULL, id TEXT NOT NULL, team TEXT, from_agent TEXT, to_agent TEXT, body TEXT, msg_id TEXT, agent TEXT, at TEXT NOT NULL{});
             CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, team TEXT NOT NULL, from_agent TEXT NOT NULL, to_agent TEXT NOT NULL, body TEXT NOT NULL, created_at TEXT NOT NULL, read_at TEXT);",
            if with_legacy_id { ", legacy_id INTEGER" } else { "" }
        ))
        .unwrap();
        if with_sync {
            c.execute_batch("CREATE TABLE sync_messages (local_team TEXT NOT NULL, local_id TEXT NOT NULL, direction TEXT NOT NULL CHECK(direction IN ('push','pull')));").unwrap();
        }
        c
    }

    fn sent(c: &Connection, id: &str, team: &str, from: &str, to: &str, body: &str, at: &str) {
        c.execute("INSERT INTO events(type,id,team,from_agent,to_agent,body,at) VALUES('message_sent',?1,?2,?3,?4,?5,?6)", rusqlite::params![id, team, from, to, body, at]).unwrap();
    }

    #[test]
    fn the_scan_reads_only_requests_to_the_app_user_of_this_team() {
        let c = store(true, true);
        let b = body(&payload("fileview", r#"{"path":"/proj"}"#, "alice", "r1"));
        sent(&c, "e1", "t", "alice", "me", &b, "2026-10-23T00:00:01Z");
        sent(&c, "e2", "t", "alice", "someone-else", &b, "2026-10-23T00:00:02Z");
        sent(&c, "e3", "other", "alice", "me", &b, "2026-10-23T00:00:03Z");
        sent(&c, "e4", "t", "alice", "me", "just chatting", "2026-10-23T00:00:04Z");
        sent(&c, "e5", "t", "alice", "me", &format!(" {b}"), "2026-10-23T00:00:05Z");
        let (rows, truncated) = scan_sqlite(&c, "t", "me", 10).unwrap();
        assert!(!truncated);
        assert_eq!(rows.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), vec!["e1"]);
        assert_eq!(rows[0].origin, Origin::Local);
    }

    #[test]
    fn a_pulled_row_is_synced_and_a_store_that_never_synced_is_local() {
        let b = body(&payload("fileview", r#"{"path":"/proj"}"#, "alice", "r1"));
        let c = store(true, true);
        sent(&c, "mine", "t", "alice", "me", &b, "2026-10-23T00:00:01Z");
        sent(&c, "theirs", "t", "alice", "me", &b, "2026-10-23T00:00:02Z");
        sent(&c, "pushed", "t", "alice", "me", &b, "2026-10-23T00:00:03Z");
        c.execute("INSERT INTO sync_messages VALUES('t','theirs','pull')", []).unwrap();
        c.execute("INSERT INTO sync_messages VALUES('t','pushed','push')", []).unwrap();
        let (rows, _) = scan_sqlite(&c, "t", "me", 10).unwrap();
        let o: Vec<(&str, Origin)> = rows.iter().map(|r| (r.id.as_str(), r.origin)).collect();
        assert_eq!(o, vec![("mine", Origin::Local), ("theirs", Origin::Synced), ("pushed", Origin::Local)]);
        let c = store(false, true);
        sent(&c, "only", "t", "alice", "me", &b, "2026-10-23T00:00:01Z");
        assert_eq!(scan_sqlite(&c, "t", "me", 10).unwrap().0[0].origin, Origin::Local);
    }

    #[test]
    fn a_legacy_row_is_unproven_and_its_event_copy_is_not_read_twice() {
        let b = body(&payload("fileview", r#"{"path":"/proj"}"#, "alice", "r1"));
        let c = store(true, true);
        // one message written to both tables, linked by legacy_id
        c.execute("INSERT INTO messages(team,from_agent,to_agent,body,created_at) VALUES('t','alice','me',?1,'2026-10-23T00:00:01Z')", [&b]).unwrap();
        c.execute("INSERT INTO events(type,id,team,from_agent,to_agent,body,at,legacy_id) VALUES('message_sent','ev1','t','alice','me',?1,'2026-10-23T00:00:01Z',1)", [&b]).unwrap();
        // one legacy row with no event at all
        c.execute("INSERT INTO messages(team,from_agent,to_agent,body,created_at) VALUES('t','alice','me',?1,'2026-10-23T00:00:02Z')", [&b]).unwrap();
        let (rows, _) = scan_sqlite(&c, "t", "me", 10).unwrap();
        let o: Vec<(&str, Origin)> = rows.iter().map(|r| (r.id.as_str(), r.origin)).collect();
        assert_eq!(o, vec![("ev1", Origin::Local), ("2", Origin::Unproven)]);
    }

    #[test]
    fn older_stores_still_scan() {
        let b = body(&payload("fileview", r#"{"path":"/proj"}"#, "alice", "r1"));
        // events without legacy_id
        let c = store(false, false);
        c.execute("INSERT INTO messages(team,from_agent,to_agent,body,created_at) VALUES('t','alice','me',?1,'2026-10-23T00:00:01Z')", [&b]).unwrap();
        sent(&c, "ev1", "t", "alice", "me", &b, "2026-10-23T00:00:02Z");
        let (rows, _) = scan_sqlite(&c, "t", "me", 10).unwrap();
        assert_eq!(rows.len(), 2);
        // no event log at all
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch("CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, team TEXT NOT NULL, from_agent TEXT NOT NULL, to_agent TEXT NOT NULL, body TEXT NOT NULL, created_at TEXT NOT NULL, read_at TEXT);").unwrap();
        c.execute("INSERT INTO messages(team,from_agent,to_agent,body,created_at) VALUES('t','alice','me',?1,'2026-10-23T00:00:01Z')", [&b]).unwrap();
        let (rows, _) = scan_sqlite(&c, "t", "me", 10).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].origin, Origin::Unproven);
    }

    #[test]
    fn the_scan_keeps_the_newest_and_says_when_it_left_some_out() {
        let c = store(true, true);
        for i in 0..7 {
            let b = body(&payload("fileview", r#"{"path":"/proj"}"#, "alice", &format!("r{i}")));
            sent(&c, &format!("e{i}"), "t", "alice", "me", &b, &format!("2026-10-23T00:00:0{i}Z"));
        }
        let (rows, truncated) = scan_sqlite(&c, "t", "me", 5).unwrap();
        assert!(truncated);
        assert_eq!(rows.iter().map(|r| r.id.as_str()).collect::<Vec<_>>(), vec!["e2", "e3", "e4", "e5", "e6"]);
    }

    // ---- against the real catalog and denylist ----

    fn host_env_parts() -> (tempfile::TempDir, AddonHost) {
        // the shipped layout: <root>/<name>/<pane>/… (the app-panes folder itself; only what the build pins, not the sources)
        fn copy(from: &Path, to: &Path) {
            fs::create_dir_all(to).unwrap();
            for e in fs::read_dir(from).unwrap().flatten() {
                let (src, dst) = (e.path(), to.join(e.file_name()));
                if src.is_dir() {
                    copy(&src, &dst);
                } else {
                    fs::copy(&src, &dst).unwrap();
                }
            }
        }
        let d = tempfile::tempdir().unwrap();
        let root = d.path().join("builtin-addons");
        for name in ["fileview", "diffview"] {
            copy(&PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../addons").join(name).join("app-panes"), &root.join(name));
        }
        let h = AddonHost::new(None);
        h.set_catalog_for_test(super::super::catalog::Catalog::new(Some(root), d.path().join("addons")));
        (d, h)
    }

    #[test]
    fn the_built_in_panes_are_found_with_what_they_open_with() {
        let (_d, h) = host_env_parts();
        let env = HostEnv::with(&h, None);
        assert_eq!(env.pane(&Target::Fileview), PaneState::Found { addon_id: "builtin:fileview".into(), pane: "fileview".into(), opens: vec!["path".into()], git_read: false });
        assert_eq!(env.pane(&Target::Diffview), PaneState::Found { addon_id: "builtin:diffview".into(), pane: "diffview".into(), opens: vec!["path".into()], git_read: true });
        assert_eq!(env.pane(&Target::Browser), PaneState::NotInstalled);
        assert_eq!(env.pane(&Target::Addon { owner: "x".into(), repo: "y".into(), pane: "z".into() }), PaneState::NotInstalled);
    }

    #[test]
    fn while_add_ons_are_off_nothing_can_open() {
        let (_d, h) = host_env_parts();
        // the startup check has not passed in a unit test: this is the real gate, not a stand-in
        let env = HostEnv::new(&h);
        match env.pane(&Target::Fileview) {
            PaneState::Unavailable(why) => assert!(why.starts_with("add-ons are off on this computer"), "{why}"),
            other => panic!("{other:?}"),
        }
        let b = body(&payload("fileview", r#"{"path":"/tmp"}"#, "alice", "r1"));
        assert_eq!(evaluate(Origin::Local, "alice", &req(&b), &env).verdict, Verdict::Unavailable);
    }

    #[test]
    #[serial_test::serial]
    fn the_agmsg_home_is_a_protected_place_and_a_missing_path_is_missing() {
        let (_d, h) = host_env_parts();
        let base = tempfile::tempdir().unwrap();
        let proj = tempfile::tempdir().unwrap();
        std::env::set_var("AGMSG_APP_BASE", base.path());
        std::fs::create_dir_all(base.path().join("db")).unwrap();
        let env = HostEnv::with(&h, None);
        let denied = env.path(base.path().join("db").to_str().unwrap());
        let ok = env.path(proj.path().to_str().unwrap());
        let missing = env.path(proj.path().join("nope").to_str().unwrap());
        std::env::remove_var("AGMSG_APP_BASE");
        assert_eq!(denied, PathState::Denied);
        assert_eq!(ok, PathState::Exists(std::fs::canonicalize(proj.path()).unwrap()));
        assert_eq!(missing, PathState::Missing);
    }

    /// The scan against a store the real scripts wrote, in a throwaway base (nothing of the user's is read or written).
    #[cfg(unix)]
    #[test]
    #[serial_test::serial]
    fn a_request_sent_with_the_real_scripts_is_found_and_checked() {
        use std::process::Command;
        let scripts = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../scripts");
        let have = |bin: &str| Command::new(bin).arg("--version").output().is_ok();
        if !scripts.is_dir() || !have("bash") || !have("sqlite3") {
            eprintln!("skipped: needs the repository scripts, bash and sqlite3");
            return;
        }
        fn copy(from: &Path, to: &Path) {
            fs::create_dir_all(to).unwrap();
            for e in fs::read_dir(from).unwrap().flatten() {
                let (src, dst) = (e.path(), to.join(e.file_name()));
                if src.is_dir() {
                    copy(&src, &dst);
                } else {
                    fs::copy(&src, &dst).unwrap();
                }
            }
        }
        let base = tempfile::tempdir().unwrap();
        let proj = tempfile::tempdir().unwrap();
        copy(&scripts, &base.path().join("scripts"));
        fs::create_dir_all(base.path().join("teams")).unwrap();
        let vars = [("AGMSG_APP_BASE", base.path().to_path_buf()), ("AGMSG_CONFIG", base.path().join("config.json")), ("AGMSG_STORAGE_PATH", base.path().join("db"))];
        for (k, v) in &vars {
            std::env::set_var(k, v);
        }
        let run = |args: &[&str]| {
            let o = Command::new("bash").arg(base.path().join("scripts").join(args[0])).args(&args[1..]).output().unwrap();
            assert!(o.status.success(), "{args:?}: {}", String::from_utf8_lossy(&o.stderr));
        };
        let real_proj = fs::canonicalize(proj.path()).unwrap();
        let b = body(&payload("fileview", &format!(r#"{{"path":"{}"}}"#, real_proj.display()), "alice", "r-real-1"));
        run(&["join.sh", "t", "me", "agmsg-app", proj.path().to_str().unwrap()]);
        run(&["send.sh", "t", "alice", "me", &b, "--force"]);
        run(&["send.sh", "t", "alice", "me", "hello there", "--force"]);

        let user = app_user_of("t");
        let cands = candidates("t", "me");
        let (_d, h) = host_env_parts();
        let env = HostEnv::with(&h, None);
        let local = cands.as_ref().ok().map(|(c, _)| assemble(c, &[], &env));

        // the same row after sync brought it in
        let db = base.path().join("db/messages.db");
        let conn = Connection::open(&db).unwrap();
        conn.execute_batch("CREATE TABLE sync_messages (local_team TEXT NOT NULL, local_id TEXT NOT NULL, direction TEXT NOT NULL);").unwrap();
        conn.execute("INSERT INTO sync_messages SELECT team, id, 'pull' FROM events WHERE type='message_sent'", []).unwrap();
        drop(conn);
        let synced = candidates("t", "me").ok().map(|(c, _)| assemble(&c, &[], &env).0);
        for (k, _) in &vars {
            std::env::remove_var(k);
        }

        assert_eq!(user.unwrap(), Some("me".to_string()));
        let (cands, truncated) = cands.unwrap();
        assert!(!truncated);
        assert_eq!(cands.len(), 1, "the chat message is not a request, and the legacy copy is not read twice: {cands:?}");
        assert_eq!((cands[0].from.as_str(), cands[0].origin), ("alice", Origin::Local));
        let (rows, handled, found) = local.unwrap();
        assert!(handled.is_empty());
        assert_eq!((rows.len(), rows[0].verdict, rows[0].requester_matches, rows[0].path_state), (1, Verdict::Ready, true, Some("exists")));
        let spec = found[0].evaluated.spec.clone().unwrap();
        assert_eq!((spec.addon_id.as_str(), spec.pane.as_str(), spec.open_args.path.as_deref()), ("builtin:fileview", "fileview", Some(real_proj.to_str().unwrap())));
        let rows = synced.unwrap();
        assert_eq!((rows.len(), rows[0].verdict, rows[0].origin), (1, Verdict::Synced, Origin::Synced));
    }
}
