//! What an add-on may learn about the agents open in its team: each agent pane's member name, type and state.
//!
//! The window reports every actual change of an agent pane's state (the moment the app's own status changes) and
//! the closing of the pane. This board keeps the last known row per pane and per team, so `agents.status` can answer
//! at once, and turns each report into one push for the panes that hold `messages:read` for that team. Nothing but
//! name, type, state and time is kept or sent: no pane id, command, folder or terminal text.

use serde_json::{json, Value};
use std::collections::HashMap;

use super::panes::{Need, PaneId, Registry};

/// The states the app itself tells apart (`RawState` in the window), plus `closed` for a pane that went away.
const STATES: [&str; 4] = ["idle", "working", "blocked", "unknown"];
pub const CLOSED: &str = "closed";
/// Longest member name or type the window may report; the window sends real names, never these.
const MAX_TEXT_LEN: usize = 100;
/// Most agent panes kept per team. A window never has this many; the cap bounds a misbehaving report.
const MAX_ROWS_PER_TEAM: usize = 256;

#[derive(Clone, Debug, PartialEq)]
struct Row {
    name: String,
    kind: String,
    state: String,
    since: u64,
}

/// Last known state of the open agent panes, per team (team name -> pane key -> row). The pane key is the
/// window's own and is never sent to an add-on.
#[derive(Default)]
pub struct StatusBoard {
    teams: HashMap<String, HashMap<String, Row>>,
}

fn text_ok(s: &str) -> bool {
    !s.is_empty() && s.len() <= MAX_TEXT_LEN
}

impl StatusBoard {
    /// Takes one report from the window. Returns the event to push when it changed something an add-on can see:
    /// a new pane, a different state, or a pane that closed. A repeat of what is already held, a closing for a pane
    /// that was never held, and a malformed report return `None`.
    pub fn report(&mut self, team: &str, pane: &str, name: &str, kind: &str, state: &str, at: u64) -> Option<Value> {
        if !text_ok(team) || !text_ok(pane) || !text_ok(name) || !text_ok(kind) {
            return None;
        }
        if state == CLOSED {
            let rows = self.teams.get_mut(team)?;
            let gone = rows.remove(pane)?;
            if rows.is_empty() {
                self.teams.remove(team);
            }
            return Some(event(&gone.name, CLOSED, at));
        }
        if !STATES.contains(&state) {
            return None;
        }
        let rows = self.teams.entry(team.to_string()).or_default();
        match rows.get(pane) {
            Some(row) if row.state == state => return None,
            None if rows.len() >= MAX_ROWS_PER_TEAM => return None,
            _ => {}
        }
        rows.insert(pane.to_string(), Row { name: name.to_string(), kind: kind.to_string(), state: state.to_string(), since: at });
        Some(event(name, state, at))
    }

    /// The `agents.status` answer for one team: the agent panes open there, by member name.
    pub fn snapshot(&self, team: &str) -> Value {
        let mut rows: Vec<&Row> = self.teams.get(team).map(|r| r.values().collect()).unwrap_or_default();
        rows.sort_by(|a, b| a.name.cmp(&b.name).then(a.since.cmp(&b.since)));
        json!({ "agents": rows.iter().map(|r| json!({ "name": r.name, "type": r.kind, "state": r.state, "since": r.since })).collect::<Vec<_>>() })
    }
}

/// The push for one change: the member, its new state and when. No text, no ids.
pub fn event(name: &str, state: &str, at: u64) -> Value {
    json!({ "agmsg": 1, "type": "status", "name": name, "state": state, "at": at })
}

/// The panes to tell about `event` for `team`: those that read that team's messages right now, with their
/// generation. Any other add-on, any other team, and a pane that was never granted the team get nothing.
pub fn pushes(registry: &Registry, team: &str, event: &Value) -> Vec<(PaneId, u64, Value)> {
    registry
        .panes_reading_team(team)
        .into_iter()
        .filter(|(pane, generation)| registry.authorize(*pane, *generation, Need::Messages).is_ok())
        .map(|(pane, generation)| (pane, generation, event.clone()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::addons::panes::{AddPane, Declared, OpenArgs};
    use crate::addons::server::Payload;
    use std::collections::HashMap;

    fn reading_pane(r: &mut Registry, addon: &str, team: Option<&str>) -> (PaneId, u64) {
        let mut files = HashMap::new();
        files.insert("index.html".to_string(), b"<div></div>".to_vec());
        let id = r
            .add(AddPane {
                addon: addon.into(),
                commit: "c".into(),
                name: "n".into(),
                payload: Payload::Embedded(files),
                entry: "index.html".into(),
                declared: Declared { messages_read: true, ..Default::default() },
                open_args: OpenArgs::default(),
                expected_digest: None,
                pinned: None,
                on_tamper: None,
            })
            .unwrap()
            .id;
        let g = r.begin_generation(id).unwrap();
        if let Some(t) = team {
            r.grant_team(id, t).unwrap();
        }
        (id, g)
    }

    #[test]
    fn a_state_change_is_one_event_and_a_repeat_is_none() {
        let mut b = StatusBoard::default();
        let first = b.report("t", "p1", "white", "claude-code", "idle", 10).unwrap();
        assert_eq!(first, json!({ "agmsg": 1, "type": "status", "name": "white", "state": "idle", "at": 10 }));
        assert!(b.report("t", "p1", "white", "claude-code", "idle", 11).is_none(), "the same state again is not a change");
        let next = b.report("t", "p1", "white", "claude-code", "working", 20).unwrap();
        assert_eq!(next["state"], "working");
        assert_eq!(next["at"], 20);
    }

    #[test]
    fn the_snapshot_lists_the_open_agent_panes_of_that_team_only() {
        let mut b = StatusBoard::default();
        b.report("t", "p1", "white", "claude-code", "idle", 10);
        b.report("t", "p2", "black", "codex", "working", 12);
        b.report("u", "p3", "other", "codex", "blocked", 13);
        assert_eq!(
            b.snapshot("t"),
            json!({ "agents": [
                { "name": "black", "type": "codex", "state": "working", "since": 12 },
                { "name": "white", "type": "claude-code", "state": "idle", "since": 10 },
            ] })
        );
        assert_eq!(b.snapshot("u")["agents"].as_array().unwrap().len(), 1);
        assert_eq!(b.snapshot("none"), json!({ "agents": [] }));
    }

    #[test]
    fn since_moves_only_when_the_state_changes() {
        let mut b = StatusBoard::default();
        b.report("t", "p1", "white", "claude-code", "idle", 10);
        b.report("t", "p1", "white", "claude-code", "idle", 99);
        assert_eq!(b.snapshot("t")["agents"][0]["since"], 10);
        b.report("t", "p1", "white", "claude-code", "working", 30);
        assert_eq!(b.snapshot("t")["agents"][0]["since"], 30);
    }

    #[test]
    fn a_closed_pane_is_one_closed_event_and_leaves_the_snapshot() {
        let mut b = StatusBoard::default();
        b.report("t", "p1", "white", "claude-code", "working", 10);
        let gone = b.report("t", "p1", "white", "claude-code", CLOSED, 40).unwrap();
        assert_eq!(gone, json!({ "agmsg": 1, "type": "status", "name": "white", "state": "closed", "at": 40 }));
        assert_eq!(b.snapshot("t"), json!({ "agents": [] }));
        assert!(b.report("t", "p1", "white", "claude-code", CLOSED, 41).is_none(), "a second closing says nothing");
        assert!(b.report("t", "never", "x", "codex", CLOSED, 42).is_none(), "nor does a pane that was never held");
    }

    #[test]
    fn a_malformed_report_changes_nothing() {
        let mut b = StatusBoard::default();
        assert!(b.report("", "p", "white", "claude-code", "idle", 1).is_none());
        assert!(b.report("t", "", "white", "claude-code", "idle", 1).is_none());
        assert!(b.report("t", "p", "", "claude-code", "idle", 1).is_none());
        assert!(b.report("t", "p", "white", "", "idle", 1).is_none());
        assert!(b.report("t", "p", &"x".repeat(MAX_TEXT_LEN + 1), "claude-code", "idle", 1).is_none());
        assert!(b.report("t", "p", "white", "claude-code", "sleeping", 1).is_none(), "a state the app does not have");
        assert_eq!(b.snapshot("t"), json!({ "agents": [] }));
    }

    #[test]
    fn the_rows_of_one_team_are_capped() {
        let mut b = StatusBoard::default();
        for i in 0..MAX_ROWS_PER_TEAM {
            assert!(b.report("t", &format!("p{i}"), &format!("a{i}"), "codex", "idle", 1).is_some());
        }
        assert!(b.report("t", "extra", "extra", "codex", "idle", 1).is_none());
        assert!(b.report("t", "p0", "a0", "codex", "working", 2).is_some(), "a pane already held can still change");
    }

    #[test]
    fn an_event_carries_no_pane_command_folder_or_text() {
        let mut b = StatusBoard::default();
        let e = b.report("t", "pane-secret-7", "white", "claude-code", "idle", 10).unwrap();
        let s = e.to_string();
        assert!(!s.contains("pane-secret-7") && !s.contains("pane") && !s.contains("cwd") && !s.contains("cmd"), "{s}");
        let snap = b.snapshot("t").to_string();
        assert!(!snap.contains("pane-secret-7"), "{snap}");
    }

    #[test]
    fn only_panes_that_read_that_team_are_told() {
        let mut r = Registry::new();
        let (mine, g) = reading_pane(&mut r, "o/r", Some("t"));
        let (_other_team, _) = reading_pane(&mut r, "o/r", Some("u"));
        let (_no_team, _) = reading_pane(&mut r, "x/y", None);
        let (also_mine, g2) = reading_pane(&mut r, "x/y", Some("t"));
        let e = event("white", "idle", 1);
        let out = pushes(&r, "t", &e);
        let got: Vec<_> = out.iter().map(|(p, gen, _)| (*p, *gen)).collect();
        assert_eq!(got, vec![(mine, g), (also_mine, g2)], "any add-on that reads team t, and nobody else");
        assert!(out.iter().all(|(_, _, ev)| *ev == e));
        assert!(pushes(&r, "none", &e).is_empty());
    }

    #[test]
    fn a_pane_that_lost_the_team_is_no_longer_told() {
        let mut r = Registry::new();
        let (id, _) = reading_pane(&mut r, "o/r", Some("t"));
        assert_eq!(pushes(&r, "t", &event("w", "idle", 1)).len(), 1);
        r.revoke_team(id);
        assert!(pushes(&r, "t", &event("w", "idle", 1)).is_empty(), "a revoked messages:read stops the events");
    }
}
