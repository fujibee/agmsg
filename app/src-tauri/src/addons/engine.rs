//! Engine hardening applied to the main webview before any add-on frame exists.
//! Every setting here is fail-closed: the probe (see `gate`) measures the
//! outcome, and a setting that is missing or cannot be applied keeps add-ons off.

use super::gate::EngineReport;
use tauri::{Runtime, WebviewWindow};

/// macOS: turn WebRTC off with the private `WKPreferences` setting
/// `_setPeerConnectionEnabled:`, only if the selector responds. CSP does not
/// govern ICE, so without this a frame can send UDP (measured in M1).
#[cfg(target_os = "macos")]
pub fn harden<R: Runtime>(window: &WebviewWindow<R>) -> EngineReport {
    use objc2::runtime::{AnyObject, Sel};
    use objc2::{msg_send, sel};
    use std::sync::mpsc;
    use std::time::Duration;

    let (tx, rx) = mpsc::channel::<EngineReport>();
    let sent = window.with_webview(move |wv| unsafe {
        let view = wv.inner() as *mut AnyObject;
        let mut report = EngineReport::default();
        if view.is_null() {
            let _ = tx.send(report);
            return;
        }
        let conf: *mut AnyObject = msg_send![view, configuration];
        let prefs: *mut AnyObject = msg_send![conf, preferences];
        if prefs.is_null() {
            let _ = tx.send(report);
            return;
        }
        let set: Sel = sel!(_setPeerConnectionEnabled:);
        let get: Sel = sel!(_peerConnectionEnabled);
        let has_set: bool = msg_send![prefs, respondsToSelector: set];
        let has_get: bool = msg_send![prefs, respondsToSelector: get];
        report.webrtc_setting_present = has_set && has_get;
        if report.webrtc_setting_present {
            let _: () = msg_send![prefs, _setPeerConnectionEnabled: false];
            let now: bool = msg_send![prefs, _peerConnectionEnabled];
            report.webrtc_setting_applied = !now;
        }
        let _ = tx.send(report);
    });
    if sent.is_err() {
        return EngineReport::default();
    }
    rx.recv_timeout(Duration::from_secs(5)).unwrap_or_default()
}

/// Windows and others: nothing is applied; the gate keeps add-ons off there.
#[cfg(not(target_os = "macos"))]
pub fn harden<R: Runtime>(_window: &WebviewWindow<R>) -> EngineReport {
    EngineReport::default()
}
