//! What an add-on may do with a team: join it as a member, send a message, start
//! agents (design `addon-agent-powers`, 2.1-2.3).
//!
//! Everything the process gets is decided here from the pane's identity and its
//! grants (`Authorized`): the team, the sender, the type's executable and options
//! never come from the frame. The frame supplies only `to`, `body`, `type`, `name`,
//! `folder` and `model`.
//!
//! Join and spawn are not repeatable without effect, so each goes through a small
//! persisted journal (one entry per add-on, team and requested name) and one
//! app-wide lock per team. Every state is written before the side effect it names
//! starts, so a crash leaves an entry at the last step that may have happened.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use super::denylist::Denylist;
use super::panes::{Authorized, BrokerError};

type Res = Result<Value, BrokerError>;

/// The member type core accepts for an add-on (`scripts/drivers/types/app-addon`).
pub const MEMBER_TYPE: &str = "app-addon";

/// After a restart, an entry that was `opening` becomes `joined` only where a PTY child is known never
/// to outlive a killed app (design 2.3, measurement M-5). Without that evidence it is `unknown`.
pub const OPENING_RECOVERS_TO_JOINED: bool = false;

// ---- names -------------------------------------------------------------------

/// The rules of `agmsg_validate_agent_name` (`scripts/lib/validate.sh`), the same ones the app applies
/// before any folder is made or any prompt is composed. `Err` is a phrase that follows "name".
pub fn validate_name(name: &str) -> Result<(), String> {
    if name.is_empty() {
        return Err("must not be empty".into());
    }
    if name == "." || name == ".." {
        return Err("must not be \".\" or \"..\"".into());
    }
    if name.starts_with('-') {
        return Err("must not start with \"-\"".into());
    }
    if name.chars().any(|c| matches!(c, '.' | '/' | '\\' | '"' | '[' | ']') || c.is_control()) {
        return Err("must not contain . / \\ \" [ ] or control characters".into());
    }
    Ok(())
}

/// `wanted`, or `wanted-2`, `wanted-3`, ... : the first name `taken` does not know.
pub fn free_name(wanted: &str, taken: &dyn Fn(&str) -> bool) -> String {
    if !taken(wanted) {
        return wanted.to_string();
    }
    for n in 2..10_000 {
        let c = format!("{wanted}-{n}");
        if !taken(&c) {
            return c;
        }
    }
    format!("{wanted}-{}", random_id())
}

/// A pane name made fit for a member name (the default `member`).
pub fn member_from_pane(pane: &str) -> String {
    let s: String = pane.chars().map(|c| if matches!(c, '.' | '/' | '\\' | '"' | '[' | ']') || c.is_control() { '-' } else { c }).collect();
    let s = s.trim_start_matches('-').to_string();
    if s.is_empty() {
        "addon".into()
    } else {
        s
    }
}

/// A model value is passed after the type's `model_arg`: one plain token.
pub fn validate_model(model: &str) -> Result<(), String> {
    if model.is_empty() || model.len() > 100 {
        return Err("must be 1 to 100 characters".into());
    }
    if model.starts_with('-') {
        return Err("must not start with \"-\"".into());
    }
    if !model.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | ':' | '/' | '@' | '+' | '-' | '[' | ']')) {
        return Err("may contain letters, digits and . _ : / @ + - [ ] only".into());
    }
    Ok(())
}

fn random_id() -> String {
    let mut b = [0u8; 8];
    let _ = getrandom::getrandom(&mut b);
    b.iter().map(|x| format!("{x:02x}")).collect()
}

// ---- the world the manager acts on (replaced in tests) ------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MemberInfo {
    pub name: String,
    pub types: Vec<String>,
    pub project: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpawnType {
    pub name: String,
    pub model_arg: Option<String>,
}

pub trait World: Send + Sync {
    fn members(&self, team: &str) -> Result<Vec<MemberInfo>, String>;
    /// The team's stable id (`team_id` in its config); a rename keeps it.
    fn team_id(&self, team: &str) -> Option<String>;
    /// The team's current name, from its id.
    fn team_name(&self, team_id: &str) -> Option<String>;
    fn join(&self, team: &str, name: &str, agent_type: &str, project: &str) -> Result<(), String>;
    fn send(&self, team: &str, from: &str, to: &str, body: &str) -> Result<(), String>;
    fn spawnable(&self) -> Result<Vec<SpawnType>, String>;
    /// `Some(token)` while the process lives; the token tells it from another process with a reused id.
    fn process_start(&self, pid: u32) -> Option<String>;
    /// Ask the window to open the terminal pane for this entry. The window rebuilds the command from the
    /// member and the type (the app's own add-agent code); only these fields cross.
    fn open_pane(&self, req: &OpenPane) -> Result<(), String>;
    /// Where a member of an add-on gets its own (unique) project folder.
    fn members_root(&self) -> PathBuf;
    /// `~/agmsg-agents`, the default parent of an agent's working folder.
    fn agents_home(&self) -> Option<PathBuf>;
}

#[derive(Debug, Clone, Serialize)]
pub struct OpenPane {
    pub key: String,
    pub team: String,
    pub name: String,
    #[serde(rename = "type")]
    pub agent_type: String,
    pub model: Option<String>,
}

/// The real thing: agmsg's scripts, the process table, the window.
pub struct RealWorld {
    pub app: Mutex<Option<tauri::AppHandle>>,
}

impl World for RealWorld {
    fn members(&self, team: &str) -> Result<Vec<MemberInfo>, String> {
        let ms = crate::agmsg::agmsg_members(team.to_string())?;
        Ok(ms.into_iter().map(|m| MemberInfo { name: m.name, types: m.types, project: m.project }).collect())
    }
    fn team_id(&self, team: &str) -> Option<String> {
        read_team_id(&crate::agmsg::base_dir().join("teams").join(team).join("config.json"))
    }
    fn team_name(&self, team_id: &str) -> Option<String> {
        let dir = std::fs::read_dir(crate::agmsg::base_dir().join("teams")).ok()?;
        dir.flatten().find(|e| read_team_id(&e.path().join("config.json")).as_deref() == Some(team_id)).and_then(|e| e.file_name().to_str().map(str::to_string))
    }
    fn join(&self, team: &str, name: &str, agent_type: &str, project: &str) -> Result<(), String> {
        crate::agmsg::agmsg_join(team.to_string(), name.to_string(), agent_type.to_string(), project.to_string())
    }
    fn send(&self, team: &str, from: &str, to: &str, body: &str) -> Result<(), String> {
        crate::agmsg::agmsg_send(team.to_string(), from.to_string(), to.to_string(), body.to_string())
    }
    fn spawnable(&self) -> Result<Vec<SpawnType>, String> {
        Ok(crate::agmsg::agmsg_spawnable_types()?.into_iter().map(|t| SpawnType { name: t.name, model_arg: t.model_arg }).collect())
    }
    fn process_start(&self, pid: u32) -> Option<String> {
        process_start_token(pid)
    }
    fn open_pane(&self, req: &OpenPane) -> Result<(), String> {
        use tauri::Emitter;
        let app = self.app.lock().unwrap().clone().ok_or("the app window is not ready")?;
        app.emit(OPEN_EVENT, req).map_err(|e| e.to_string())
    }
    fn members_root(&self) -> PathBuf {
        crate::agmsg::base_dir().join("addons").join("addon-members")
    }
    fn agents_home(&self) -> Option<PathBuf> {
        crate::agmsg::home_dir_string().map(|h| PathBuf::from(h).join("agmsg-agents"))
    }
}

fn read_team_id(config: &Path) -> Option<String> {
    let v: Value = serde_json::from_str(&std::fs::read_to_string(config).ok()?).ok()?;
    v.get("team_id").and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string)
}

/// The window opens a terminal pane for the entry named in the payload (`OpenPane`).
pub const OPEN_EVENT: &str = "addon-agent-open";

/// A token for "this process, started then": the start time as the OS prints it. One `ps` launch on
/// macOS and Linux, one PowerShell launch on Windows; asked when an agent's pane has started and once per
/// `running` entry after a restart.
pub fn process_start_token(pid: u32) -> Option<String> {
    #[cfg(unix)]
    {
        let out = std::process::Command::new("ps").args(["-o", "lstart=", "-p", &pid.to_string()]).output().ok()?;
        let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if out.status.success() && !s.is_empty() {
            Some(s)
        } else {
            None
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let out = std::process::Command::new("powershell")
            .creation_flags(0x0800_0000)
            .args(["-NoProfile", "-NonInteractive", "-Command", &format!("(Get-Process -Id {pid} -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o')")])
            .output()
            .ok()?;
        let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if out.status.success() && !s.is_empty() {
            Some(s)
        } else {
            None
        }
    }
}

// ---- the journal ---------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Claimed,
    Joined,
    Opening,
    Running,
    Failed,
    Orphaned,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// The add-on's own member (`team.join`).
    Member,
    /// An agent the add-on started (`agents.spawn`).
    Agent,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    pub key: String,
    pub addon: String,
    /// The team's stable id; entries are matched by it, so a rename does not orphan them.
    pub team_id: String,
    /// The team's name as last seen, for display and for the scripts.
    pub team: String,
    pub kind: Kind,
    /// The name asked for; the lookup key of a retry.
    pub requested: String,
    /// The member name actually used.
    pub name: String,
    pub agent_type: String,
    pub project: String,
    pub claim: String,
    pub model: Option<String>,
    pub state: State,
    pub pid: Option<u32>,
    pub start: Option<String>,
    pub reason: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Journal {
    entries: Vec<Entry>,
}

fn load(path: &Path) -> Journal {
    std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

fn store(path: &Path, j: &Journal) -> Result<(), BrokerError> {
    let io = |e: std::io::Error| BrokerError::new("not_available", format!("cannot write the add-on journal: {e}"));
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(io)?;
    }
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, serde_json::to_vec_pretty(j).unwrap_or_default()).map_err(io)?;
    std::fs::rename(&tmp, path).map_err(io)
}

// ---- the manager -----------------------------------------------------------------

/// How long `agents.spawn` waits for the window to report the process (or a failure) before it records one.
const OPEN_WAIT: std::time::Duration = std::time::Duration::from_secs(15);

pub struct Manager {
    open_wait: std::time::Duration,
    world: Arc<dyn World>,
    journal_path: PathBuf,
    journal: Mutex<Journal>,
    team_locks: Mutex<HashMap<String, Arc<Mutex<()>>>>,
}

static GLOBAL: OnceLock<Manager> = OnceLock::new();

/// The app's one manager. Set once at startup.
pub fn init_global(app: tauri::AppHandle) -> &'static Manager {
    GLOBAL.get_or_init(|| Manager::new(Arc::new(RealWorld { app: Mutex::new(Some(app)) }), crate::agmsg::base_dir().join("addons").join("agents-journal.json")))
}

pub fn global() -> Option<&'static Manager> {
    GLOBAL.get()
}

fn summary(e: &Entry) -> Value {
    let mut v = json!({ "name": e.name, "type": e.agent_type, "state": state_name(e.state) });
    let o = v.as_object_mut().unwrap();
    if e.requested != e.name {
        o.insert("requested".into(), json!(e.requested));
    }
    if matches!(e.state, State::Running | State::Orphaned) {
        if let Some(p) = e.pid {
            o.insert("pid".into(), json!(p));
        }
    }
    if let Some(r) = &e.reason {
        o.insert("reason".into(), json!(r));
    }
    v
}

fn state_name(s: State) -> &'static str {
    match s {
        // `claimed` is the app's own step; the pane sees the member as being set up
        State::Claimed => "opening",
        State::Joined => "joined",
        State::Opening => "opening",
        State::Running => "running",
        State::Failed => "failed",
        State::Orphaned => "orphaned",
        State::Unknown => "unknown",
    }
}

impl Manager {
    pub fn new(world: Arc<dyn World>, journal_path: PathBuf) -> Manager {
        let journal = load(&journal_path);
        Manager { open_wait: OPEN_WAIT, world, journal_path, journal: Mutex::new(journal), team_locks: Mutex::new(HashMap::new()) }
    }

    fn team_lock(&self, team: &str) -> Arc<Mutex<()>> {
        self.team_locks.lock().unwrap().entry(team.to_string()).or_default().clone()
    }

    /// Changes the journal and writes it before returning; the closure sees the whole journal.
    fn update<T>(&self, f: impl FnOnce(&mut Vec<Entry>) -> T) -> Result<T, BrokerError> {
        let mut j = self.journal.lock().unwrap();
        let out = f(&mut j.entries);
        store(&self.journal_path, &j)?;
        Ok(out)
    }

    fn find(&self, addon: &str, tid: &str, kind: Kind, requested: &str) -> Option<Entry> {
        self.journal.lock().unwrap().entries.iter().find(|e| e.addon == addon && e.team_id == tid && e.kind == kind && e.requested == requested).cloned()
    }

    /// The id entries of this team are filed under, and the name they show: the name is refreshed on every op.
    fn team_key(&self, team: &str) -> String {
        let tid = self.world.team_id(team).unwrap_or_else(|| team.to_string());
        let _ = self.update(|es| {
            for e in es.iter_mut().filter(|e| e.team_id == tid && e.team != team) {
                e.team = team.to_string();
            }
        });
        tid
    }

    fn by_key(&self, key: &str) -> Option<Entry> {
        self.journal.lock().unwrap().entries.iter().find(|e| e.key == key).cloned()
    }

    fn set_state(&self, key: &str, state: State, reason: Option<String>) -> Result<(), BrokerError> {
        self.update(|es| {
            if let Some(e) = es.iter_mut().find(|e| e.key == key) {
                e.state = state;
                e.reason = reason;
                if !matches!(state, State::Running | State::Orphaned) {
                    e.pid = None;
                    e.start = None;
                }
            }
        })
    }

    /// The member the add-on joined as in this team, if it has.
    pub fn member_of(&self, addon: &str, tid: &str) -> Option<Entry> {
        self.journal.lock().unwrap().entries.iter().find(|e| e.addon == addon && e.team_id == tid && e.kind == Kind::Member && e.state == State::Joined).cloned()
    }

    /// Every entry of one add-on in one team, for the add-on's own `agents.list` and the app's settings.
    pub fn entries_for(&self, addon: &str, tid: &str) -> Vec<Entry> {
        self.journal.lock().unwrap().entries.iter().filter(|e| e.addon == addon && e.team_id == tid).cloned().collect()
    }

    pub fn all_entries(&self) -> Vec<Entry> {
        self.journal.lock().unwrap().entries.clone()
    }

    // ---- ops ---------------------------------------------------------------------

    pub fn run(&self, a: &Authorized, deny: &Denylist, op: &str, args: &Value) -> Res {
        let team = a.team.clone().ok_or_else(|| BrokerError::new("not_granted", "no team is allowed for this pane"))?;
        let tid = self.team_key(&team);
        match op {
            "team.join" => self.team_join(a, &team, &tid),
            "messages.send" => self.messages_send(a, &team, &tid, args),
            "agents.types" => self.agents_types(),
            "agents.spawn" => self.agents_spawn(a, deny, &team, &tid, args),
            "agents.list" => Ok(json!({ "agents": self.entries_for(&a.addon, &tid).iter().filter(|e| e.kind == Kind::Agent).map(summary).collect::<Vec<_>>() })),
            _ => Err(BrokerError::new("bad_args", "unknown op")),
        }
    }

    fn team_join(&self, a: &Authorized, team: &str, tid: &str) -> Res {
        // a join still in progress (claimed) is waited for under the lock, not answered half done
        if let Some(e) = self.find(&a.addon, tid, Kind::Member, "").filter(|e| e.state != State::Claimed) {
            return self.member_reply(&e, false);
        }
        let lock = self.team_lock(team);
        let _held = lock.lock().unwrap();
        // another pane of the same add-on may have joined while this one waited
        if let Some(e) = self.find(&a.addon, tid, Kind::Member, "") {
            return self.member_reply(&e, false);
        }
        let wanted = a.member.clone().unwrap_or_else(|| member_from_pane(&a.pane));
        validate_name(&wanted).map_err(|w| BrokerError::new("bad_args", format!("member name {w}")))?;
        let before = self.world.members(team).map_err(|e| BrokerError::new("not_available", e))?;
        let name = free_name(&wanted, &|n| before.iter().any(|m| m.name == n));
        let claim = random_id();
        let project = self.world.members_root().join(&claim);
        std::fs::create_dir_all(&project).map_err(|e| BrokerError::new("not_available", format!("cannot create the member folder: {e}")))?;
        let project_s = project.to_string_lossy().into_owned();
        let key = format!("m-{claim}");
        self.update(|es| {
            es.push(Entry { key: key.clone(), addon: a.addon.clone(), team_id: tid.to_string(), team: team.to_string(), kind: Kind::Member, requested: String::new(), name: name.clone(), agent_type: MEMBER_TYPE.into(), project: project_s.clone(), claim: claim.clone(), model: None, state: State::Claimed, pid: None, start: None, reason: None })
        })?;
        if let Err(e) = self.world.join(team, &name, MEMBER_TYPE, &project_s) {
            self.set_state(&key, State::Failed, Some(e.clone()))?;
            return Err(BrokerError::new("not_available", format!("could not join the team: {e}")));
        }
        match self.confirm_ours(team, &name, MEMBER_TYPE, &project_s) {
            Ok(()) => self.set_state(&key, State::Joined, None)?,
            Err(why) => {
                self.set_state(&key, State::Failed, Some(why.clone()))?;
                return Err(BrokerError::new("conflict", why));
            }
        }
        let e = self.by_key(&key).expect("just written");
        self.member_reply(&e, true)
    }

    fn member_reply(&self, e: &Entry, created: bool) -> Res {
        match e.state {
            State::Joined => Ok(json!({ "name": e.name, "type": MEMBER_TYPE, "created": created })),
            State::Failed => Err(BrokerError::new("conflict", e.reason.clone().unwrap_or_else(|| "joining the team failed".into()))),
            _ => Err(BrokerError::new("not_available", "joining the team is not finished")),
        }
    }

    /// After `join.sh`: the member exists, with exactly one registration, and it is the one made here.
    /// An outside join of the same name with the same type and folder cannot be told from ours (Q6).
    fn confirm_ours(&self, team: &str, name: &str, agent_type: &str, project: &str) -> Result<(), String> {
        let ms = self.world.members(team)?;
        let m = ms.iter().find(|m| m.name == name).ok_or_else(|| format!("the member {name} is not in the team after joining"))?;
        let mut types = m.types.clone();
        types.sort();
        types.dedup();
        if types != [agent_type.to_string()] || !same_path(&m.project, project) {
            return Err(format!("the member name {name} was taken by someone else while joining; nothing was adopted"));
        }
        Ok(())
    }

    fn messages_send(&self, a: &Authorized, team: &str, tid: &str, args: &Value) -> Res {
        let to = str_arg(args, "to")?;
        let body = str_arg(args, "body")?;
        if to.is_empty() || body.is_empty() {
            return Err(BrokerError::new("bad_args", "`to` and `body` must not be empty"));
        }
        let me = self.member_of(&a.addon, tid).ok_or_else(|| BrokerError::new("not_granted", "the add-on has not joined the team (call team.join first)"))?;
        if to != "all" {
            let ms = self.world.members(team).map_err(|e| BrokerError::new("not_available", e))?;
            if !ms.iter().any(|m| m.name == to) {
                return Err(BrokerError::new("bad_args", format!("{to} is not a member of the team")));
            }
        }
        self.world.send(team, &me.name, &to, &body).map_err(|e| BrokerError::new("not_available", e))?;
        Ok(json!({ "to": to }))
    }

    fn agents_types(&self) -> Res {
        let ts = self.world.spawnable().map_err(|e| BrokerError::new("not_available", e))?;
        Ok(json!({ "types": ts.iter().map(|t| json!({ "type": t.name, "models": t.model_arg.is_some() })).collect::<Vec<_>>() }))
    }

    fn agents_spawn(&self, a: &Authorized, deny: &Denylist, team: &str, tid: &str, args: &Value) -> Res {
        // 1. validate everything before any side effect
        let agent_type = str_arg(args, "type")?;
        let wanted = str_arg(args, "name")?;
        validate_name(&wanted).map_err(|w| BrokerError::new("bad_args", format!("name {w}")))?;
        let types = self.world.spawnable().map_err(|e| BrokerError::new("not_available", e))?;
        let t = types.iter().find(|t| t.name == agent_type).ok_or_else(|| BrokerError::new("bad_args", format!("`{agent_type}` is not a type the app can start")))?;
        let model = match args.get("model") {
            None | Some(Value::Null) => None,
            Some(Value::String(m)) => {
                validate_model(m).map_err(|w| BrokerError::new("bad_args", format!("model {w}")))?;
                if t.model_arg.is_none() {
                    return Err(BrokerError::new("bad_args", format!("{agent_type} takes no model")));
                }
                Some(m.clone())
            }
            Some(_) => return Err(BrokerError::new("bad_args", "`model` must be a string")),
        };
        let folder_arg = match args.get("folder") {
            None | Some(Value::Null) => None,
            Some(Value::String(f)) => Some(f.clone()),
            Some(_) => return Err(BrokerError::new("bad_args", "`folder` must be a string")),
        };
        // 2. a retry: the entry for this requested name decides
        if let Some(e) = self.find(&a.addon, tid, Kind::Agent, &wanted) {
            return self.retry(&e, model);
        }
        // 3. a given folder is resolved before the lock; the default needs the final name, so it waits
        let given = match &folder_arg {
            Some(f) => Some(super::broker::resolve_dir(a, deny, f)?),
            None => None,
        };
        let lock = self.team_lock(team);
        let _held = lock.lock().unwrap();
        if let Some(e) = self.find(&a.addon, tid, Kind::Agent, &wanted) {
            return self.retry(&e, model);
        }
        let before = self.world.members(team).map_err(|e| BrokerError::new("not_available", e))?;
        let name = free_name(&wanted, &|n| before.iter().any(|m| m.name == n) || self.name_in_journal(tid, n));
        let folder = match given {
            Some(f) => f,
            None => self.default_folder(deny, &name)?,
        };
        let folder_s = folder.to_string_lossy().into_owned();
        let claim = random_id();
        let key = format!("a-{claim}");
        self.update(|es| {
            es.push(Entry { key: key.clone(), addon: a.addon.clone(), team_id: tid.to_string(), team: team.to_string(), kind: Kind::Agent, requested: wanted.clone(), name: name.clone(), agent_type: agent_type.clone(), project: folder_s.clone(), claim: claim.clone(), model: model.clone(), state: State::Claimed, pid: None, start: None, reason: None })
        })?;
        if let Err(e) = self.world.join(team, &name, &agent_type, &folder_s) {
            self.set_state(&key, State::Failed, Some(e.clone()))?;
            return Err(BrokerError::new("not_available", format!("could not join the team: {e}")));
        }
        if let Err(why) = self.confirm_agent(team, &name, &agent_type, &folder_s, &before) {
            self.set_state(&key, State::Failed, Some(why.clone()))?;
            return Err(BrokerError::new("conflict", why));
        }
        self.set_state(&key, State::Joined, None)?;
        self.open(&key)
    }

    fn name_in_journal(&self, tid: &str, name: &str) -> bool {
        self.journal.lock().unwrap().entries.iter().any(|e| e.team_id == tid && e.name == name && !matches!(e.state, State::Failed))
    }

    /// For a spawned agent "ours" is the registration with our type and folder, made when the member did
    /// not exist in the read taken under the lock just before `join.sh`.
    fn confirm_agent(&self, team: &str, name: &str, agent_type: &str, folder: &str, before: &[MemberInfo]) -> Result<(), String> {
        if before.iter().any(|m| m.name == name) {
            return Err(format!("the member name {name} appeared while joining; nothing was adopted"));
        }
        self.confirm_ours(team, name, agent_type, folder)
    }

    fn default_folder(&self, deny: &Denylist, name: &str) -> Result<PathBuf, BrokerError> {
        let home = self.world.agents_home().ok_or_else(|| BrokerError::new("not_available", "the home folder is not known"))?;
        let dir = home.join(name);
        std::fs::create_dir_all(&dir).map_err(|e| BrokerError::new("not_available", format!("cannot create {}: {e}", dir.display())))?;
        let real = std::fs::canonicalize(&dir).map_err(|e| BrokerError::new("not_available", e.to_string()))?;
        let home_real = std::fs::canonicalize(&home).map_err(|e| BrokerError::new("not_available", e.to_string()))?;
        if !real.starts_with(&home_real) {
            return Err(BrokerError::new("outside_root", "the agent's folder leads outside ~/agmsg-agents"));
        }
        if deny.is_denied(&real) {
            return Err(BrokerError::new("denied_path", super::denylist::refusal_message(&real)));
        }
        Ok(real)
    }

    fn retry(&self, e: &Entry, model: Option<String>) -> Res {
        match e.state {
            State::Joined => {
                // the resume path: a member whose pane did not open
                let _ = model;
                self.open(&e.key)
            }
            State::Failed => Err(BrokerError::new("not_available", e.reason.clone().unwrap_or_else(|| "starting the agent failed".into()))),
            _ => Ok(summary(e)),
        }
    }

    /// Opens the terminal pane for a joined entry. `opening` is written first; the window reports the process
    /// through `pty_started` once the pane has one.
    fn open(&self, key: &str) -> Res {
        let e = self.by_key(key).ok_or_else(|| BrokerError::new("not_available", "the entry is gone"))?;
        self.set_state(key, State::Opening, None)?;
        let req = OpenPane { key: key.to_string(), team: e.team.clone(), name: e.name.clone(), agent_type: e.agent_type.clone(), model: e.model.clone() };
        if let Err(why) = self.world.open_pane(&req) {
            // the member stays joined and recorded; the add-on may ask again
            self.set_state(key, State::Joined, Some(why.clone()))?;
            return Err(BrokerError::new("not_available", format!("{} joined the team but its terminal did not open: {why}", e.name)));
        }
        // The window answers through `pty_started` or `open_failed`. No entry stays `opening` after this returns:
        // silence is recorded as a failure (a late `pty_started` still moves it to `running`).
        let deadline = std::time::Instant::now() + self.open_wait;
        loop {
            match self.by_key(key) {
                Some(cur) if cur.state == State::Opening && std::time::Instant::now() < deadline => std::thread::sleep(std::time::Duration::from_millis(25)),
                _ => break,
            }
        }
        if self.by_key(key).is_some_and(|c| c.state == State::Opening) {
            self.set_state(key, State::Failed, Some(format!("The terminal for {} did not report within {} s.", e.name, self.open_wait.as_secs())))?;
        }
        Ok(summary(&self.by_key(key).expect("entry exists")))
    }

    /// The window could not open the terminal (no such member, a pane with that name is already open, the process
    /// did not start). The member stays; the user may open it again from the settings.
    pub fn open_failed(&self, key: &str, reason: &str) {
        let _ = self.update(|es| {
            if let Some(e) = es.iter_mut().find(|e| e.key == key && matches!(e.state, State::Opening | State::Joined)) {
                e.state = State::Failed;
                e.reason = Some(reason.chars().take(300).collect());
                e.pid = None;
                e.start = None;
            }
        });
    }

    // ---- reports from the terminal ------------------------------------------------

    /// The pane's process started. Stored the moment `pty_spawn` returns.
    pub fn pty_started(&self, key: &str, pid: u32) {
        let start = self.world.process_start(pid);
        let _ = self.update(|es| {
            if let Some(e) = es.iter_mut().find(|e| e.key == key) {
                e.state = State::Running;
                e.pid = Some(pid);
                e.start = start;
                e.reason = None;
            }
        });
    }

    /// The pane's process ended (or the pane was closed).
    pub fn pty_ended(&self, key: &str) {
        let _ = self.update(|es| {
            if let Some(e) = es.iter_mut().find(|e| e.key == key && matches!(e.state, State::Running | State::Opening)) {
                e.state = State::Joined;
                e.pid = None;
                e.start = None;
            }
        });
    }

    /// The user chose to open a new pane for an `orphaned` or `unknown` entry.
    pub fn reopen(&self, key: &str) -> Res {
        match self.by_key(key) {
            Some(e) if e.kind == Kind::Agent && matches!(e.state, State::Orphaned | State::Unknown | State::Joined | State::Failed) => {
                self.set_state(key, State::Joined, None)?;
                self.open(key)
            }
            Some(_) => Err(BrokerError::new("bad_args", "that agent is not waiting for a decision")),
            None => Err(BrokerError::new("not_found", "no such agent")),
        }
    }

    // ---- recovery at app start (design 2.3) ---------------------------------------

    pub fn recover(&self) {
        let entries = self.all_entries();
        for e in entries {
            let next: Option<Option<(State, Option<String>)>> = match e.state {
                State::Claimed => Some(self.recover_claimed(&e)),
                State::Running | State::Orphaned => {
                    let alive = e.pid.zip(e.start.as_ref()).is_some_and(|(p, s)| self.world.process_start(p).as_ref() == Some(s));
                    Some(Some((if alive { State::Orphaned } else { State::Joined }, None)))
                }
                State::Opening => Some(Some(if OPENING_RECOVERS_TO_JOINED {
                    (State::Joined, None)
                } else {
                    (State::Unknown, Some("The app stopped while this agent's terminal was starting; the app cannot tell whether it is running.".into()))
                })),
                _ => None,
            };
            match next {
                None => {}
                Some(None) => {
                    let _ = self.update(|es| es.retain(|x| x.key != e.key));
                }
                Some(Some((state, reason))) => {
                    let _ = self.set_state(&e.key, state, reason);
                }
            }
        }
    }

    fn recover_claimed(&self, e: &Entry) -> Option<(State, Option<String>)> {
        let team = self.world.team_name(&e.team_id).unwrap_or_else(|| e.team.clone());
        let ms = self.world.members(&team).ok()?;
        match ms.iter().find(|m| m.name == e.name) {
            None => None,
            Some(m) => {
                let mut types = m.types.clone();
                types.sort();
                types.dedup();
                if types == [e.agent_type.clone()] && same_path(&m.project, &e.project) {
                    Some((State::Joined, None))
                } else {
                    Some((State::Failed, Some(format!("the member name {} was taken by someone else while joining; nothing was adopted", e.name))))
                }
            }
        }
    }
}

fn str_arg(args: &Value, key: &str) -> Result<String, BrokerError> {
    match args.get(key) {
        Some(Value::String(s)) => Ok(s.clone()),
        _ => Err(BrokerError::new("bad_args", format!("`{key}` must be a string"))),
    }
}

fn same_path(a: &str, b: &str) -> bool {
    let norm = |p: &str| std::fs::canonicalize(p).map(|c| c.to_string_lossy().into_owned()).unwrap_or_else(|_| p.trim_end_matches(['/', '\\']).to_string());
    norm(a) == norm(b)
}

// ---- commands for the app's own window ---------------------------------------------

/// What the app's windows show about an entry (settings, sidebar, the pane's header).
#[derive(Debug, Clone, Serialize)]
pub struct EntryView {
    pub key: String,
    pub addon: String,
    pub team: String,
    pub kind: Kind,
    pub name: String,
    #[serde(rename = "type")]
    pub agent_type: String,
    pub state: State,
    pub pid: Option<u32>,
    pub reason: Option<String>,
}

impl From<Entry> for EntryView {
    fn from(e: Entry) -> EntryView {
        EntryView { key: e.key, addon: e.addon, team: e.team, kind: e.kind, name: e.name, agent_type: e.agent_type, state: e.state, pid: e.pid, reason: e.reason }
    }
}

/// Every member and agent add-ons have made, in every team, with where each stands.
#[tauri::command]
pub fn addon_members_state() -> Vec<EntryView> {
    global().map(|m| m.all_entries().into_iter().map(EntryView::from).collect()).unwrap_or_default()
}

/// The window could not open the terminal for an agent an add-on started.
#[tauri::command]
pub fn addon_agent_open_failed(key: String, reason: String) {
    if let Some(m) = global() {
        m.open_failed(&key, &reason);
    }
}

/// The user chose to open a new terminal for an agent that was `orphaned` or `unknown`.
#[tauri::command(async)]
pub fn addon_agent_reopen(key: String) -> Result<(), BrokerError> {
    global().ok_or_else(|| BrokerError::new("not_available", "the app is still starting"))?.reopen(&key).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::addons::panes::{AddPane, Declared, OpenArgs, Power, Registry};
    use crate::addons::server::Payload;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[derive(Default)]
    struct Fake {
        members: Mutex<Vec<MemberInfo>>,
        sent: Mutex<Vec<(String, String, String, String)>>,
        opened: Mutex<Vec<OpenPane>>,
        joins: AtomicUsize,
        fail_open: Mutex<bool>,
        /// a hook run inside `join`, standing for a `join.sh` somebody else runs at the same moment
        outside: Mutex<Option<Box<dyn Fn(&Fake) + Send>>>,
        alive: Mutex<HashMap<u32, String>>,
        /// what the window does when asked to open a pane (default: nothing answers)
        on_open: Mutex<Option<Box<dyn Fn(&OpenPane) + Send>>>,
        renamed: Mutex<HashMap<String, String>>,
        root: PathBuf,
        home: PathBuf,
    }

    impl World for Fake {
        fn members(&self, _team: &str) -> Result<Vec<MemberInfo>, String> {
            Ok(self.members.lock().unwrap().clone())
        }
        fn team_id(&self, team: &str) -> Option<String> {
            let r = self.renamed.lock().unwrap();
            Some(format!("id-{}", r.iter().find(|(_, new)| new.as_str() == team).map(|(old, _)| old.as_str()).unwrap_or(team)))
        }
        fn team_name(&self, id: &str) -> Option<String> {
            let old = id.strip_prefix("id-")?;
            Some(self.renamed.lock().unwrap().get(old).cloned().unwrap_or_else(|| old.to_string()))
        }
        fn join(&self, _team: &str, name: &str, t: &str, project: &str) -> Result<(), String> {
            self.joins.fetch_add(1, Ordering::SeqCst);
            if let Some(f) = self.outside.lock().unwrap().take() {
                f(self);
            }
            let mut ms = self.members.lock().unwrap();
            if let Some(m) = ms.iter_mut().find(|m| m.name == name) {
                // join.sh adds a registration to an existing member
                m.types.push(t.into());
            } else {
                ms.push(MemberInfo { name: name.into(), types: vec![t.into()], project: project.into() });
            }
            Ok(())
        }
        fn send(&self, team: &str, from: &str, to: &str, body: &str) -> Result<(), String> {
            self.sent.lock().unwrap().push((team.into(), from.into(), to.into(), body.into()));
            Ok(())
        }
        fn spawnable(&self) -> Result<Vec<SpawnType>, String> {
            Ok(vec![SpawnType { name: "claude-code".into(), model_arg: Some("--model".into()) }, SpawnType { name: "gemini".into(), model_arg: None }])
        }
        fn process_start(&self, pid: u32) -> Option<String> {
            self.alive.lock().unwrap().get(&pid).cloned()
        }
        fn open_pane(&self, req: &OpenPane) -> Result<(), String> {
            if *self.fail_open.lock().unwrap() {
                return Err("no window".into());
            }
            self.opened.lock().unwrap().push(req.clone());
            if let Some(f) = self.on_open.lock().unwrap().as_ref() {
                f(req);
            }
            Ok(())
        }
        fn members_root(&self) -> PathBuf {
            self.root.clone()
        }
        fn agents_home(&self) -> Option<PathBuf> {
            Some(self.home.clone())
        }
    }

    struct Fx {
        _tmp: tempfile::TempDir,
        world: Arc<Fake>,
        mgr: Arc<Manager>,
        reg: Mutex<Registry>,
        id: u64,
        gen: u64,
        deny: Denylist,
        granted: PathBuf,
        journal: PathBuf,
    }

    fn all_powers() -> Declared {
        Declared { team_join: true, messages_send: true, agents_spawn: true, files_read: true, ..Default::default() }
    }

    fn fx(declared: Declared) -> Fx {
        let tmp = tempfile::tempdir().unwrap();
        let base = tmp.path().canonicalize().unwrap();
        let granted = base.join("granted");
        std::fs::create_dir_all(granted.join("sub")).unwrap();
        let world = Arc::new(Fake { root: base.join("members"), home: base.join("home/agmsg-agents"), ..Default::default() });
        std::fs::create_dir_all(&world.home).unwrap();
        world.members.lock().unwrap().push(MemberInfo { name: "lead".into(), types: vec!["claude-code".into()], project: "/x".into() });
        let journal = base.join("journal.json");
        let mut m = Manager::new(world.clone(), journal.clone());
        m.open_wait = std::time::Duration::from_millis(600);
        let mgr = Arc::new(m);
        // the window answers a moment after it is asked: a process id for the pane
        let for_window = mgr.clone();
        *world.on_open.lock().unwrap() = Some(Box::new(move |req: &OpenPane| {
            let (m, key) = (for_window.clone(), req.key.clone());
            std::thread::spawn(move || {
                std::thread::sleep(std::time::Duration::from_millis(20));
                m.pty_started(&key, 4242);
            });
        }));
        let mut reg = Registry::new();
        let mut files = HashMap::new();
        files.insert("index.html".to_string(), b"x".to_vec());
        let id = reg
            .add(AddPane { addon: "o/chess".into(), commit: "c".into(), name: "chess".into(), payload: Payload::Embedded(files), entry: "index.html".into(), declared, open_args: OpenArgs::default(), expected_digest: None, pinned: None, on_tamper: None })
            .unwrap()
            .id;
        let gen = reg.begin_generation(id).unwrap();
        reg.grant_root(id, granted.clone()).ok();
        reg.grant_team(id, "t").ok();
        for p in [Power::Join, Power::Send, Power::Spawn] {
            reg.set_power(id, p, true).ok();
        }
        Fx { _tmp: tmp, world, mgr, reg: Mutex::new(reg), id, gen, deny: Denylist::from_process_env(vec![]), granted, journal }
    }

    fn call(f: &Fx, op: &str, args: Value) -> Res {
        crate::addons::broker::handle_power(&f.reg, &f.deny, &f.mgr, f.id, f.gen, op, &args)
    }
    fn code(r: Res) -> &'static str {
        r.unwrap_err().code
    }

    #[test]
    fn names_follow_the_core_rules() {
        for ok in ["chess", "chess-2", "a b", "white", "x_y", "名前"] {
            assert!(validate_name(ok).is_ok(), "{ok}");
        }
        for bad in ["", ".", "..", "-x", "a.b", "a/b", "a\\b", "a\"b", "a[b", "a]b", "a\nb", "a\u{7}b"] {
            assert!(validate_name(bad).is_err(), "{bad:?}");
        }
    }

    /// The Rust rules and `agmsg_validate_agent_name` give the same answer for the same names.
    #[test]
    fn names_agree_with_the_shell_validator() {
        let lib = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts/lib/validate.sh");
        if !lib.is_file() {
            return;
        }
        for name in ["chess", "chess-2", "a b", "x_y", "", ".", "..", "-x", "a.b", "a/b", "a\\b", "a\"b", "a[b", "a]b", "a\tb", "ok-name", "名前", "all", "*", "$x", "a;b"] {
            let out = std::process::Command::new("bash").arg("-c").arg(format!("source '{}'; agmsg_validate_agent_name \"$1\" 2>/dev/null", lib.display())).arg("_").arg(name).output().unwrap();
            assert_eq!(out.status.success(), validate_name(name).is_ok(), "{name:?}");
        }
    }

    #[test]
    fn a_free_name_is_picked_without_touching_anyone_elses() {
        let taken = |n: &str| ["chess", "chess-2"].contains(&n);
        assert_eq!(free_name("chess", &taken), "chess-3");
        assert_eq!(free_name("go", &taken), "go");
    }

    #[test]
    fn model_values_are_one_plain_token() {
        for ok in ["opus", "claude-3.5-sonnet", "gpt-5:high", "a/b", "opus[1m]"] {
            assert!(validate_model(ok).is_ok(), "{ok}");
        }
        for bad in ["", "-x", "--model", "a b", "a;b", "a$b", "a\nb", &"x".repeat(101)] {
            assert!(validate_model(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn undeclared_and_ungranted_are_refused_before_anything_happens() {
        let f = fx(Declared { team_join: true, ..Default::default() });
        assert_eq!(code(call(&f, "messages.send", json!({"to": "lead", "body": "x"}))), "not_declared");
        assert_eq!(code(call(&f, "agents.spawn", json!({"type": "claude-code", "name": "w"}))), "not_declared");
        assert_eq!(f.world.joins.load(Ordering::SeqCst), 0);
        let g = fx(all_powers());
        g.reg.lock().unwrap().set_power(g.id, Power::Send, false).unwrap();
        assert_eq!(code(call(&g, "messages.send", json!({"to": "lead", "body": "x"}))), "not_granted");
        g.reg.lock().unwrap().set_power(g.id, Power::Join, false).unwrap();
        assert_eq!(code(call(&g, "agents.types", json!({}))), "not_granted", "spawn needs the join power too");
        assert_eq!(code(call(&g, "nope", json!({}))), "bad_args");
    }

    #[test]
    fn join_is_once_and_a_taken_name_gets_a_free_one() {
        let f = fx(all_powers());
        f.world.members.lock().unwrap().push(MemberInfo { name: "chess".into(), types: vec!["claude-code".into()], project: "/y".into() });
        let r = call(&f, "team.join", json!({})).unwrap();
        assert_eq!((r["name"].as_str().unwrap(), r["created"].as_bool().unwrap()), ("chess-2", true), "the seat named chess is not touched");
        assert_eq!(r["type"], MEMBER_TYPE);
        let again = call(&f, "team.join", json!({})).unwrap();
        assert_eq!((again["name"].as_str().unwrap(), again["created"].as_bool().unwrap()), ("chess-2", false));
        assert_eq!(f.world.joins.load(Ordering::SeqCst), 1, "a retry runs no second join");
        let ms = f.world.members.lock().unwrap();
        let mine = ms.iter().find(|m| m.name == "chess-2").unwrap();
        assert!(mine.project.contains("members") && mine.types == [MEMBER_TYPE], "{mine:?}");
        assert_eq!(ms.iter().find(|m| m.name == "chess").unwrap().types, ["claude-code"]);
    }

    #[test]
    fn the_conf_member_name_is_used_and_checked() {
        let f = fx(Declared { member: Some("referee".into()), ..all_powers() });
        assert_eq!(call(&f, "team.join", json!({})).unwrap()["name"], "referee");
        let g = fx(Declared { member: Some("bad.name".into()), ..all_powers() });
        assert_eq!(code(call(&g, "team.join", json!({}))), "bad_args");
        assert_eq!(g.world.joins.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn send_comes_from_the_add_ons_member_whatever_the_frame_says() {
        let f = fx(all_powers());
        assert_eq!(code(call(&f, "messages.send", json!({"to": "lead", "body": "hi"}))), "not_granted", "join first");
        call(&f, "team.join", json!({})).unwrap();
        let r = call(&f, "messages.send", json!({"to": "lead", "body": "hi", "from": "lead", "team": "other", "sender": "lead"})).unwrap();
        assert_eq!(r["to"], "lead");
        assert_eq!(*f.world.sent.lock().unwrap(), vec![("t".to_string(), "chess".to_string(), "lead".to_string(), "hi".to_string())]);
        call(&f, "messages.send", json!({"to": "all", "body": "hello"})).unwrap();
        assert_eq!(code(call(&f, "messages.send", json!({"to": "nobody", "body": "x"}))), "bad_args");
        assert_eq!(code(call(&f, "messages.send", json!({"to": "lead", "body": ""}))), "bad_args");
        assert_eq!(code(call(&f, "messages.send", json!({"to": 3, "body": "x"}))), "bad_args");
        // no cap on the count, and a retried send is a second message
        for _ in 0..20 {
            call(&f, "messages.send", json!({"to": "lead", "body": "again"})).unwrap();
        }
        assert_eq!(f.world.sent.lock().unwrap().len(), 22);
    }

    #[test]
    fn spawn_validates_everything_before_any_side_effect() {
        let f = fx(all_powers());
        let before = std::fs::read_dir(&f.world.home).unwrap().count();
        for args in [
            json!({"type": "claude-code", "name": "../evil"}),
            json!({"type": "claude-code", "name": ".."}),
            json!({"type": "claude-code", "name": "-x"}),
            json!({"type": "claude-code", "name": ""}),
            json!({"type": "nope", "name": "w"}),
            json!({"type": "agmsg-app", "name": "w"}),
            json!({"type": "claude-code", "name": "w", "model": "--evil"}),
            json!({"type": "gemini", "name": "w", "model": "m"}),
            json!({"type": "claude-code", "name": "w", "model": 7}),
            json!({"type": "claude-code", "name": "w", "folder": "../outside"}),
            json!({"type": "claude-code", "name": "w", "folder": "missing"}),
            json!({"type": "claude-code", "name": 5}),
        ] {
            let e = call(&f, "agents.spawn", args.clone()).unwrap_err();
            assert!(matches!(e.code, "bad_args" | "not_found"), "{args}: {e:?}");
        }
        assert_eq!(f.world.joins.load(Ordering::SeqCst), 0);
        assert_eq!(std::fs::read_dir(&f.world.home).unwrap().count(), before, "no folder was made");
        assert!(f.mgr.all_entries().is_empty());
        assert!(f.world.opened.lock().unwrap().is_empty());
    }

    #[test]
    fn spawn_joins_records_and_opens_a_pane_with_server_owned_fields() {
        let f = fx(all_powers());
        let r = call(&f, "agents.spawn", json!({"type": "claude-code", "name": "white", "model": "opus", "team": "other", "cmd": "rm", "args": ["-rf"], "permission_mode": "bypass"})).unwrap();
        assert_eq!((r["name"].as_str().unwrap(), r["state"].as_str().unwrap(), r["pid"].as_u64().unwrap()), ("white", "running", 4242));
        let opened = f.world.opened.lock().unwrap().clone();
        assert_eq!(opened.len(), 1);
        let o = &opened[0];
        assert_eq!((o.team.as_str(), o.name.as_str(), o.agent_type.as_str(), o.model.as_deref()), ("t", "white", "claude-code", Some("opus")));
        let ms = f.world.members.lock().unwrap();
        let w = ms.iter().find(|m| m.name == "white").unwrap();
        assert!(w.project.ends_with("agmsg-agents/white"), "default folder: {}", w.project);
        drop(ms);
        let list = call(&f, "agents.list", json!({})).unwrap();
        assert_eq!(list["agents"][0]["state"], "running");
        assert_eq!(list["agents"][0]["pid"], 4242);
        // a retry returns the live agent, and does not join or open again
        let again = call(&f, "agents.spawn", json!({"type": "claude-code", "name": "white"})).unwrap();
        assert_eq!(again["state"], "running");
        assert_eq!((f.world.joins.load(Ordering::SeqCst), f.world.opened.lock().unwrap().len()), (1, 1));
        // the process ends: joined, and a new spawn call resumes it
        f.mgr.pty_ended(&o.key);
        assert_eq!(call(&f, "agents.list", json!({})).unwrap()["agents"][0]["state"], "joined");
        call(&f, "agents.spawn", json!({"type": "claude-code", "name": "white"})).unwrap();
        assert_eq!((f.world.joins.load(Ordering::SeqCst), f.world.opened.lock().unwrap().len()), (1, 2));
    }

    #[test]
    fn a_taken_agent_name_gets_a_free_one_and_the_request_is_remembered() {
        let f = fx(all_powers());
        let r = call(&f, "agents.spawn", json!({"type": "claude-code", "name": "lead"})).unwrap();
        assert_eq!((r["name"].as_str().unwrap(), r["requested"].as_str().unwrap()), ("lead-2", "lead"));
        assert_eq!(f.world.members.lock().unwrap().iter().find(|m| m.name == "lead").unwrap().types, ["claude-code"], "the seat is untouched");
    }

    #[test]
    fn a_failed_terminal_leaves_the_member_and_a_retry_resumes() {
        let f = fx(all_powers());
        *f.world.fail_open.lock().unwrap() = true;
        let e = call(&f, "agents.spawn", json!({"type": "claude-code", "name": "black"})).unwrap_err();
        assert_eq!(e.code, "not_available");
        assert!(e.message.contains("black"), "{}", e.message);
        assert!(f.world.members.lock().unwrap().iter().any(|m| m.name == "black"));
        *f.world.fail_open.lock().unwrap() = false;
        let r = call(&f, "agents.spawn", json!({"type": "claude-code", "name": "black"})).unwrap();
        assert_eq!(r["state"], "running");
        assert_eq!(f.world.joins.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_folder_comes_only_from_inside_the_granted_one() {
        let f = fx(all_powers());
        let r = call(&f, "agents.spawn", json!({"type": "claude-code", "name": "w", "folder": "sub"})).unwrap();
        assert_eq!(r["state"], "running");
        let ms = f.world.members.lock().unwrap();
        assert_eq!(ms.iter().find(|m| m.name == "w").unwrap().project, f.granted.join("sub").to_string_lossy());
        drop(ms);
        std::fs::write(f.granted.join("file.txt"), "x").unwrap();
        for folder in ["file.txt", "/etc", "C:/Windows", "sub/..", "a\\b"] {
            let c = code(call(&f, "agents.spawn", json!({"type": "claude-code", "name": "z", "folder": folder})));
            assert!(matches!(c, "bad_args" | "not_found"), "{folder}: {c}");
        }
        assert!(f.mgr.entries_for("o/chess", "id-t").iter().all(|e| e.name != "z"));
    }

    #[cfg(unix)]
    #[test]
    fn a_link_out_of_the_granted_folder_or_the_default_one_is_refused() {
        let f = fx(all_powers());
        let outside = f._tmp.path().join("outside");
        std::fs::create_dir_all(&outside).unwrap();
        std::os::unix::fs::symlink(&outside, f.granted.join("out")).unwrap();
        assert_eq!(code(call(&f, "agents.spawn", json!({"type": "claude-code", "name": "z", "folder": "out"}))), "outside_root");
        // the default folder is a link that leaves ~/agmsg-agents
        std::os::unix::fs::symlink(&outside, f.world.home.join("v")).unwrap();
        assert_eq!(code(call(&f, "agents.spawn", json!({"type": "claude-code", "name": "v"}))), "outside_root");
        assert!(f.world.members.lock().unwrap().iter().all(|m| m.name != "v"));
        // a denied folder
        let g = Fx { deny: Denylist::from_process_env(vec![f.granted.join("sub")]), ..fx(all_powers()) };
        let _ = g;
    }

    #[test]
    fn an_outside_join_of_another_type_is_a_conflict_and_nothing_is_adopted() {
        let f = fx(all_powers());
        *f.world.outside.lock().unwrap() = Some(Box::new(|w: &Fake| {
            w.members.lock().unwrap().push(MemberInfo { name: "black".into(), types: vec!["codex".into()], project: "/other".into() });
        }));
        let e = call(&f, "agents.spawn", json!({"type": "claude-code", "name": "black"})).unwrap_err();
        assert_eq!(e.code, "conflict");
        assert!(f.world.opened.lock().unwrap().is_empty());
        let list = call(&f, "agents.list", json!({})).unwrap();
        assert_eq!(list["agents"][0]["state"], "failed");
        // a retry returns the recorded reason, it does not try again
        assert_eq!(code(call(&f, "agents.spawn", json!({"type": "claude-code", "name": "black"}))), "not_available");
        assert_eq!(f.world.joins.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn two_panes_asking_at_once_make_one_member() {
        let f = Arc::new(fx(all_powers()));
        let hs: Vec<_> = (0..4)
            .map(|_| {
                let f = f.clone();
                std::thread::spawn(move || call(&f, "team.join", json!({})).unwrap())
            })
            .collect();
        let rs: Vec<Value> = hs.into_iter().map(|h| h.join().unwrap()).collect();
        assert_eq!(f.world.joins.load(Ordering::SeqCst), 1);
        assert_eq!(rs.iter().filter(|r| r["created"] == true).count(), 1);
        assert!(rs.iter().all(|r| r["name"] == "chess"));
    }

    // ---- recovery -------------------------------------------------------------------

    fn entry(state: State, kind: Kind) -> Entry {
        Entry { key: "k1".into(), addon: "o/chess".into(), team_id: "id-t".into(), team: "t".into(), kind, requested: "w".into(), name: "w".into(), agent_type: "claude-code".into(), project: "/p".into(), claim: "c".into(), model: None, state, pid: None, start: None, reason: None }
    }

    fn with_entries(f: &Fx, es: Vec<Entry>) -> Manager {
        std::fs::write(&f.journal, serde_json::to_vec(&Journal { entries: es }).unwrap()).unwrap();
        let mut m = Manager::new(f.world.clone(), f.journal.clone());
        m.open_wait = std::time::Duration::from_millis(200);
        m
    }

    #[test]
    fn the_journal_survives_a_restart() {
        let f = fx(all_powers());
        call(&f, "agents.spawn", json!({"type": "claude-code", "name": "w"})).unwrap();
        let again = Manager::new(f.world.clone(), f.journal.clone());
        assert_eq!(again.all_entries().len(), 1);
        assert_eq!(again.all_entries()[0].state, State::Running);
    }

    #[test]
    fn recovery_of_a_claimed_member_finds_it_by_its_claim_folder() {
        let f = fx(all_powers());
        let mut e = entry(State::Claimed, Kind::Member);
        e.agent_type = MEMBER_TYPE.into();
        e.requested = String::new();
        // joined before the crash
        f.world.members.lock().unwrap().push(MemberInfo { name: "w".into(), types: vec![MEMBER_TYPE.into()], project: "/p".into() });
        let m = with_entries(&f, vec![e.clone()]);
        m.recover();
        assert_eq!(m.all_entries()[0].state, State::Joined);
        // never joined: dropped
        f.world.members.lock().unwrap().retain(|m| m.name != "w");
        let m = with_entries(&f, vec![e.clone()]);
        m.recover();
        assert!(m.all_entries().is_empty());
        // joined, with another registration beside ours: a conflict, shown
        f.world.members.lock().unwrap().push(MemberInfo { name: "w".into(), types: vec![MEMBER_TYPE.into(), "codex".into()], project: "/p".into() });
        let m = with_entries(&f, vec![e]);
        m.recover();
        assert_eq!(m.all_entries()[0].state, State::Failed);
    }

    #[test]
    fn recovery_of_running_opening_and_orphaned_entries() {
        let f = fx(all_powers());
        f.world.alive.lock().unwrap().insert(77, "start-A".into());
        let mut live = entry(State::Running, Kind::Agent);
        live.key = "live".into();
        live.pid = Some(77);
        live.start = Some("start-A".into());
        let mut reused = entry(State::Running, Kind::Agent);
        reused.key = "reused".into();
        reused.pid = Some(77);
        reused.start = Some("start-OLD".into());
        let mut gone = entry(State::Running, Kind::Agent);
        gone.key = "gone".into();
        gone.pid = Some(78);
        gone.start = Some("start-B".into());
        let mut opening = entry(State::Opening, Kind::Agent);
        opening.key = "opening".into();
        let m = with_entries(&f, vec![live, reused, gone, opening]);
        m.recover();
        let st = |k: &str| m.all_entries().into_iter().find(|e| e.key == k).unwrap().state;
        assert_eq!(st("live"), State::Orphaned, "the agent outlived the app: shown with its pid, not reopened");
        assert_eq!(st("reused"), State::Joined, "the same pid but another process");
        assert_eq!(st("gone"), State::Joined);
        assert_eq!(st("opening"), if OPENING_RECOVERS_TO_JOINED { State::Joined } else { State::Unknown });
        assert_eq!(m.all_entries().iter().find(|e| e.key == "live").unwrap().pid, Some(77));
        // no pane is opened by recovery, and a spawn for an orphaned name returns its state
        assert!(f.world.opened.lock().unwrap().is_empty());
    }

    #[test]
    fn an_orphaned_or_unknown_agent_is_not_reopened_until_the_user_chooses() {
        let f = fx(all_powers());
        f.world.alive.lock().unwrap().insert(77, "s".into());
        let mut e = entry(State::Running, Kind::Agent);
        e.pid = Some(77);
        e.start = Some("s".into());
        let m = with_entries(&f, vec![e]);
        m.recover();
        let f2 = Fx { mgr: Arc::new(m), ..f };
        let r = call(&f2, "agents.spawn", json!({"type": "claude-code", "name": "w"})).unwrap();
        assert_eq!((r["state"].as_str().unwrap(), r["pid"].as_u64().unwrap()), ("orphaned", 77));
        assert!(f2.world.opened.lock().unwrap().is_empty());
        f2.mgr.reopen("k1").unwrap();
        assert_eq!(f2.world.opened.lock().unwrap().len(), 1);
    }

    #[test]
    fn a_revoke_after_the_start_does_not_undo_the_op_and_the_next_one_is_refused() {
        let f = fx(all_powers());
        call(&f, "team.join", json!({})).unwrap();
        f.reg.lock().unwrap().set_power(f.id, Power::Send, false).unwrap();
        assert_eq!(code(call(&f, "messages.send", json!({"to": "lead", "body": "x"}))), "not_granted");
        // a reloaded frame gets no answer
        let old = f.gen;
        f.reg.lock().unwrap().begin_generation(f.id);
        let e = crate::addons::broker::handle_power(&f.reg, &f.deny, &f.mgr, f.id, old, "team.join", &json!({})).unwrap_err();
        assert_eq!(e.code, "not_granted");
    }

    #[test]
    fn the_frame_cannot_name_a_team_for_another_pane() {
        // two panes of two add-ons in two teams: each op lands in its own pane's team and member
        let f = fx(all_powers());
        call(&f, "team.join", json!({"team": "other"})).unwrap();
        assert!(f.mgr.member_of("o/chess", "id-t").is_some());
        assert!(f.mgr.member_of("o/chess", "id-other").is_none());
        assert!(f.mgr.member_of("o/other-addon", "id-t").is_none());
    }

    #[test]
    fn a_team_rename_does_not_orphan_the_entries() {
        let f = fx(all_powers());
        let j = call(&f, "team.join", json!({})).unwrap();
        call(&f, "agents.spawn", json!({"type": "claude-code", "name": "white"})).unwrap();
        // the team is renamed t -> table: same id, new name; the grant follows the pane's team name
        f.world.renamed.lock().unwrap().insert("t".into(), "table".into());
        f.reg.lock().unwrap().grant_team(f.id, "table").unwrap();
        let gen = f.reg.lock().unwrap().generation(f.id).unwrap();
        let again = crate::addons::broker::handle_power(&f.reg, &f.deny, &f.mgr, f.id, gen, "team.join", &json!({})).unwrap();
        assert_eq!((again["name"].as_str().unwrap(), again["created"].as_bool().unwrap()), (j["name"].as_str().unwrap(), false));
        let list = crate::addons::broker::handle_power(&f.reg, &f.deny, &f.mgr, f.id, gen, "agents.list", &json!({})).unwrap();
        assert_eq!(list["agents"].as_array().unwrap().len(), 1);
        assert!(f.mgr.all_entries().iter().all(|e| e.team_id == "id-t" && e.team == "table"), "the name shown follows the rename");
        assert_eq!(f.world.joins.load(Ordering::SeqCst), 2, "no second join, no second agent");
    }

    #[test]
    fn no_entry_stays_opening_after_the_op_returns() {
        // the window says it could not open the pane
        let f = fx(all_powers());
        let m = f.mgr.clone();
        *f.world.on_open.lock().unwrap() = Some(Box::new(move |req: &OpenPane| m.open_failed(&req.key, "a pane named white is already open")));
        let r = call(&f, "agents.spawn", json!({"type": "claude-code", "name": "white"})).unwrap();
        assert_eq!((r["state"].as_str().unwrap(), r["reason"].as_str().unwrap()), ("failed", "a pane named white is already open"));
        // the window never answers
        let g = fx(all_powers());
        *g.world.on_open.lock().unwrap() = None;
        let r = call(&g, "agents.spawn", json!({"type": "claude-code", "name": "black"})).unwrap();
        assert_eq!(r["state"], "failed");
        assert!(r["reason"].as_str().unwrap().contains("did not report"), "{r}");
        assert!(g.mgr.all_entries().iter().all(|e| e.state != State::Opening));
        // the user can open a failed agent again from the settings
        *g.world.on_open.lock().unwrap() = Some(Box::new({
            let m = g.mgr.clone();
            move |req: &OpenPane| {
                let (m, key) = (m.clone(), req.key.clone());
                std::thread::spawn(move || m.pty_started(&key, 99));
            }
        }));
        let key = g.mgr.all_entries()[0].key.clone();
        assert_eq!(g.mgr.reopen(&key).unwrap()["state"], "running");
    }
}
