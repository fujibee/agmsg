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
    last_tail: Option<String>,
}

impl DetectionTracker {
    pub fn new(agent_type: String) -> Self {
        Self {
            agent_type,
            state: PaneState::Unknown,
            created_at: Instant::now(),
            idle_confirmations: 0,
            last_tail: None,
        }
    }

    pub fn state(&self) -> PaneState {
        self.state
    }

    pub fn observe(&mut self, tail: &str, now: Instant) -> Option<PaneState> {
        if now.saturating_duration_since(self.created_at) < STARTUP_GRACE {
            return None;
        }

        // Compares the DERIVED text, not a raw byte/push counter: a blinking
        // cursor or other zero-width escape noise still arrives as PTY bytes
        // every tick even while the pane is genuinely idle, so a push-based
        // "did anything arrive" signal never goes quiet and the 3-tick
        // debounce below never got to fire (#385 — panes stuck showing
        // Working forever after the agent actually finished).
        let tail_changed = self.last_tail.as_deref() != Some(tail);
        self.last_tail = Some(tail.to_string());
        let candidate = if tail_changed {
            classify(&self.agent_type, tail)
        } else {
            // A static tail means nothing new happened since last tick:
            // Working debounces down toward Idle below (no more output ==
            // probably done), and every other state — crucially including
            // Idle itself — just holds. Re-running classify() here on an
            // Idle pane's unchanged snapshot was the actual bug: if that
            // frozen frame still had a stale spinner glyph in it (a
            // synchronized-output redraw that stalled mid-animation), it
            // matched Working again immediately, bounced right back to
            // Idle after another 3-tick debounce, and repeated forever.
            match self.state {
                PaneState::Working => PaneState::Idle,
                other => other,
            }
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
        // Generic numbered-choice menus (e.g. the plan-mode-exit conflict
        // dialog) don't say "Do you want to proceed?" at all — confirmed
        // from a live capture, #385 — but they all share this footer
        // regardless of which menu is showing, so it covers the class
        // instead of enumerating every prompt's own wording.
        "Enter to select",
        // Structural fallback for the SAME class of menu, for when even
        // that footer isn't there (confirmed from a live capture, #385: the
        // plan-review "Ready to code?" screen has neither "Do you want to
        // proceed?" nor "Enter to select" — just "Would you like to
        // proceed?" and a numbered list). Every one of these interactive
        // menus opens with its first option pre-selected behind "❯", so
        // matching that marker generalizes across prompt wording we
        // haven't seen yet instead of enumerating each one — the same idea
        // herdr uses for codex's "›" cursor glyph (src/detect/manifest.rs),
        // just applied to claude's own selector character.
        "❯ 1.",
    ];
    const BRAILLE_SPINNERS: &[&str] = &["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
    // Claude Code's "thinking" spinner cycles through these sparkle glyphs,
    // not the braille dots above — confirmed from a real capture (#385):
    // "✻i…", "✳…", "✶5", "✢di", "✽n30" all rendering behind a whimsical
    // verb ("Considering…" etc). The braille set never matched claude panes,
    // and "esc to interrupt" doesn't appear in the current CLI build either
    // (checked via `strings` on the installed binary), so Working detection
    // for claude was relying on neither signal actually firing — any tick
    // without a Blocked match fell straight through to Idle mid-generation.
    const CLAUDE_SPINNERS: &[&str] = &["✢", "✳", "✶", "✻", "✽"];
    // Verified against herdr's codex.toml (src/detect/manifests/codex.toml)
    // rather than guessed: "Press enter to continue" and "Do you trust the
    // contents of this directory?" were never real Codex CLI strings (the
    // latter reads like VS Code's workspace-trust dialog, not Codex) and
    // never matched anything.
    const CODEX_BLOCKED: &[&str] = &[
        "Allow command?",
        "enter to submit answer",
        "enter to submit all",
        "press enter to confirm or esc to cancel",
        "[y/n]",
        "yes (y)",
        // Set in the window title, not the screen — TailBuffer::detection_tail
        // appends the last-seen title to the flattened text, so this still
        // matches via the same plain substring check. herdr's cheapest/
        // highest-priority Codex blocked signal.
        "Action Required",
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
        // Codex's working signal is purely the title-bar spinner glyph
        // (below) — herdr's codex.toml has no phrase-based working rule at
        // all, and "esc to interrupt" is confirmed absent from it (it only
        // appears in devin.toml/opencode.toml).
        "codex" => &[],
        _ => &["esc to interrupt", "Esc to interrupt"],
    };
    let spinners: &[&str] = match agent_type {
        "claude" | "claude-code" => CLAUDE_SPINNERS,
        _ => BRAILLE_SPINNERS,
    };

    // Case-insensitive, matching herdr's own gates (they normalize both
    // sides via `.to_lowercase()`) — we don't actually know the exact
    // casing every one of these strings renders with on screen, so
    // matching loosely here beats silently missing a real match over a
    // capitalization difference.
    let tail_lower = tail.to_lowercase();
    if COMMON_BLOCKED
        .iter()
        .chain(blocked_patterns.iter())
        .any(|pattern| tail_lower.contains(&pattern.to_lowercase()))
    {
        PaneState::Blocked
    } else if working_patterns
        .iter()
        .chain(spinners.iter())
        .any(|pattern| tail_lower.contains(&pattern.to_lowercase()))
    {
        PaneState::Working
    } else {
        PaneState::Idle
    }
}

pub struct TailBuffer {
    bytes: VecDeque<u8>,
}

impl Default for TailBuffer {
    fn default() -> Self {
        Self {
            bytes: VecDeque::with_capacity(TAIL_CAPACITY),
        }
    }
}

impl TailBuffer {
    pub fn push(&mut self, input: &[u8]) {
        if input.is_empty() {
            return;
        }
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
        let (text, title) = strip_ansi(&String::from_utf8_lossy(&raw));
        // Split on '\r' as well as '\n': ink redraws the spinner/status line
        // in place with a bare carriage return, not a newline (confirmed
        // from a real capture, #385 — dozens of "Cerebrating…" spinner
        // frames arrive '\r'-separated with no '\n' at all). `.lines()`
        // alone treated that whole run as ONE line, so it never aged out of
        // the last-20 window — a resolved permission prompt, or a finished
        // "Working" spinner, could keep matching indefinitely because its
        // bytes were still sitting near the front of that one giant "line"
        // long after the real terminal had moved past them.
        let lines: Vec<&str> = text.split(['\r', '\n']).collect();
        let recent = &lines[lines.len().saturating_sub(20)..];

        // Structural narrowing, ported from herdr's src/detect/manifest.rs
        // (prompt_box_body / after_last_horizontal_rule): scope down to the
        // live bordered box's body when the window holds a complete one,
        // else to whatever came after the most recent box's closing rule.
        // Pure box-drawing-character geometry, no words involved, so it
        // generalizes across every dialog's own wording and sheds stale
        // scrollback the recency window alone can't (a resolved dialog's
        // closing rule marks everything above it as no-longer-current).
        let scoped = prompt_box_body(recent).unwrap_or_else(|| after_last_horizontal_rule(recent));
        let menu_option_selected = scoped.iter().any(|line| is_chevron_menu_line(line));

        // Joined with a space, not '\n'/'\r': a narrow pane wraps a prompt
        // like "Do you want to proceed?" across two frames, and either
        // separator would split that phrase apart, permanently defeating
        // classify()'s substring match for as long as the pane stays that
        // width.
        let mut flattened = scoped.join(" ");
        if menu_option_selected {
            // A line starting with claude's selector glyph followed by real
            // content (not the bare, nothing-highlighted composer prompt)
            // means SOME option is currently highlighted in an interactive
            // menu — herdr: claude.toml's `^\s*❯` gate, the same idea as
            // codex's `›` cursor glyph. Guaranteed present in the flattened
            // text this way regardless of which option number is shown or
            // whether an adjacent color code broke the natural adjacency.
            flattened.push_str(" ❯ 1.");
        }
        // Codex reports its own state through the window title, not the
        // screen (herdr: codex.toml's `osc_title` region — a Braille
        // spinner glyph means Working, "Action Required" means Blocked).
        // Appending it here lets classify()'s existing substring patterns
        // pick it up without needing their own code path.
        if let Some(title) = title {
            flattened.push(' ');
            flattened.push_str(&title);
        }
        flattened
    }
}

// Structural detectors ported from herdr's src/detect/manifest.rs — pure
// box-drawing-character and glyph geometry, no literal English words. herdr
// uses these to pick WHICH region of the screen to run its phrase rules
// against, not to classify state by shape alone; we do the same, applying
// them ahead of classify()'s (still literal) pattern matching.

/// A line made (almost) entirely of the box-drawing rule character, with
/// nothing but whitespace after it — the top/bottom border of a bordered
/// box (the permission-prompt/plan-review dialogs all draw one).
fn is_horizontal_rule(line: &str) -> bool {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return false;
    }
    let rule_chars = trimmed.chars().take_while(|&ch| ch == '─').count();
    if rule_chars == 0 {
        return false;
    }
    let rest: String = trimmed.chars().skip(rule_chars).collect();
    rest.trim().is_empty() || rule_chars >= 3
}

/// Index of the top border of the most recently opened box: the
/// second-to-last horizontal-rule line, scanning bottom-up.
fn prompt_box_top_border_index(lines: &[&str]) -> Option<usize> {
    let mut rules_seen = 0;
    for index in (0..lines.len()).rev() {
        if is_horizontal_rule(lines[index]) {
            rules_seen += 1;
            if rules_seen == 2 {
                return Some(index);
            }
        }
    }
    None
}

/// The lines strictly between a currently-open box's top and bottom
/// border, if the window holds a complete one.
fn prompt_box_body<'a>(lines: &'a [&'a str]) -> Option<&'a [&'a str]> {
    let top = prompt_box_top_border_index(lines)?;
    let body_start = top + 1;
    let body_end = lines[body_start..]
        .iter()
        .position(|line| is_horizontal_rule(line))
        .map(|relative| body_start + relative)
        .unwrap_or(lines.len());
    lines.get(body_start..body_end)
}

/// Everything after the last horizontal-rule line in the window (the
/// fallback when there's no complete box, only a box that just closed).
fn after_last_horizontal_rule<'a>(lines: &'a [&'a str]) -> &'a [&'a str] {
    match lines.iter().rposition(|line| is_horizontal_rule(line)) {
        Some(index) => &lines[index + 1..],
        None => lines,
    }
}

/// claude's menu-selector glyph followed by a NUMBERED option ("❯ 1. ...")
/// means an option is currently highlighted in an interactive menu (herdr:
/// claude.toml's `^\s*❯` gate). The bare composer prompt ("❯" alone) is
/// already excluded by requiring real content — but the composer ALSO
/// shows "❯ " immediately followed by whatever the user is typing (e.g.
/// "❯ fix the bug"), which looks just as "non-empty" and caused a false
/// Blocked the moment anyone typed a message (#385, live repro). Requiring
/// the content to start with digits + '.' (the option-numbering every one
/// of these menus actually uses) rules that out without misclassifying a
/// real menu.
fn is_chevron_menu_line(line: &str) -> bool {
    let Some(rest) = line.trim_start().strip_prefix('❯') else {
        return false;
    };
    let rest = rest.trim_start();
    let digits = rest.chars().take_while(|c| c.is_ascii_digit()).count();
    digits > 0 && rest.as_bytes().get(digits) == Some(&b'.')
}

// Cursor Forward (CSI n C) and Cursor Horizontal Absolute (CSI n G) both move
// the cursor without printing — ink pads/aligns text with them instead of
// writing literal spaces (confirmed from a real permission-prompt capture,
// #385: "Do\x1b[5Gyou\x1b[9Gwant\x1b[14Gto\x1b[17Gproceed?" renders as "Do you
// want to proceed?", but naively dropping the escapes glued it into
// "Doyouwanttoproceed?", which no longer matched classify()'s substring
// patterns — the actual cause of panes getting stuck instead of turning
// Blocked/Working). `col` tracks the 0-indexed column the next printed
// character would land on, reset on '\r'/'\n', so both forms can be
// rendered back as the gap of spaces they visually are.
//
// Returns the stripped body text plus the LAST OSC 0/2 window-title string
// seen, if any. Codex sets its live/blocked state in the window title, not
// the visible screen (herdr: codex.toml's `osc_title` region) — e.g. a
// Braille spinner glyph in the title means Working, "Action Required" means
// Blocked — so that title text has to survive somewhere for classify() to
// see it, instead of being silently discarded like every other OSC.
fn strip_ansi(input: &str) -> (String, Option<String>) {
    let mut output = String::with_capacity(input.len());
    let mut title: Option<String> = None;
    let mut col: usize = 0;
    let mut chars = input.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '\u{1b}' {
            if ch == '\r' || ch == '\n' {
                col = 0;
            } else {
                col += 1;
            }
            output.push(ch);
            continue;
        }

        match chars.peek().copied() {
            Some('[') => {
                chars.next();
                let mut params = String::new();
                for c in chars.by_ref() {
                    if ('@'..='~').contains(&c) {
                        match c {
                            'C' => {
                                let n = params.parse().unwrap_or(1).clamp(1, 512);
                                output.extend(std::iter::repeat_n(' ', n));
                                col += n;
                            }
                            // Only a forward jump can be represented as
                            // spaces; a same-or-backward jump is left alone
                            // since already-emitted text can't be un-printed.
                            'G' => {
                                let target: usize = params.parse().unwrap_or(1).max(1);
                                if target > col + 1 {
                                    let gap = (target - 1 - col).min(512);
                                    output.extend(std::iter::repeat_n(' ', gap));
                                    col = target - 1;
                                }
                            }
                            _ => {}
                        }
                        break;
                    }
                    params.push(c);
                }
            }
            Some(']') => {
                chars.next();
                let mut body = String::new();
                let mut escaped = false;
                for c in chars.by_ref() {
                    if c == '\u{7}' || (escaped && c == '\\') {
                        break;
                    }
                    escaped = c == '\u{1b}';
                    body.push(c);
                }
                // "0;<title>" or "2;<title>" (OSC 0 sets icon+title, OSC 2
                // sets title only — both are the window title as far as a
                // reader is concerned).
                if let Some(rest) = body.strip_prefix("0;").or_else(|| body.strip_prefix("2;")) {
                    title = Some(rest.trim_end_matches('\u{1b}').to_string());
                }
            }
            _ => {}
        }
    }
    (output, title)
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use super::{
        after_last_horizontal_rule, classify, is_chevron_menu_line, is_horizontal_rule,
        prompt_box_body, DetectionTracker, PaneState, TailBuffer, TAIL_CAPACITY,
    };

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
    fn carriage_return_redraws_age_out_old_frames_like_newlines_do() {
        // ink rewrites the spinner in place with a bare '\r', never '\n'
        // (#385). A resolved permission prompt followed by enough spinner
        // redraws must age out of the last-20-frame window exactly like a
        // resolved prompt followed by enough real newlines would — a stale
        // "Do you want to proceed?" sitting near the front of one giant
        // '\r'-joined "line" was why panes stayed stuck as Blocked (or
        // Working, from stale spinner text) long after they'd moved on.
        let mut tail = TailBuffer::default();
        tail.push(b"Do you want to proceed?\r");
        for i in 0..25 {
            tail.push(format!("frame-{i}\r").as_bytes());
        }
        let snapshot = tail.detection_tail();
        assert!(
            !snapshot.contains("Do you want to proceed?"),
            "got: {snapshot:?}"
        );
        assert_eq!(classify("claude", &snapshot), PaneState::Idle);
    }

    #[test]
    fn is_horizontal_rule_requires_only_whitespace_after_a_short_run() {
        assert!(is_horizontal_rule("────────────"));
        assert!(is_horizontal_rule("  ───  "));
        // A pure rule of any length (nothing after it) still counts.
        assert!(is_horizontal_rule("──"));
        // With trailing content, at least 3 rule chars are required — a
        // labeled divider like "── Section ──" is still a rule, but a
        // stray "--" in normal prose isn't.
        assert!(is_horizontal_rule("─── Section"));
        assert!(!is_horizontal_rule("── not a rule"));
        assert!(!is_horizontal_rule(""));
        assert!(!is_horizontal_rule("plain text"));
    }

    #[test]
    fn is_chevron_menu_line_excludes_the_bare_composer_prompt() {
        assert!(is_chevron_menu_line("❯ 1. Yes"));
        assert!(is_chevron_menu_line("  ❯ 1. Exit plan mode"));
        assert!(is_chevron_menu_line("❯ 10. tenth option"));
        assert!(!is_chevron_menu_line("❯"));
        assert!(!is_chevron_menu_line("❯ "));
        assert!(!is_chevron_menu_line("no chevron here"));
    }

    #[test]
    fn is_chevron_menu_line_ignores_the_user_typing_a_message() {
        // Live repro (#385): the composer shows "❯ <whatever you're
        // typing>" the same way it shows "❯ 1. <option>" for a real menu —
        // "content after the glyph" alone isn't enough to tell them apart.
        // Typing any message briefly flipped the pane to Blocked until this
        // was tightened to require the option-numbering real menus use.
        assert!(!is_chevron_menu_line("❯ あああ"));
        assert!(!is_chevron_menu_line("❯ /agmsg actas Alice"));
        assert!(!is_chevron_menu_line("❯ fix the lint errors"));
    }

    #[test]
    fn prompt_box_body_extracts_the_lines_between_the_two_most_recent_rules() {
        let lines = [
            "stale text",
            "────",
            "Do you want to proceed?",
            "❯ 1. Yes",
            "────",
        ];
        assert_eq!(
            prompt_box_body(&lines),
            Some(&["Do you want to proceed?", "❯ 1. Yes"][..])
        );
    }

    #[test]
    fn after_last_horizontal_rule_falls_back_when_only_one_rule_is_in_view() {
        let lines = [
            "Do you want to proceed?",
            "❯ 1. Yes",
            "────",
            "next turn's output",
        ];
        assert_eq!(prompt_box_body(&lines), None);
        assert_eq!(after_last_horizontal_rule(&lines), &["next turn's output"]);
    }

    #[test]
    fn detection_tail_scopes_to_the_open_box_and_drops_a_stale_closed_one() {
        // Two dialogs back to back: an earlier, already-resolved box (whose
        // "Do you want to proceed?" is stale scrollback now) followed by a
        // brand new one that's actually open. Only the open box's content
        // should survive — this is what makes a resolved dialog's text stop
        // poisoning classify() even within the same 20-line window, on top
        // of (not instead of) the recency window itself (#385).
        let mut tail = TailBuffer::default();
        tail.push(
            "────\n\
Do you want to proceed?\n\
❯ 1. Yes\n\
────\n\
some output after answering\n\
────\n\
Would you like to proceed?\n\
❯ 1. Yes, and use auto mode\n\
────\n"
                .as_bytes(),
        );
        let snapshot = tail.detection_tail();
        assert!(
            !snapshot.contains("Do you want to proceed?"),
            "got: {snapshot:?}"
        );
        assert!(snapshot.contains("Would you like to proceed?"));
        assert_eq!(classify("claude", &snapshot), PaneState::Blocked);
    }

    #[test]
    fn detection_tail_strips_non_title_bel_and_st_terminated_osc_sequences() {
        let mut tail = TailBuffer::default();
        tail.push(b"before\x1b]9;progress\x07middle\x1b]8;;url\x1b\\after");
        assert_eq!(tail.detection_tail(), "beforemiddleafter");
    }

    #[test]
    fn detection_tail_appends_the_osc_0_and_2_window_title() {
        // Codex reports Working/Blocked through the window title, not the
        // screen (herdr: codex.toml's `osc_title` region) — the title has
        // to survive into the flattened text for classify() to see it.
        let mut tail = TailBuffer::default();
        tail.push(b"before\x1b]0;Action Required\x07after");
        assert_eq!(tail.detection_tail(), "beforeafter Action Required");

        // OSC 2 (title-only, no icon) counts the same way.
        let mut tail2 = TailBuffer::default();
        tail2.push(b"before\x1b]2;codex\x07after");
        assert_eq!(tail2.detection_tail(), "beforeafter codex");
    }

    #[test]
    fn codex_blocked_and_working_signals_come_from_the_title_not_the_screen() {
        // End-to-end (TailBuffer -> classify()): a codex pane whose visible
        // screen has nothing recognizable, but whose title carries the
        // real signal (herdr: codex.toml's osc_title region).
        let mut blocked = TailBuffer::default();
        blocked.push(b"ordinary transcript output\x1b]0;Action Required\x07");
        assert_eq!(
            classify("codex", &blocked.detection_tail()),
            PaneState::Blocked
        );

        let mut working = TailBuffer::default();
        working.push("ordinary transcript output\x1b]2;⠙ codex\u{7}".as_bytes());
        assert_eq!(
            classify("codex", &working.detection_tail()),
            PaneState::Working
        );
    }

    #[test]
    fn cursor_forward_sequences_become_the_spaces_they_visually_are() {
        // CSI n C (Cursor Forward) moves the cursor without printing — used
        // here for the box's 1-column left indent before "Do".
        let mut tail = TailBuffer::default();
        tail.push(b"\x1b[1CDo you want to proceed?");
        assert_eq!(tail.detection_tail(), " Do you want to proceed?");
    }

    #[test]
    fn cursor_horizontal_absolute_sequences_become_the_spaces_they_visually_are() {
        // Captured verbatim (mid-word color codes trimmed) from a real
        // Claude Code permission dialog (#385): ink right-pads each word to
        // a precomputed column with CSI n G (Cursor Horizontal Absolute)
        // instead of writing literal spaces. Dropping those escapes (the
        // old behavior, which only handled the unrelated Cursor Forward
        // form) glued the phrase into "Doyouwanttoproceed?", which no
        // longer matched classify()'s "Do you want to proceed?" pattern —
        // the actual cause of panes getting stuck instead of turning
        // Blocked.
        let mut tail = TailBuffer::default();
        tail.push(b"\x1b[1CDo\x1b[5Gyou\x1b[9Gwant\x1b[14Gto\x1b[17Gproceed?");
        assert_eq!(tail.detection_tail(), " Do you want to proceed?");
        assert_eq!(
            classify("claude", &tail.detection_tail()),
            PaneState::Blocked
        );
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
        // "enter to submit ANSWER", not COMMON_BLOCKED's "Enter to confirm"
        // — picked to not accidentally overlap with the shared list, so
        // this only passes if it's really CODEX_BLOCKED doing the work.
        assert_eq!(
            classify("codex", "please press Enter to submit Answer now"),
            PaneState::Blocked
        );
        assert_eq!(
            classify("claude", "please press Enter to submit Answer now"),
            PaneState::Idle
        );
    }

    #[test]
    fn uses_claude_sparkle_spinner_not_braille() {
        // Real captured spinner frames (#385) — claude never emits the
        // braille dots, so this only passes once classify() checks the
        // sparkle glyphs for claude specifically.
        assert_eq!(
            classify("claude", "✻ Considering… (10s)"),
            PaneState::Working
        );
        assert_eq!(
            classify("claude-code", "✳ Percolating…"),
            PaneState::Working
        );
        assert_eq!(
            classify("claude", "⠋ some other cli's spinner"),
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
    fn detects_generic_numbered_choice_menus() {
        // Captured live (#385): the plan-mode-exit conflict dialog never
        // says "Do you want to proceed?" — only a numbered list and this
        // footer.
        assert_eq!(
            classify(
                "claude",
                "1. Exit plan mode and continue actas 2. Stay in plan mode Enter to select · ↑/↓ to navigate · Esc to cancel"
            ),
            PaneState::Blocked
        );
    }

    #[test]
    fn detects_menus_with_neither_known_phrase_via_the_selector_marker() {
        // Captured live (#385): the plan-review "Ready to code?" screen has
        // neither "Do you want to proceed?" nor "Enter to select" — just
        // "Would you like to proceed?", which isn't in any pattern list —
        // so only the "❯ 1." selector marker catches it.
        assert_eq!(
            classify(
                "claude",
                "Would you like to proceed? ❯ 1. Yes, and use auto mode   2. Yes, manually approve edits"
            ),
            PaneState::Blocked
        );
    }

    #[test]
    fn unsupported_agents_remain_unknown() {
        assert_eq!(classify("grok", "Thinking"), PaneState::Unknown);
    }

    #[test]
    fn working_to_idle_requires_three_confirmations() {
        let started = Instant::now();
        let mut tracker = DetectionTracker::new("claude".to_string());
        let ready = started + Duration::from_secs(3);
        assert_eq!(
            tracker.observe("esc to interrupt", ready),
            Some(PaneState::Working)
        );
        assert_eq!(tracker.observe("esc to interrupt", ready), None);
        assert_eq!(tracker.observe("esc to interrupt", ready), None);
        assert_eq!(
            tracker.observe("esc to interrupt", ready),
            Some(PaneState::Idle)
        );
    }

    #[test]
    fn blocked_state_stays_sticky_while_output_is_quiet() {
        let started = Instant::now();
        let mut tracker = DetectionTracker::new("codex".to_string());
        let ready = started + Duration::from_secs(3);
        assert_eq!(
            tracker.observe("Allow command?", ready),
            Some(PaneState::Blocked)
        );
        assert_eq!(tracker.observe("Allow command?", ready), None);
        assert_eq!(tracker.state(), PaneState::Blocked);
    }

    #[test]
    fn startup_grace_keeps_new_panes_unknown() {
        let started = Instant::now();
        let mut tracker = DetectionTracker::new("gemini".to_string());
        assert_eq!(tracker.observe("Thinking", started), None);
        assert_eq!(tracker.state(), PaneState::Unknown);
    }

    #[test]
    fn changing_text_keeps_resetting_the_idle_debounce() {
        // A live token/elapsed-time counter changes the tail every tick
        // while genuinely still working (e.g. "esc to interrupt (12s)" ->
        // "... (13s)"). Each such change must keep resetting the 3-tick
        // debounce, the same way a truly static byte stream would — the
        // debounce keys off the derived text, not a raw "did any PTY byte
        // arrive" counter, which could never go quiet on its own once a
        // zero-width escape (e.g. cursor blink) starts firing every tick
        // regardless of real activity (#385).
        let started = Instant::now();
        let mut tracker = DetectionTracker::new("claude".to_string());
        let ready = started + Duration::from_secs(3);
        assert_eq!(
            tracker.observe("esc to interrupt (1s)", ready),
            Some(PaneState::Working)
        );
        assert_eq!(tracker.observe("esc to interrupt (2s)", ready), None);
        assert_eq!(tracker.observe("esc to interrupt (3s)", ready), None);
        // Still changing on what would have been the 3rd quiet tick — stays
        // Working, doesn't debounce yet.
        assert_eq!(tracker.observe("esc to interrupt (4s)", ready), None);
        assert_eq!(tracker.state(), PaneState::Working);
        // Now it goes genuinely quiet — 3 fresh identical ticks required.
        assert_eq!(tracker.observe("esc to interrupt (4s)", ready), None);
        assert_eq!(tracker.observe("esc to interrupt (4s)", ready), None);
        assert_eq!(
            tracker.observe("esc to interrupt (4s)", ready),
            Some(PaneState::Idle)
        );
    }

    #[test]
    fn idle_does_not_bounce_back_to_working_on_a_stale_frozen_spinner() {
        // Captured live from a real pane (#385): a synchronized-output
        // redraw stalled mid-animation, so the tail stayed byte-for-byte
        // identical for many ticks in a row while still containing a
        // spinner glyph from the moment it froze. Once Working correctly
        // debounces down to Idle, re-running classify() on that same
        // still-spinner-containing static tail flipped it right back to
        // Working — which then re-debounced to Idle after another 3 ticks,
        // forever. A static tail must hold whatever state it's already in
        // (other than Working, which debounces toward Idle) rather than
        // being reclassified from scratch.
        let started = Instant::now();
        let mut tracker = DetectionTracker::new("claude".to_string());
        let ready = started + Duration::from_secs(3);
        let frozen = "✻ Baked for 50s · 1 monitor still running";
        assert_eq!(tracker.observe(frozen, ready), Some(PaneState::Working));
        assert_eq!(tracker.observe(frozen, ready), None);
        assert_eq!(tracker.observe(frozen, ready), None);
        assert_eq!(tracker.observe(frozen, ready), Some(PaneState::Idle));
        // The bug: this next call used to flip straight back to Working.
        for _ in 0..10 {
            assert_eq!(tracker.observe(frozen, ready), None);
            assert_eq!(tracker.state(), PaneState::Idle);
        }
    }
}
