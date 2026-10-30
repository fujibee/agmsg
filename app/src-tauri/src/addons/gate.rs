//! The startup gate: add-ons run only while the app has just confirmed, with
//! an app-owned known frame, that this webview really isolates them.
//!
//! Rules:
//! - The probe frame is the app's own page in a frame with exactly the same
//!   webview, preferences and sandbox as a real add-on. A timeout, an
//!   exception or a missing result all mean add-ons stay off. An add-on's own
//!   report is never used as the probe.
//! - The CSP check attempts a forbidden self-navigation (to the app origin) and
//!   requires that it was refused; reading the configured CSP is not enough. It
//!   also makes an allowed navigation first and requires that to complete (a
//!   positive control), so a refusal is told apart from a slow navigation.
//! - WebRTC must be absent in the frame (`RTCPeerConnection` and its aliases)
//!   and a UDP sentinel the app opened must have received nothing.
//! - The gate is cleared for every new webview, reload and update; a window
//!   whose settings cannot be confirmed does not enable add-ons.
//! - Windows is on only with a working frame navigation guard on top of the
//!   probe (`WINDOWS_VERIFIED`: the same negative and positive tests passed there).

use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// The Windows measurement runs on the product build passed (the criteria in `m1/win-measure/CRITERIA.md`):
/// the probe, the required frame navigation guard, the WebRTC removal, the egress and read checks.
pub const WINDOWS_VERIFIED: bool = true;

/// Debug builds only: `AGMSG_WINDOWS_MEASURE=1` lets the Windows measurement runs open panes while
/// `WINDOWS_VERIFIED` is still false. Every other check stays in force (the probe, the frame guard);
/// only the "not verified yet" reason is waived. A release build has no such switch.
#[cfg(debug_assertions)]
fn measuring() -> bool {
    std::env::var_os("AGMSG_WINDOWS_MEASURE").is_some()
}
#[cfg(not(debug_assertions))]
fn measuring() -> bool {
    false
}

pub const PROBE_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Os {
    MacOs,
    Windows,
    Other,
}

impl Os {
    pub fn host() -> Os {
        if cfg!(target_os = "macos") {
            Os::MacOs
        } else if cfg!(windows) {
            Os::Windows
        } else {
            Os::Other
        }
    }
}

/// What the probe frame measured about itself.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", default)]
pub struct ProbeReport {
    pub nonce: String,
    /// The frame's script ran at all.
    pub started: bool,
    /// `self.origin === 'null'`: the sandbox has no `allow-same-origin`.
    pub opaque_origin: bool,
    /// `eval` threw: the pane CSP is in force.
    pub csp_blocks_eval: bool,
    /// After a forbidden navigation to the app origin the frame was still the
    /// same document, running.
    pub nav_refused: bool,
    /// The parent page observed an *enforced* `securitypolicyviolation` for the
    /// forbidden navigation: its directive (`frame-src`/`child-src`) ...
    pub nav_violation_directive: String,
    /// ... and the exact URI that was blocked. Both must match what the app
    /// asked for; a frame that merely survived (navigation pending, cancelled
    /// elsewhere, or failing for another reason) proves nothing.
    pub nav_violation_uri: String,
    /// Positive control: an allowed navigation (to the probe's own second page)
    /// completed in this environment, so a forbidden one that did not complete
    /// was refused, not merely slow.
    pub control_nav_ok: bool,
    /// `RTCPeerConnection`, `webkitRTCPeerConnection`, `RTCSessionDescription`
    /// and `RTCDataChannel` are all undefined.
    pub webrtc_absent: bool,
    /// Informational: the bridge globals present in the frame (macOS: none;
    /// WebView2 injects them into subframes).
    pub bridge_in_frame: bool,
    /// Stage B announced itself but its final answer was not received afterwards;
    /// the document may have been replaced (observed on WebView2 after a cancelled
    /// frame navigation), so the "document survived" half of the refusal cannot be seen.
    pub final_missing: bool,
}

/// What the app itself did to the engine before the probe.
#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct EngineReport {
    /// The WebRTC-off setting exists on this engine.
    pub webrtc_setting_present: bool,
    /// ... and was applied and reads back as off.
    pub webrtc_setting_applied: bool,
    /// Windows: why the frame navigation guard is not working, if it is not.
    pub frame_guard_problem: Option<String>,
    /// Windows: the targets the frame guard cancelled.
    pub frame_nav_cancelled: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Verdict {
    pub enabled: bool,
    pub reasons: Vec<String>,
}

pub fn evaluate(expected_nonce: &str, expected_target: &str, r: &ProbeReport, engine: &EngineReport, udp_hits: usize, os: Os) -> Verdict {
    let mut reasons = Vec::new();
    if r.nonce != expected_nonce {
        reasons.push("the probe answered with the wrong nonce".to_string());
    }
    if !r.started {
        reasons.push("the probe frame did not run".to_string());
    }
    if !r.opaque_origin {
        reasons.push("the probe frame does not have an opaque origin".to_string());
    }
    if !r.csp_blocks_eval {
        reasons.push("the pane CSP is not in force in the probe frame".to_string());
    }
    if !r.control_nav_ok {
        reasons.push("the probe could not tell a refused navigation from a slow one (its allowed navigation did not complete)".to_string());
    }
    // On Windows the guard is the refusal and it is required: when the final answer never arrives after
    // the interim one, the guard's own record of the exact cancelled target stands in for "the document
    // survived". The CSP violation below is still required.
    let guard_refused = os == Os::Windows && r.final_missing && engine.frame_nav_cancelled.iter().any(|u| u == expected_target);
    if !r.nav_refused && !guard_refused {
        reasons.push("the probe frame was able to navigate itself to the app origin".to_string());
    }
    // A refusal must be *seen*: the page's CSP reported blocking exactly that
    // navigation. Surviving for two seconds is not evidence.
    if !(matches!(r.nav_violation_directive.as_str(), "frame-src" | "child-src") && !expected_target.is_empty() && r.nav_violation_uri == expected_target) {
        reasons.push("no enforced frame-src violation was observed for the forbidden navigation, so a refusal cannot be told from a navigation that is pending or failed".to_string());
    }
    if !r.webrtc_absent {
        reasons.push("WebRTC is available in the probe frame".to_string());
    }
    if udp_hits > 0 {
        reasons.push(format!("the probe frame sent {udp_hits} UDP packets to the sentinel"));
    }
    match os {
        Os::MacOs => {
            if !engine.webrtc_setting_present {
                reasons.push("this WebKit has no WebRTC-off setting".to_string());
            } else if !engine.webrtc_setting_applied {
                reasons.push("the WebRTC-off setting could not be applied".to_string());
            }
        }
        Os::Windows => {
            if let Some(p) = &engine.frame_guard_problem {
                reasons.push(format!("the frame navigation guard is not working: {p}"));
            }
            if !WINDOWS_VERIFIED && !measuring() {
                reasons.push("add-ons are not verified on WebView2 yet".to_string());
            }
        }
        Os::Other => reasons.push("add-ons are not available on this platform".to_string()),
    }
    Verdict { enabled: reasons.is_empty(), reasons }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Pending {
    nonce: String,
    target: String,
    deadline: Instant,
    generation: u64,
}

#[derive(Debug, Default)]
struct State {
    generation: u64,
    pending: Option<Pending>,
    /// A recheck was started and its probe has not begun yet (so two cannot start at once).
    starting: bool,
    verdict: Verdict,
}

/// Add-ons are enabled iff `status().enabled`. The initial state is off.
#[derive(Default)]
pub struct AddonGate {
    inner: Mutex<State>,
}

impl AddonGate {
    pub fn new() -> AddonGate {
        let g = AddonGate::default();
        g.inner.lock().unwrap().verdict = Verdict { enabled: false, reasons: vec!["the startup check has not run yet".into()] };
        g
    }

    /// A new webview, a reload or an update: everything proven so far is void.
    /// Returns the new generation.
    pub fn invalidate(&self, why: &str) -> u64 {
        let mut s = self.inner.lock().unwrap();
        s.generation += 1;
        s.pending = None;
        s.starting = false;
        s.verdict = Verdict { enabled: false, reasons: vec![format!("checking again: {why}")] };
        s.generation
    }

    /// The user asked to run the startup check again. Refused (`None`) while a probe is running or
    /// about to begin, so two never run at once; otherwise everything proven so far is void and the
    /// caller starts the probe.
    pub fn try_recheck(&self) -> Option<u64> {
        let mut s = self.inner.lock().unwrap();
        if s.pending.is_some() || s.starting {
            return None;
        }
        s.generation += 1;
        s.starting = true;
        s.verdict = Verdict { enabled: false, reasons: vec!["checking again: asked by the user".into()] };
        Some(s.generation)
    }

    /// A recheck whose probe could not be started ends off, with the reason.
    pub fn start_failed(&self) {
        let mut s = self.inner.lock().unwrap();
        if s.starting && s.pending.is_none() {
            s.starting = false;
            s.verdict = Verdict { enabled: false, reasons: vec!["the startup check could not be started".into()] };
        }
    }

    /// Something the gate depends on broke while running: off now, with the reason.
    pub fn force_off(&self, why: &str) {
        let mut s = self.inner.lock().unwrap();
        s.generation += 1;
        s.pending = None;
        s.starting = false;
        s.verdict = Verdict { enabled: false, reasons: vec![why.to_string()] };
    }

    /// Starts a probe for the current generation.
    pub fn begin(&self, nonce: &str, target: &str, now: Instant) -> u64 {
        let mut s = self.inner.lock().unwrap();
        let generation = s.generation;
        s.starting = false;
        s.pending = Some(Pending { nonce: nonce.to_string(), target: target.to_string(), deadline: now + PROBE_TIMEOUT, generation });
        generation
    }

    /// The probe frame's answer (relayed by the main UI). Accepted once, only
    /// for the pending nonce of the current generation, and not after the
    /// deadline. `udp_hits` is read by the caller at this moment.
    pub fn report(&self, r: &ProbeReport, engine: &EngineReport, udp_hits: usize, os: Os, now: Instant) -> Verdict {
        let mut s = self.inner.lock().unwrap();
        let Some(p) = s.pending.clone() else {
            return s.verdict.clone();
        };
        if p.generation != s.generation {
            return s.verdict.clone();
        }
        if now > p.deadline {
            s.pending = None;
            s.verdict = Verdict { enabled: false, reasons: vec!["the startup check took too long".into()] };
            return s.verdict.clone();
        }
        if r.nonce != p.nonce {
            // a stray or forged answer does not end the probe; the real one may still come
            return Verdict { enabled: false, reasons: vec!["ignored an answer with the wrong nonce".into()] };
        }
        s.pending = None;
        s.verdict = evaluate(&p.nonce, &p.target, r, engine, udp_hits, os);
        s.verdict.clone()
    }

    /// Called by a timer: a probe past its deadline turns into "off".
    pub fn expire(&self, now: Instant) -> bool {
        let mut s = self.inner.lock().unwrap();
        match &s.pending {
            Some(p) if p.generation == s.generation && now > p.deadline => {
                s.pending = None;
                s.verdict = Verdict { enabled: false, reasons: vec!["the startup check did not finish (timeout)".into()] };
                true
            }
            _ => false,
        }
    }

    pub fn generation(&self) -> u64 {
        self.inner.lock().unwrap().generation
    }

    pub fn status(&self) -> Verdict {
        self.inner.lock().unwrap().verdict.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TARGET: &str = "tauri://localhost/__agmsg_probe_nav__/n";

    fn good(nonce: &str) -> ProbeReport {
        ProbeReport { nonce: nonce.into(), nav_violation_directive: "frame-src".into(), nav_violation_uri: TARGET.into(), started: true, opaque_origin: true, csp_blocks_eval: true, nav_refused: true, control_nav_ok: true, webrtc_absent: true, bridge_in_frame: false, final_missing: false }
    }

    fn eng() -> EngineReport {
        EngineReport { webrtc_setting_present: true, webrtc_setting_applied: true, frame_guard_problem: None, frame_nav_cancelled: vec![] }
    }

    #[test]
    fn a_replaced_frame_document_counts_as_refused_on_windows_only_with_the_guards_own_record() {
        // WebView2: the cancelled navigation replaces the probe's document, so no final answer comes.
        let replaced = ProbeReport { nav_refused: false, final_missing: true, ..good("n") };
        let cancelled = EngineReport { frame_nav_cancelled: vec![TARGET.into()], ..eng() };
        assert!(evaluate("n", TARGET, &replaced, &cancelled, 0, Os::Windows).enabled, "guard record + violation");
        let other = EngineReport { frame_nav_cancelled: vec!["tauri://localhost/other".into()], ..eng() };
        assert!(evaluate("n", TARGET, &replaced, &other, 0, Os::Windows).reasons.iter().any(|r| r.contains("able to navigate")), "cancelled another target");
        assert!(evaluate("n", TARGET, &replaced, &eng(), 0, Os::Windows).reasons.iter().any(|r| r.contains("able to navigate")), "nothing cancelled");
        let no_violation = ProbeReport { nav_violation_uri: String::new(), nav_violation_directive: String::new(), ..replaced.clone() };
        assert!(evaluate("n", TARGET, &no_violation, &cancelled, 0, Os::Windows).reasons.iter().any(|r| r.contains("frame-src violation")), "the CSP violation is still required");
        let missing = ProbeReport { final_missing: false, ..replaced };
        assert!(evaluate("n", TARGET, &missing, &cancelled, 0, Os::Windows).reasons.iter().any(|r| r.contains("able to navigate")), "no interim marker, no stand-in");
        let mac = ProbeReport { nav_refused: false, final_missing: true, ..good("n") };
        assert!(!evaluate("n", TARGET, &mac, &cancelled, 0, Os::MacOs).enabled, "never on macOS");
    }

    #[test]
    fn a_recheck_never_runs_two_probes_and_voids_an_old_answer() {
        let g = AddonGate::new();
        let t0 = Instant::now();
        g.invalidate("startup");
        g.begin("n1", TARGET, t0);
        assert!(g.try_recheck().is_none(), "a probe is running");
        assert!(g.expire(t0 + PROBE_TIMEOUT + Duration::from_millis(1)));
        assert!(g.try_recheck().is_some(), "after a timeout the user can ask again");
        assert!(g.try_recheck().is_none(), "the second probe has not begun but is already on its way");
        // the answer of the first probe arrives late: refused, and it does not end the new check
        let late = g.report(&good("n1"), &eng(), 0, Os::MacOs, t0 + PROBE_TIMEOUT + Duration::from_secs(1));
        assert!(!late.enabled);
        g.begin("n2", TARGET, t0 + Duration::from_secs(40));
        assert!(g.try_recheck().is_none());
        let old = g.report(&good("n1"), &eng(), 0, Os::MacOs, t0 + Duration::from_secs(41));
        assert!(!old.enabled, "an answer for the old nonce does not enable");
        let v = g.report(&good("n2"), &eng(), 0, Os::MacOs, t0 + Duration::from_secs(42));
        assert!(v.enabled, "{:?}", v.reasons);
    }

    #[test]
    fn a_recheck_that_cannot_start_a_probe_ends_off_with_a_reason() {
        let g = AddonGate::new();
        assert!(g.try_recheck().is_some());
        g.start_failed();
        assert!(g.status().reasons[0].contains("could not be started"));
        assert!(g.try_recheck().is_some(), "and the user can try again");
    }

    #[test]
    fn all_good_on_macos_enables() {
        let v = evaluate("n", TARGET, &good("n"), &eng(), 0, Os::MacOs);
        assert!(v.enabled, "{:?}", v.reasons);
    }

    #[test]
    fn every_single_failure_turns_it_off() {
        let base = good("n");
        let cases: Vec<(&str, ProbeReport)> = vec![
            ("nonce", ProbeReport { nonce: "x".into(), ..base.clone() }),
            ("started", ProbeReport { started: false, ..base.clone() }),
            ("opaque", ProbeReport { opaque_origin: false, ..base.clone() }),
            ("csp", ProbeReport { csp_blocks_eval: false, ..base.clone() }),
            ("nav", ProbeReport { nav_refused: false, ..base.clone() }),
            ("control", ProbeReport { control_nav_ok: false, ..base.clone() }),
            ("no violation seen", ProbeReport { nav_violation_uri: String::new(), nav_violation_directive: String::new(), ..base.clone() }),
            ("violation for another uri", ProbeReport { nav_violation_uri: "tauri://localhost/other".into(), ..base.clone() }),
            ("violation of another directive", ProbeReport { nav_violation_directive: "img-src".into(), ..base.clone() }),
            ("webrtc", ProbeReport { webrtc_absent: false, ..base.clone() }),
        ];
        for (name, r) in cases {
            let v = evaluate("n", TARGET, &r, &eng(), 0, Os::MacOs);
            assert!(!v.enabled, "{name}");
            assert_eq!(v.reasons.len(), 1, "{name}: {:?}", v.reasons);
        }
        assert!(!evaluate("n", TARGET, &base, &eng(), 1, Os::MacOs).enabled, "udp");
        assert!(!evaluate("n", TARGET, &base, &EngineReport { webrtc_setting_present: false, webrtc_setting_applied: false, frame_guard_problem: None, frame_nav_cancelled: vec![] }, 0, Os::MacOs).enabled, "no selector");
        assert!(!evaluate("n", TARGET, &base, &EngineReport { webrtc_setting_present: true, webrtc_setting_applied: false, frame_guard_problem: None, frame_nav_cancelled: vec![] }, 0, Os::MacOs).enabled, "not applied");
        assert!(!evaluate("n", TARGET, &ProbeReport::default(), &eng(), 0, Os::MacOs).enabled, "empty report");
    }

    #[test]
    fn a_surviving_frame_without_an_observed_refusal_stays_off() {
        // the frame is alive after two seconds, the allowed control navigation worked,
        // but nothing proves the forbidden navigation was refused: pending, failed or slow
        let r = ProbeReport { nav_violation_uri: String::new(), nav_violation_directive: String::new(), ..good("n") };
        assert!(r.nav_refused && r.control_nav_ok);
        let v = evaluate("n", TARGET, &r, &eng(), 0, Os::MacOs);
        assert!(!v.enabled);
        assert!(v.reasons[0].contains("pending or failed"));
        assert!(!evaluate("n", "", &good("n"), &eng(), 0, Os::MacOs).enabled, "no expected target means nothing can match");
    }

    #[test]
    fn windows_is_on_with_the_probe_and_the_guard_and_other_platforms_stay_off() {
        assert!(WINDOWS_VERIFIED);
        let v = evaluate("n", TARGET, &good("n"), &eng(), 0, Os::Windows);
        assert!(v.enabled, "{:?}", v.reasons);
        let broken = EngineReport { frame_guard_problem: Some("watching a frame's navigation: E_FAIL".into()), ..eng() };
        let v = evaluate("n", TARGET, &good("n"), &broken, 0, Os::Windows);
        assert!(!v.enabled && v.reasons.iter().any(|r| r.contains("frame navigation guard")), "{:?}", v.reasons);
        assert!(!evaluate("n", TARGET, &ProbeReport { webrtc_absent: false, ..good("n") }, &eng(), 0, Os::Windows).enabled);
        assert!(!evaluate("n", TARGET, &good("n"), &eng(), 0, Os::Other).enabled);
    }

    #[test]
    fn a_bridge_in_the_frame_is_informational() {
        let r = ProbeReport { bridge_in_frame: true, ..good("n") };
        assert!(evaluate("n", TARGET, &r, &eng(), 0, Os::MacOs).enabled);
    }

    #[test]
    fn starts_off() {
        let g = AddonGate::new();
        assert!(!g.status().enabled);
    }

    #[test]
    fn happy_path_enables_once() {
        let g = AddonGate::new();
        let t0 = Instant::now();
        g.invalidate("startup");
        g.begin("n1", TARGET, t0);
        let v = g.report(&good("n1"), &eng(), 0, Os::MacOs, t0 + Duration::from_secs(1));
        assert!(v.enabled);
        assert!(g.status().enabled);
        // an answer after it was consumed changes nothing
        let again = g.report(&ProbeReport::default(), &eng(), 9, Os::MacOs, t0 + Duration::from_secs(2));
        assert!(again.enabled, "second answer is ignored, state kept");
    }

    #[test]
    fn a_wrong_nonce_does_not_enable_and_does_not_end_the_probe() {
        let g = AddonGate::new();
        let t0 = Instant::now();
        g.invalidate("startup");
        g.begin("real", TARGET, t0);
        let v = g.report(&good("forged"), &eng(), 0, Os::MacOs, t0);
        assert!(!v.enabled);
        assert!(!g.status().enabled);
        assert!(g.report(&good("real"), &eng(), 0, Os::MacOs, t0).enabled);
    }

    #[test]
    fn a_late_answer_is_off() {
        let g = AddonGate::new();
        let t0 = Instant::now();
        g.invalidate("startup");
        g.begin("n", TARGET, t0);
        let v = g.report(&good("n"), &eng(), 0, Os::MacOs, t0 + PROBE_TIMEOUT + Duration::from_millis(1));
        assert!(!v.enabled);
        assert!(!g.status().enabled);
    }

    #[test]
    fn no_answer_means_off_after_the_deadline() {
        let g = AddonGate::new();
        let t0 = Instant::now();
        g.invalidate("startup");
        g.begin("n", TARGET, t0);
        assert!(!g.expire(t0 + Duration::from_secs(1)), "not yet");
        assert!(g.expire(t0 + PROBE_TIMEOUT + Duration::from_millis(1)));
        assert!(!g.status().enabled);
        assert!(g.status().reasons[0].contains("timeout"));
        assert!(!g.expire(t0 + Duration::from_secs(60)), "only once");
    }

    #[test]
    fn invalidate_voids_an_enabled_gate_and_a_pending_probe() {
        let g = AddonGate::new();
        let t0 = Instant::now();
        g.invalidate("startup");
        g.begin("n", TARGET, t0);
        assert!(g.report(&good("n"), &eng(), 0, Os::MacOs, t0).enabled);
        let gen = g.generation();
        g.invalidate("reload");
        assert!(g.generation() > gen);
        assert!(!g.status().enabled, "reload clears it");
        // an answer to the old probe cannot re-enable
        g.begin("n2", TARGET, t0);
        g.invalidate("update");
        let v = g.report(&good("n2"), &eng(), 0, Os::MacOs, t0);
        assert!(!v.enabled);
        assert!(!g.status().enabled);
    }

    #[test]
    fn report_without_a_pending_probe_changes_nothing() {
        let g = AddonGate::new();
        let v = g.report(&good("n"), &eng(), 0, Os::MacOs, Instant::now());
        assert!(!v.enabled);
        assert!(!g.status().enabled);
    }

    #[test]
    fn a_broken_frame_guard_keeps_windows_off_and_force_off_sticks_until_checked_again() {
        let mut e = eng();
        e.frame_guard_problem = Some("add NavigationStarting: E_FAIL".into());
        let v = evaluate("n", TARGET, &good("n"), &e, 0, Os::Windows);
        assert!(!v.enabled);
        assert!(v.reasons.iter().any(|r| r.contains("frame navigation guard is not working") && r.contains("E_FAIL")), "{:?}", v.reasons);
        let g = AddonGate::new();
        g.force_off("the frame guard broke");
        assert_eq!(g.status().reasons, vec!["the frame guard broke".to_string()]);
        assert!(!g.status().enabled);
    }
}
