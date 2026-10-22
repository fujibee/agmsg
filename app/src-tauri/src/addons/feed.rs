//! The message feed of a pane (design 4.2): which messages a pane gets, and how
//! many. Rust filters to the granted team; the UI only forwards over the port.
//!
//! Caps: `init` carries at most 500 messages and 4 MB, newest kept; a live
//! message over 256 KB is truncated with `truncated: true`. Live messages that
//! arrive while `init` is being built are queued and de-duplicated by id.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;

pub const INIT_MAX_MESSAGES: usize = 500;
pub const INIT_MAX_BYTES: usize = 4 * 1024 * 1024;
pub const BODY_MAX_BYTES: usize = 256 * 1024;

/// A message in protocol v1 shape (`Message` in `addon-kit/protocol.d.ts`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedMessage {
    pub id: String,
    pub team: String,
    pub from: String,
    pub to: String,
    pub body: String,
    pub created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub truncated: Option<bool>,
}

/// Cuts the body at 256 KB (on a character boundary) and marks it.
pub fn cap_body(mut m: FeedMessage) -> FeedMessage {
    if m.body.len() > BODY_MAX_BYTES {
        let mut cut = BODY_MAX_BYTES;
        while !m.body.is_char_boundary(cut) {
            cut -= 1;
        }
        m.body.truncate(cut);
        m.truncated = Some(true);
    }
    m
}

/// The team's member list alone does not fit the 4 MB init cap.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InitTooLarge {
    pub measured: usize,
    pub cap: usize,
}

impl InitTooLarge {
    /// The plain reason the pane's failure card shows.
    pub fn message(&self) -> String {
        format!("This team's member list is too large to send to an add-on ({} bytes, limit {}).", self.measured, self.cap)
    }
}

/// The `init` event: `messages` are oldest-first; messages of other teams are
/// dropped; the newest that fit the count and the byte cap are kept, in order.
/// The byte cap is measured on the JSON that is actually sent (escaping
/// included), for the whole event: envelope, members and every message.
/// Returns the JSON event and the ids it contains.
pub fn build_init(team: &str, members: &[(String, String)], messages: Vec<FeedMessage>) -> Result<(Value, HashSet<String>), InitTooLarge> {
    let members_json: Vec<Value> = members.iter().map(|(name, ty)| json!({ "name": name, "type": ty })).collect();
    let envelope = json!({ "agmsg": 1, "type": "init", "team": team, "members": members_json, "messages": [] });
    let mut bytes = serde_json::to_string(&envelope).map(|s| s.len()).unwrap_or(usize::MAX);
    // Members are never cut silently: if the envelope alone is over the cap the
    // pane fails closed with a named error the failure card can explain.
    if bytes > INIT_MAX_BYTES {
        return Err(InitTooLarge { measured: bytes, cap: INIT_MAX_BYTES });
    }
    let mut kept: Vec<FeedMessage> = Vec::new();
    for m in messages.into_iter().rev().filter(|m| m.team == team) {
        let m = cap_body(m);
        // +1 for the comma between array items
        let w = serde_json::to_string(&m).map(|s| s.len() + 1).unwrap_or(usize::MAX);
        if kept.len() >= INIT_MAX_MESSAGES || bytes.saturating_add(w) > INIT_MAX_BYTES {
            break;
        }
        bytes += w;
        kept.push(m);
    }
    kept.reverse();
    let ids: HashSet<String> = kept.iter().map(|m| m.id.clone()).collect();
    Ok((json!({ "agmsg": 1, "type": "init", "team": team, "members": members_json, "messages": kept }), ids))
}

/// Wraps one live message in the protocol event.
pub fn message_event(m: &FeedMessage) -> Value {
    json!({ "agmsg": 1, "type": "message", "message": m })
}

/// Per pane and frame generation, pinned to the team it was started for: a
/// message of any other team never enters its queue, whatever the caller passes.
#[derive(Debug)]
pub enum Feed {
    /// `init` is being built: live messages wait here.
    Buffering { team: String, queue: Vec<FeedMessage> },
    Live { team: String, seen: HashSet<String> },
}

impl Feed {
    pub fn begin(team: &str) -> Feed {
        Feed::Buffering { team: team.to_string(), queue: Vec::new() }
    }

    pub fn team(&self) -> &str {
        match self {
            Feed::Buffering { team, .. } | Feed::Live { team, .. } => team,
        }
    }

    /// A live message. Returns what to push now (nothing while buffering,
    /// nothing for a duplicate or for another team).
    pub fn on_live(&mut self, m: FeedMessage) -> Option<FeedMessage> {
        if m.team != self.team() {
            return None;
        }
        match self {
            Feed::Buffering { queue, .. } => {
                if !queue.iter().any(|x| x.id == m.id) {
                    queue.push(m);
                }
                None
            }
            Feed::Live { seen, .. } => {
                if seen.insert(m.id.clone()) {
                    Some(cap_body(m))
                } else {
                    None
                }
            }
        }
    }

    /// `init` was built with `ids`; the queued messages that are not in it are
    /// returned (to be pushed right after `init`), and the feed goes live.
    pub fn finish(&mut self, mut ids: HashSet<String>) -> Vec<FeedMessage> {
        let team = self.team().to_string();
        let queue = match std::mem::replace(self, Feed::Live { team: team.clone(), seen: HashSet::new() }) {
            Feed::Buffering { queue, .. } => queue,
            Feed::Live { seen, .. } => {
                *self = Feed::Live { team, seen };
                return Vec::new();
            }
        };
        let mut out = Vec::new();
        for m in queue {
            if ids.insert(m.id.clone()) {
                out.push(cap_body(m));
            }
        }
        *self = Feed::Live { team, seen: ids };
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn m(id: &str, team: &str, body: &str) -> FeedMessage {
        FeedMessage { id: id.into(), team: team.into(), from: "a".into(), to: "b".into(), body: body.into(), created_at: "2026-10-22T00:00:00Z".into(), truncated: None }
    }

    fn ids(v: &Value) -> Vec<String> {
        v["messages"].as_array().unwrap().iter().map(|x| x["id"].as_str().unwrap().to_string()).collect()
    }

    #[test]
    fn init_has_the_protocol_shape() {
        let (ev, seen) = build_init("t", &[("alice".into(), "claude-code".into())], vec![m("1", "t", "hi")]).unwrap();
        assert_eq!(ev["agmsg"], 1);
        assert_eq!(ev["type"], "init");
        assert_eq!(ev["team"], "t");
        assert_eq!(ev["members"][0], json!({"name": "alice", "type": "claude-code"}));
        assert_eq!(ev["messages"][0]["body"], "hi");
        assert!(ev["messages"][0].get("truncated").is_none());
        assert!(seen.contains("1"));
    }

    #[test]
    fn init_keeps_the_newest_500_in_order() {
        let all: Vec<_> = (0..700).map(|i| m(&i.to_string(), "t", "x")).collect();
        let (ev, seen) = build_init("t", &[], all).unwrap();
        let got = ids(&ev);
        assert_eq!(got.len(), INIT_MAX_MESSAGES);
        assert_eq!(got.first().unwrap(), "200");
        assert_eq!(got.last().unwrap(), "699");
        assert_eq!(seen.len(), 500);
    }

    #[test]
    fn init_never_includes_other_teams() {
        let (ev, _) = build_init("t", &[], vec![m("1", "t", "a"), m("2", "other", "SECRET"), m("3", "t", "b")]).unwrap();
        assert_eq!(ids(&ev), vec!["1", "3"]);
        assert!(!ev.to_string().contains("SECRET"));
    }

    #[test]
    fn init_is_cut_at_4mb_keeping_the_newest() {
        let body = "x".repeat(200 * 1024);
        let all: Vec<_> = (0..40).map(|i| m(&i.to_string(), "t", &body)).collect();
        let (ev, _) = build_init("t", &[], all).unwrap();
        let got = ids(&ev);
        assert!(got.len() < 40 && got.len() >= 19, "{}", got.len());
        assert_eq!(got.last().unwrap(), "39");
        assert!(ev.to_string().len() <= INIT_MAX_BYTES + 64 * 1024);
    }

    #[test]
    fn a_huge_body_is_truncated_on_a_char_boundary_and_marked() {
        let body = "あ".repeat(BODY_MAX_BYTES); // 3 bytes each
        let c = cap_body(m("1", "t", &body));
        assert!(c.body.len() <= BODY_MAX_BYTES);
        assert!(c.body.is_char_boundary(c.body.len()));
        assert_eq!(c.truncated, Some(true));
        let small = cap_body(m("2", "t", "ok"));
        assert_eq!(small.truncated, None);
        let at = cap_body(m("3", "t", &"y".repeat(BODY_MAX_BYTES)));
        assert_eq!(at.truncated, None, "exactly at the cap is not truncated");
        let (ev, _) = build_init("t", &[], vec![m("4", "t", &"z".repeat(BODY_MAX_BYTES + 5))]).unwrap();
        assert_eq!(ev["messages"][0]["truncated"], true);
    }

    #[test]
    fn live_messages_wait_during_init_and_are_deduplicated() {
        let mut f = Feed::begin("t");
        assert!(f.on_live(m("5", "t", "during")).is_none());
        assert!(f.on_live(m("5", "t", "during again")).is_none(), "queued once");
        assert!(f.on_live(m("6", "t", "during too")).is_none());
        assert!(f.on_live(m("7", "other", "no")).is_none());
        // init already contains 5
        let ids: HashSet<String> = ["1", "2", "5"].iter().map(|s| s.to_string()).collect();
        let queued = f.finish(ids);
        assert_eq!(queued.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), vec!["6"]);
        assert!(f.on_live(m("6", "t", "again")).is_none(), "already delivered");
        assert!(f.on_live(m("5", "t", "again")).is_none(), "already in init");
        assert_eq!(f.on_live(m("8", "t", "new")).unwrap().id, "8");
        assert!(f.on_live(m("8", "t", "dup")).is_none());
        assert!(f.on_live(m("9", "other", "x")).is_none(), "wrong team never passes");
    }

    #[test]
    fn live_bodies_are_capped() {
        let mut f = Feed::Live { team: "t".into(), seen: HashSet::new() };
        let out = f.on_live(m("1", "t", &"q".repeat(BODY_MAX_BYTES + 1))).unwrap();
        assert_eq!(out.truncated, Some(true));
        assert_eq!(out.body.len(), BODY_MAX_BYTES);
    }

    #[test]
    fn finish_twice_keeps_the_feed_live() {
        let mut f = Feed::begin("t");
        f.finish(HashSet::new());
        assert!(f.finish(HashSet::new()).is_empty());
        assert!(matches!(f, Feed::Live { .. }));
    }

    #[test]
    fn a_feed_started_for_one_team_never_queues_another() {
        let mut f = Feed::begin("team-a");
        assert!(f.on_live(m("1", "team-b", "B-SECRET")).is_none());
        assert!(f.on_live(m("2", "team-a", "a")).is_none());
        let queued = f.finish(HashSet::new());
        assert_eq!(queued.iter().map(|x| x.id.as_str()).collect::<Vec<_>>(), vec!["2"]);
        assert!(!format!("{queued:?}").contains("B-SECRET"));
        assert_eq!(f.team(), "team-a");
    }

    #[test]
    fn the_byte_cap_counts_the_json_that_is_sent_not_the_raw_length() {
        // U+0001 is one byte raw and six bytes (\u0001) in JSON
        let body = "\u{1}".repeat(BODY_MAX_BYTES);
        let all: Vec<_> = (0..16).map(|i| m(&i.to_string(), "t", &body)).collect();
        let (ev, _) = build_init("t", &[("alice".into(), "claude-code".into())], all).unwrap();
        let sent = serde_json::to_string(&ev).unwrap().len();
        assert!(sent <= INIT_MAX_BYTES, "sent {sent} bytes, cap {INIT_MAX_BYTES}");
        let n = ev["messages"].as_array().unwrap().len();
        assert!((1..16).contains(&n), "{n}");
        assert_eq!(ev["messages"].as_array().unwrap().last().unwrap()["id"], "15", "newest kept");
    }

    fn members_of(n: usize, pad: usize) -> Vec<(String, String)> {
        (0..n).map(|i| (format!("member-{i:06}-{}", "x".repeat(pad)), "claude-code".into())).collect()
    }

    fn sent(ev: &Value) -> usize {
        serde_json::to_string(ev).unwrap().len()
    }

    #[test]
    fn members_count_toward_the_cap_and_messages_give_way_to_them() {
        let msgs = |n: usize| -> Vec<FeedMessage> { (0..n).map(|i| m(&i.to_string(), "t", &"y".repeat(20_000))).collect() };
        // 30,000 ordinary members take ~3.2 MB of the 4 MiB: they fit, and fewer messages do
        let (big, _) = build_init("t", &members_of(30_000, 60), msgs(300)).unwrap();
        assert!(sent(&big) <= INIT_MAX_BYTES, "sent {}", sent(&big));
        let (none, _) = build_init("t", &[], msgs(300)).unwrap();
        assert!(sent(&none) <= INIT_MAX_BYTES);
        assert!(big["messages"].as_array().unwrap().len() < none["messages"].as_array().unwrap().len());
        // a member list that fills the cap exactly to the edge keeps zero messages, still within the cap
        let (edge, _) = build_init("t", &members_of(30_000, 60), msgs(5)).unwrap();
        assert!(sent(&edge) <= INIT_MAX_BYTES);
    }

    #[test]
    fn a_member_list_over_the_cap_fails_closed_with_a_named_error() {
        // one member whose name alone is over the cap
        let huge = vec![("x".repeat(INIT_MAX_BYTES + 1), "claude-code".to_string())];
        let e = build_init("t", &huge, vec![]).unwrap_err();
        assert!(e.measured > INIT_MAX_BYTES && e.cap == INIT_MAX_BYTES, "{e:?}");
        assert!(e.message().contains("too large") && e.message().contains(&INIT_MAX_BYTES.to_string()));
        // many ordinary members
        let many = members_of(80_000, 60);
        let e = build_init("t", &many, vec![m("1", "t", "hi")]).unwrap_err();
        assert!(e.measured > INIT_MAX_BYTES);
        // the error does not depend on the messages
        assert!(build_init("t", &many, vec![]).is_err());
        // and nothing is silently cut: just under the cap still succeeds whole
        let (ok, _) = build_init("t", &members_of(20_000, 60), vec![]).unwrap();
        assert_eq!(ok["members"].as_array().unwrap().len(), 20_000);
        assert!(sent(&ok) <= INIT_MAX_BYTES);
    }

    #[test]
    fn message_event_shape() {
        let ev = message_event(&m("1", "t", "b"));
        assert_eq!(ev["type"], "message");
        assert_eq!(ev["message"]["id"], "1");
    }
}
