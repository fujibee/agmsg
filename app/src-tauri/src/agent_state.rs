use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde::Serialize;

pub const TAIL_CAPACITY: usize = 8 * 1024;
pub const DETECTION_INTERVAL: std::time::Duration = std::time::Duration::from_millis(400);
const STARTUP_GRACE: Duration = Duration::from_secs(2);
const IDLE_CONFIRMATIONS: u8 = 3;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PaneState {
    Idle,
    Working,
    Blocked,
    Unknown,
}

pub struct DetectionTracker {
    agent_type: String,
    state: PaneState,
    created_at: Instant,
    idle_confirmations: u8,
    last_output_seq: Option<u64>,
}

impl DetectionTracker {
    pub fn new(agent_type: String) -> Self {
        Self {
            agent_type,
            state: PaneState::Unknown,
            created_at: Instant::now(),
            idle_confirmations: 0,
            last_output_seq: None,
        }
    }

    pub fn state(&self) -> PaneState {
        self.state
    }

    pub fn observe(&mut self, tail: &str, output_seq: u64, now: Instant) -> Option<PaneState> {
        if now.saturating_duration_since(self.created_at) < STARTUP_GRACE {
            return None;
        }

        let output_changed = self.last_output_seq != Some(output_seq);
        self.last_output_seq = Some(output_seq);
        let candidate = if !output_changed && self.state == PaneState::Working {
            PaneState::Idle
        } else if !output_changed && self.state == PaneState::Blocked {
            PaneState::Blocked
        } else {
            classify(&self.agent_type, tail)
        };
        let next = match (self.state, candidate) {
            (_, PaneState::Blocked) => {
                self.idle_confirmations = 0;
                PaneState::Blocked
            }
            (_, PaneState::Working) => {
                self.idle_confirmations = 0;
                PaneState::Working
            }
            (PaneState::Working, PaneState::Idle) => {
                self.idle_confirmations = self.idle_confirmations.saturating_add(1);
                if self.idle_confirmations < IDLE_CONFIRMATIONS {
                    PaneState::Working
                } else {
                    self.idle_confirmations = 0;
                    PaneState::Idle
                }
            }
            (_, next) => {
                self.idle_confirmations = 0;
                next
            }
        };

        if next == self.state {
            None
        } else {
            self.state = next;
            Some(next)
        }
    }
}

pub fn classify(agent_type: &str, tail: &str) -> PaneState {
    if !matches!(agent_type, "claude-code" | "claude" | "codex" | "gemini") {
        return PaneState::Unknown;
    }

    const COMMON_BLOCKED: &[&str] = &[
        "Do you want to proceed?",
        "Allow this action?",
        "waiting for approval",
        "Waiting for approval",
        "Enter to confirm",
        "(y/n)",
        "[y/N]",
        "[Y/n]",
    ];
    const SPINNERS: &[&str] = &["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
    const CODEX_BLOCKED: &[&str] = &[
        "Allow command?",
        "Do you trust the contents of this directory?",
        "Press enter to continue",
        "enter to submit answer",
    ];
    const GEMINI_BLOCKED: &[&str] = &[
        "Do you trust the files in this folder?",
        "(Use Enter to select)",
    ];

    let blocked_patterns = match agent_type {
        "codex" => CODEX_BLOCKED,
        "gemini" => GEMINI_BLOCKED,
        _ => &[],
    };
    let working_patterns: &[&str] = match agent_type {
        "gemini" => &["Thinking", "esc to cancel"],
        _ => &["esc to interrupt", "Esc to interrupt"],
    };

    if COMMON_BLOCKED
        .iter()
        .chain(blocked_patterns.iter())
        .any(|pattern| tail.contains(pattern))
    {
        PaneState::Blocked
    } else if working_patterns
        .iter()
        .chain(SPINNERS.iter())
        .any(|pattern| tail.contains(pattern))
    {
        PaneState::Working
    } else {
        PaneState::Idle
    }
}

pub struct TailBuffer {
    bytes: VecDeque<u8>,
    output_seq: u64,
}

impl Default for TailBuffer {
    fn default() -> Self {
        Self {
            bytes: VecDeque::with_capacity(TAIL_CAPACITY),
            output_seq: 0,
        }
    }
}

impl TailBuffer {
    pub fn push(&mut self, input: &[u8]) {
        if input.is_empty() {
            return;
        }
        self.output_seq = self.output_seq.wrapping_add(1);
        let overflow = self
            .bytes
            .len()
            .saturating_add(input.len())
            .saturating_sub(TAIL_CAPACITY);
        self.bytes.drain(..overflow.min(self.bytes.len()));
        if input.len() > TAIL_CAPACITY {
            self.bytes.extend(&input[input.len() - TAIL_CAPACITY..]);
        } else {
            self.bytes.extend(input);
        }
    }

    pub fn detection_tail(&self) -> String {
        let raw: Vec<u8> = self.bytes.iter().copied().collect();
        let text = strip_ansi(&String::from_utf8_lossy(&raw));
        let lines: Vec<&str> = text.lines().collect();
        // Joined with a space, not "\n": a narrow pane wraps a prompt like "Do
        // you want to proceed?" across two lines, and a literal "\n" would
        // split that phrase apart, permanently defeating classify()'s
        // substring match for as long as the pane stays that width (#385
        // "blocking doesn't react" diagnosis).
        lines[lines.len().saturating_sub(20)..].join(" ")
    }

    pub fn snapshot(&self) -> (String, u64) {
        (self.detection_tail(), self.output_seq)
    }
}

fn strip_ansi(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let mut chars = input.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '\u{1b}' {
            output.push(ch);
            continue;
        }

        match chars.peek().copied() {
            Some('[') => {
                chars.next();
                for c in chars.by_ref() {
                    if ('@'..='~').contains(&c) {
                        break;
                    }
                }
            }
            Some(']') => {
                chars.next();
                let mut escaped = false;
                for c in chars.by_ref() {
                    if c == '\u{7}' || (escaped && c == '\\') {
                        break;
                    }
                    escaped = c == '\u{1b}';
                }
            }
            _ => {}
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::{classify, DetectionTracker, PaneState, TailBuffer, TAIL_CAPACITY};

    #[test]
    fn tail_is_bounded_to_capacity() {
        let mut tail = TailBuffer::default();
        tail.push(&vec![b'a'; TAIL_CAPACITY + 10]);
        assert_eq!(tail.bytes.len(), TAIL_CAPACITY);
    }

    #[test]
    fn detection_tail_strips_ansi_and_keeps_last_twenty_lines() {
        let mut tail = TailBuffer::default();
        let content = (0..25)
            .map(|line| format!("\u{1b}[31mline-{line}\u{1b}[0m"))
            .collect::<Vec<_>>()
            .join("\n");
        tail.push(content.as_bytes());
        let snapshot = tail.detection_tail();
        assert!(!snapshot.contains('\u{1b}'));
        assert!(snapshot.starts_with("line-5"));
        assert!(snapshot.ends_with("line-24"));
    }

    #[test]
    fn detection_tail_strips_bel_and_st_terminated_osc_sequences() {
        let mut tail = TailBuffer::default();
        tail.push(b"before\x1b]0;title\x07middle\x1b]9;progress\x1b\\after");
        assert_eq!(tail.detection_tail(), "beforemiddleafter");
    }

    #[test]
    fn detection_tail_survives_narrow_pane_word_wrap() {
        let mut tail = TailBuffer::default();
        // A narrow pane wraps the approval prompt mid-phrase.
        tail.push(b"Do you want to\nproceed?\n");
        assert_eq!(
            classify("claude", &tail.detection_tail()),
            PaneState::Blocked
        );
    }

    #[test]
    fn blocked_patterns_take_priority_over_working_noise() {
        assert_eq!(
            classify("codex", "Thinking\nAllow command?"),
            PaneState::Blocked
        );
    }

    #[test]
    fn uses_agent_specific_blocked_patterns() {
        assert_eq!(
            classify("gemini", "Do you trust the files in this folder?"),
            PaneState::Blocked
        );
        assert_eq!(
            classify("codex", "Press enter to continue"),
            PaneState::Blocked
        );
        assert_eq!(
            classify("claude", "Press enter to continue"),
            PaneState::Idle
        );
    }

    #[test]
    fn ignores_claude_dashboard_history_headings() {
        assert_eq!(
            classify("claude", "Working\nCompleted\n3 awaiting input"),
            PaneState::Idle
        );
    }

    #[test]
    fn unsupported_agents_remain_unknown() {
        assert_eq!(classify("grok", "Thinking"), PaneState::Unknown);
    }

    #[test]
    fn working_to_idle_requires_three_confirmations() {
        let started = Instant::now();
        let mut tracker = DetectionTracker::new("codex".to_string());
        let ready = started + Duration::from_secs(3);
        assert_eq!(
            tracker.observe("esc to interrupt", 1, ready),
            Some(PaneState::Working)
        );
        assert_eq!(tracker.observe("esc to interrupt", 1, ready), None);
        assert_eq!(tracker.observe("esc to interrupt", 1, ready), None);
        assert_eq!(
            tracker.observe("esc to interrupt", 1, ready),
            Some(PaneState::Idle)
        );
    }

    #[test]
    fn blocked_state_stays_sticky_while_output_is_quiet() {
        let started = Instant::now();
        let mut tracker = DetectionTracker::new("codex".to_string());
        let ready = started + Duration::from_secs(3);
        assert_eq!(
            tracker.observe("Allow command?", 1, ready),
            Some(PaneState::Blocked)
        );
        assert_eq!(tracker.observe("Allow command?", 1, ready), None);
        assert_eq!(tracker.state(), PaneState::Blocked);
    }

    #[test]
    fn startup_grace_keeps_new_panes_unknown() {
        let started = Instant::now();
        let mut tracker = DetectionTracker::new("gemini".to_string());
        assert_eq!(tracker.observe("Thinking", 1, started), None);
        assert_eq!(tracker.state(), PaneState::Unknown);
    }
}
