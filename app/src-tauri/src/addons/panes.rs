//! Open add-on panes: one record per pane instance, with its server, what the
//! add-on declared and what the user has allowed so far.
//!
//! Rust holds the grants and decides; the UI only relays. Every request and
//! every push is checked against the record of the pane instance and the
//! *generation* of its frame (bumped on each iframe load), so a reloaded,
//! closed or revoked pane can never be answered. The identity of a request is
//! taken from the port it arrived on in the UI, never from the request args.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use super::csp::Network;
use super::server::{PaneServer, PaneSpec, Payload, StartError};

pub type PaneId = u64;

/// Stable codes the add-on sees (`ErrorCode` in `addon-kit/protocol.d.ts`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BrokerError {
    pub code: &'static str,
    pub message: String,
}

impl BrokerError {
    pub fn new(code: &'static str, message: impl Into<String>) -> BrokerError {
        BrokerError { code, message: message.into() }
    }
}

/// What `addon.conf` declared.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Declared {
    pub messages_read: bool,
    pub files_read: bool,
    pub git_read: bool,
    #[serde(skip)]
    pub network: Option<Network>,
}

/// What the pane was opened with (only values the user approved).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct OpenArgs {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
}

/// What the broker may do for a request, in the order the checks run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Need {
    /// Only that the pane instance and generation are current (`open.args`).
    Current,
    Files,
    /// `git:read` plus `files:read` on the repo root.
    FilesAndGit,
    Messages,
}

pub struct Pane {
    pub id: PaneId,
    /// `owner/repo` or a built-in name.
    pub addon: String,
    pub commit: String,
    pub name: String,
    pub declared: Declared,
    pub open_args: OpenArgs,
    pub generation: u64,
    /// The one team this pane may read (granted at first open per team).
    pub team: Option<String>,
    /// The real path of the one folder this pane may read.
    pub root: Option<PathBuf>,
    pub server: PaneServer,
    pub inflight: Arc<AtomicUsize>,
}

/// What a broker op needs after authorization, copied out so the registry is
/// not locked during file I/O.
#[derive(Debug, Clone)]
pub struct Authorized {
    pub id: PaneId,
    pub generation: u64,
    pub root: Option<PathBuf>,
    pub team: Option<String>,
    pub open_args: OpenArgs,
    pub inflight: Arc<AtomicUsize>,
}

pub struct AddPane {
    pub addon: String,
    pub commit: String,
    pub name: String,
    pub payload: Payload,
    pub entry: String,
    pub declared: Declared,
    pub open_args: OpenArgs,
    pub expected_digest: Option<String>,
    pub pinned: Option<std::collections::BTreeMap<String, (String, u64)>>,
    pub on_tamper: Option<super::server::TamperFn>,
}

#[derive(Default)]
pub struct Registry {
    next: PaneId,
    panes: HashMap<PaneId, Pane>,
}

pub struct Added {
    pub id: PaneId,
    pub url: String,
    pub port: u16,
    pub token: String,
}

/// A request in flight; dropped when the op finishes.
pub struct Slot(Arc<AtomicUsize>);

impl Drop for Slot {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Per pane: at most this many requests queued or running.
pub const MAX_INFLIGHT: usize = 64;

impl Registry {
    pub fn new() -> Registry {
        Registry { next: 1, panes: HashMap::new() }
    }

    pub fn add(&mut self, spec: AddPane) -> Result<Added, StartError> {
        let network = spec.declared.network.clone().unwrap_or(Network::None);
        let server = PaneServer::start(PaneSpec { payload: spec.payload, entry: spec.entry, network, expected_digest: spec.expected_digest, pinned: spec.pinned, on_tamper: spec.on_tamper })?;
        let id = self.next;
        self.next += 1;
        let added = Added { id, url: server.url(), port: server.port(), token: server.token().to_string() };
        self.panes.insert(
            id,
            Pane {
                id,
                addon: spec.addon,
                commit: spec.commit,
                name: spec.name,
                declared: spec.declared,
                open_args: spec.open_args,
                generation: 0,
                team: None,
                root: None,
                server,
                inflight: Arc::new(AtomicUsize::new(0)),
            },
        );
        Ok(added)
    }

    /// Closes the pane that listens on `port` with exactly this `token` (a pinned
    /// file changed). A late notice for a pane that is already gone, whose port
    /// was reused by another pane, matches nothing and closes nothing.
    pub fn remove_matching(&mut self, port: u16, token: &str) -> Option<(PaneId, u16, String)> {
        let id = self.panes.values().find(|p| p.server.port() == port && p.server.token() == token).map(|p| p.id)?;
        let (port, token) = self.remove(id)?;
        Some((id, port, token))
    }

    /// Closes the pane: the listener and token are dropped with the server.
    pub fn remove(&mut self, id: PaneId) -> Option<(u16, String)> {
        self.panes.remove(&id).map(|p| (p.server.port(), p.server.token().to_string()))
    }

    /// Every open pane of an add-on (`owner/repo`, `builtin:x` or `dev:x`).
    pub fn ids_for_addon(&self, addon: &str) -> Vec<PaneId> {
        let mut v: Vec<_> = self.panes.values().filter(|p| p.addon == addon).map(|p| p.id).collect();
        v.sort();
        v
    }

    pub fn contains(&self, id: PaneId) -> bool {
        self.panes.contains_key(&id)
    }

    pub fn ids(&self) -> Vec<PaneId> {
        let mut v: Vec<_> = self.panes.keys().copied().collect();
        v.sort();
        v
    }

    /// The iframe loaded again (first load, reload, update): everything the
    /// previous frame held is void. Returns the new generation.
    pub fn begin_generation(&mut self, id: PaneId) -> Option<u64> {
        let p = self.panes.get_mut(&id)?;
        p.generation += 1;
        Some(p.generation)
    }

    pub fn generation(&self, id: PaneId) -> Option<u64> {
        self.panes.get(&id).map(|p| p.generation)
    }

    /// The user allowed this pane to read `team`. Only declared permissions can be granted.
    pub fn grant_team(&mut self, id: PaneId, team: &str) -> Result<(), BrokerError> {
        let p = self.panes.get_mut(&id).ok_or_else(gone)?;
        if !p.declared.messages_read {
            return Err(BrokerError::new("not_declared", "this add-on did not declare messages:read"));
        }
        // Changing an existing scope (team A -> B) voids the frame exactly like a
        // revoke: whatever was authorized under A can no longer be answered under B.
        if p.team.as_deref().is_some_and(|old| old != team) {
            p.generation += 1;
        }
        p.team = Some(team.to_string());
        Ok(())
    }

    pub fn revoke_team(&mut self, id: PaneId) {
        if let Some(p) = self.panes.get_mut(&id) {
            p.team = None;
            // a revoked frame is torn down by the caller; the generation bump
            // makes any answer still on its way a stale one
            p.generation += 1;
        }
    }

    /// The user allowed this pane to read under `root` (already resolved to a
    /// real path and checked against the denylist by the caller).
    pub fn grant_root(&mut self, id: PaneId, root: PathBuf) -> Result<(), BrokerError> {
        let p = self.panes.get_mut(&id).ok_or_else(gone)?;
        if !p.declared.files_read {
            return Err(BrokerError::new("not_declared", "this add-on did not declare files:read"));
        }
        if p.root.as_ref().is_some_and(|old| old != &root) {
            p.generation += 1;
        }
        p.root = Some(root);
        Ok(())
    }

    pub fn revoke_root(&mut self, id: PaneId) {
        if let Some(p) = self.panes.get_mut(&id) {
            p.root = None;
            p.generation += 1;
        }
    }

    /// Order: pane and generation current → declared → granted. Nothing about
    /// the request's own arguments is trusted here.
    pub fn authorize(&self, id: PaneId, generation: u64, need: Need) -> Result<Authorized, BrokerError> {
        let p = self.panes.get(&id).ok_or_else(gone)?;
        if p.generation != generation || generation == 0 {
            return Err(BrokerError::new("not_granted", "this frame is not the pane's current one (it was reloaded or closed)"));
        }
        match need {
            Need::Current => {}
            Need::Messages => {
                if !p.declared.messages_read {
                    return Err(BrokerError::new("not_declared", "this add-on did not declare messages:read"));
                }
                if p.team.is_none() {
                    return Err(BrokerError::new("not_granted", "no team is allowed for this pane"));
                }
            }
            Need::Files | Need::FilesAndGit => {
                if need == Need::FilesAndGit && !p.declared.git_read {
                    return Err(BrokerError::new("not_declared", "this add-on did not declare git:read"));
                }
                if !p.declared.files_read {
                    return Err(BrokerError::new("not_declared", "this add-on did not declare files:read"));
                }
                if p.root.is_none() {
                    return Err(BrokerError::new("not_granted", "no folder is allowed for this pane"));
                }
            }
        }
        Ok(Authorized { id, generation, root: p.root.clone(), team: p.team.clone(), open_args: p.open_args.clone(), inflight: p.inflight.clone() })
    }

    /// Reserves a request slot for the pane; `None` when 64 are already queued.
    pub fn slot(&self, id: PaneId) -> Option<Slot> {
        let p = self.panes.get(&id)?;
        if p.inflight.fetch_add(1, Ordering::SeqCst) >= MAX_INFLIGHT {
            p.inflight.fetch_sub(1, Ordering::SeqCst);
            return None;
        }
        Some(Slot(p.inflight.clone()))
    }

    /// Panes that may be sent messages of `team` right now, with their generation.
    pub fn panes_reading_team(&self, team: &str) -> Vec<(PaneId, u64)> {
        let mut v: Vec<_> = self
            .panes
            .values()
            .filter(|p| p.declared.messages_read && p.team.as_deref() == Some(team) && p.generation > 0)
            .map(|p| (p.id, p.generation))
            .collect();
        v.sort();
        v
    }
}

fn gone() -> BrokerError {
    BrokerError::new("not_granted", "this pane is closed")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn reg_with(declared: Declared) -> (Registry, PaneId) {
        let mut r = Registry::new();
        let mut files = HashMap::new();
        files.insert("index.html".to_string(), b"<div></div>".to_vec());
        let a = r
            .add(AddPane {
                addon: "o/r".into(),
                commit: "c".into(),
                name: "n".into(),
                payload: Payload::Embedded(files),
                entry: "index.html".into(),
                declared,
                open_args: OpenArgs::default(),
                expected_digest: None,
                pinned: None,
                on_tamper: None,
            })
            .unwrap();
        (r, a.id)
    }

    fn all() -> Declared {
        Declared { messages_read: true, files_read: true, git_read: true, network: None }
    }

    #[test]
    fn generation_zero_and_stale_generations_are_refused() {
        let (mut r, id) = reg_with(all());
        assert!(r.authorize(id, 0, Need::Current).is_err(), "no frame has loaded yet");
        let g1 = r.begin_generation(id).unwrap();
        assert!(r.authorize(id, g1, Need::Current).is_ok());
        let g2 = r.begin_generation(id).unwrap();
        assert_eq!(r.authorize(id, g1, Need::Current).unwrap_err().code, "not_granted");
        assert!(r.authorize(id, g2, Need::Current).is_ok());
        assert!(r.authorize(id, g2 + 1, Need::Current).is_err(), "a future generation is not valid either");
    }

    #[test]
    fn undeclared_is_checked_before_granted() {
        let (mut r, id) = reg_with(Declared::default());
        let g = r.begin_generation(id).unwrap();
        for need in [Need::Files, Need::FilesAndGit, Need::Messages] {
            assert_eq!(r.authorize(id, g, need).unwrap_err().code, "not_declared", "{need:?}");
        }
        assert_eq!(r.grant_team(id, "t").unwrap_err().code, "not_declared");
        assert_eq!(r.grant_root(id, PathBuf::from("/x")).unwrap_err().code, "not_declared");
    }

    #[test]
    fn declared_but_not_granted_is_not_granted() {
        let (mut r, id) = reg_with(all());
        let g = r.begin_generation(id).unwrap();
        for need in [Need::Files, Need::FilesAndGit, Need::Messages] {
            assert_eq!(r.authorize(id, g, need).unwrap_err().code, "not_granted", "{need:?}");
        }
        r.grant_team(id, "t").unwrap();
        r.grant_root(id, PathBuf::from("/x")).unwrap();
        for need in [Need::Files, Need::FilesAndGit, Need::Messages] {
            assert!(r.authorize(id, g, need).is_ok(), "{need:?}");
        }
    }

    #[test]
    fn git_needs_its_own_declaration_even_with_files() {
        let (mut r, id) = reg_with(Declared { files_read: true, ..Default::default() });
        let g = r.begin_generation(id).unwrap();
        r.grant_root(id, PathBuf::from("/x")).unwrap();
        assert!(r.authorize(id, g, Need::Files).is_ok());
        assert_eq!(r.authorize(id, g, Need::FilesAndGit).unwrap_err().code, "not_declared");
    }

    #[test]
    fn revoking_voids_the_current_generation() {
        let (mut r, id) = reg_with(all());
        let g = r.begin_generation(id).unwrap();
        r.grant_team(id, "t").unwrap();
        r.grant_root(id, PathBuf::from("/x")).unwrap();
        r.revoke_team(id);
        assert!(r.authorize(id, g, Need::Messages).is_err());
        assert!(r.authorize(id, g, Need::Files).is_err(), "the whole frame is stale after a revoke");
        let g2 = r.generation(id).unwrap();
        assert!(g2 > g);
        assert_eq!(r.authorize(id, g2, Need::Messages).unwrap_err().code, "not_granted");
        r.grant_root(id, PathBuf::from("/y")).unwrap();
        let g3 = r.generation(id).unwrap();
        r.revoke_root(id);
        assert!(r.generation(id).unwrap() > g3);
    }

    #[test]
    fn swapping_the_team_or_the_folder_voids_the_authority_it_replaces() {
        let (mut r, id) = reg_with(all());
        let g = r.begin_generation(id).unwrap();
        r.grant_team(id, "team-a").unwrap();
        r.grant_root(id, PathBuf::from("/a")).unwrap();
        assert_eq!(r.generation(id), Some(g), "first grants do not change the frame");
        r.grant_team(id, "team-a").unwrap();
        r.grant_root(id, PathBuf::from("/a")).unwrap();
        assert!(r.authorize(id, g, Need::Messages).is_ok(), "granting the same scope again is a no-op");
        let held = r.authorize(id, g, Need::Messages).unwrap();
        assert_eq!(held.team.as_deref(), Some("team-a"));
        r.grant_team(id, "team-b").unwrap();
        assert!(r.authorize(id, g, Need::Messages).is_err(), "team A authority must not survive the swap to B");
        assert!(r.authorize(id, g, Need::Files).is_err(), "the whole frame is stale after a swap");
        let g2 = r.generation(id).unwrap();
        assert!(g2 > g);
        assert_eq!(r.authorize(id, g2, Need::Messages).unwrap().team.as_deref(), Some("team-b"));
        r.grant_root(id, PathBuf::from("/b")).unwrap();
        assert!(r.authorize(id, g2, Need::Files).is_err(), "root A authority must not survive the swap to B");
        assert!(r.generation(id).unwrap() > g2);
    }

    #[test]
    fn removed_panes_answer_nothing() {
        let (mut r, id) = reg_with(all());
        let g = r.begin_generation(id).unwrap();
        assert!(r.remove(id).is_some());
        assert!(r.authorize(id, g, Need::Current).is_err());
        assert!(r.slot(id).is_none());
        assert!(r.remove(id).is_none());
        assert!(!r.contains(id));
    }

    #[test]
    fn panes_are_independent() {
        let (mut r, a) = reg_with(all());
        let mut files = HashMap::new();
        files.insert("index.html".to_string(), b"x".to_vec());
        let b = r
            .add(AddPane { addon: "o/r".into(), commit: "c".into(), name: "n".into(), payload: Payload::Embedded(files), entry: "index.html".into(), declared: all(), open_args: OpenArgs::default(), expected_digest: None, pinned: None, on_tamper: None })
            .unwrap()
            .id;
        let ga = r.begin_generation(a).unwrap();
        let gb = r.begin_generation(b).unwrap();
        r.grant_team(a, "team-a").unwrap();
        r.grant_team(b, "team-b").unwrap();
        assert_eq!(r.panes_reading_team("team-a"), vec![(a, ga)]);
        assert_eq!(r.panes_reading_team("team-b"), vec![(b, gb)]);
        assert!(r.panes_reading_team("team-c").is_empty());
        r.revoke_team(a);
        assert_eq!(r.panes_reading_team("team-b"), vec![(b, gb)]);
    }

    #[test]
    fn a_late_notice_closes_only_the_pane_with_that_port_and_token() {
        let (mut r, a) = reg_with(all());
        let (port, token) = {
            let p = r.panes.get(&a).unwrap();
            (p.server.port(), p.server.token().to_string())
        };
        // wrong token for a live port: nothing closes
        assert!(r.remove_matching(port, "0".repeat(32).as_str()).is_none());
        assert!(r.contains(a));
        // wrong port with the right token: nothing closes
        assert!(r.remove_matching(port.wrapping_add(1), &token).is_none());
        assert!(r.contains(a));
        // the pane is removed; the same notice arriving late matches nothing, even if the port is reused
        assert_eq!(r.remove_matching(port, &token).map(|x| x.0), Some(a));
        assert!(r.remove_matching(port, &token).is_none());
        assert!(!r.contains(a));
    }

    #[test]
    fn open_panes_are_found_by_add_on() {
        let (mut r, a) = reg_with(all());
        assert_eq!(r.ids_for_addon("o/r"), vec![a]);
        assert!(r.ids_for_addon("x/y").is_empty());
        r.remove(a);
        assert!(r.ids_for_addon("o/r").is_empty());
    }

    #[test]
    fn at_most_64_requests_in_flight() {
        let (r, id) = reg_with(all());
        let mut slots = Vec::new();
        for _ in 0..MAX_INFLIGHT {
            slots.push(r.slot(id).expect("slot"));
        }
        assert!(r.slot(id).is_none());
        slots.pop();
        assert!(r.slot(id).is_some());
    }

    #[test]
    fn a_pane_with_no_generation_is_not_pushed_to() {
        let (mut r, id) = reg_with(all());
        r.grant_team(id, "t").unwrap();
        assert!(r.panes_reading_team("t").is_empty(), "no frame has loaded");
    }
}
