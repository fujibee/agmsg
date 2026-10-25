//! Frame navigation guard for WebView2.
//!
//! Tauri's `on_navigation` does not report subframe navigations on Windows
//! (measured on WebView2 155), so a pane frame could navigate itself to the app
//! origin unseen. WebView2 does report them per frame: `FrameCreated` fires for
//! every frame (and `ChildFrameCreated` for nested ones), and each frame's
//! `NavigationStarting` carries the target. Every frame gets its own `FrameNav`,
//! so the frame-to-origin mapping needs no lookup.
//!
//! The guard is required, not best effort. Every step that can fail is checked
//! through `GuardStatus`; a failure, now or later, turns add-ons off with the
//! reason (the gate shows it) and closes every open pane. A navigation is
//! cancelled unless the rule allows it.

use std::sync::Arc;

use tauri::{AppHandle, Emitter, Runtime, WebviewWindow};
use webview2_com::Microsoft::Web::WebView2::Win32::{ICoreWebView2Frame, ICoreWebView2Frame2, ICoreWebView2Frame7, ICoreWebView2_4};
use webview2_com::{take_pwstr, FrameChildFrameCreatedEventHandler, FrameCreatedEventHandler, FrameNavigationStartingEventHandler};
use windows::core::{Interface, PWSTR};

use super::host::{AddonHost, GATE_EVENT};
use super::nav::{frame_navigation_allowed, FrameNav};

/// Runs a setup step; on failure add-ons go off and open panes close.
fn step<R: Runtime>(app: &AppHandle<R>, host: &AddonHost, what: &str, r: windows::core::Result<()>) -> bool {
    let ok = host.guard.check(what, r.map_err(|e| e.to_string()));
    if !ok {
        fail_closed(app, host);
    }
    ok
}

fn fail_closed<R: Runtime>(app: &AppHandle<R>, host: &AddonHost) {
    let why = host.guard.problem().unwrap_or_else(|| "the frame navigation guard failed".into());
    eprintln!("[addons] frame guard: {why}; add-ons are off");
    for (port, token) in host.panes.close_all() {
        host.nav.unregister_pane(port, &token);
    }
    host.gate.force_off(&format!("the frame navigation guard is not working: {why}"));
    let _ = app.emit(GATE_EVENT, host.gate.status());
}

fn guard_frame<R: Runtime>(app: &AppHandle<R>, host: &Arc<AddonHost>, frame: &ICoreWebView2Frame) {
    let rule = Arc::new(FrameNav::default());

    match frame.cast::<ICoreWebView2Frame2>() {
        Ok(frame2) => {
            let (h, a, r) = (host.clone(), app.clone(), rule.clone());
            let handler = FrameNavigationStartingEventHandler::create(Box::new(move |_frame, args| {
                // cancel by default; allow only after the rule says so
                let Some(args) = args else { return Ok(()) };
                let mut raw = PWSTR::null();
                let uri = unsafe { args.Uri(&mut raw) }.map(|_| take_pwstr(raw)).map_err(|e| e.to_string());
                let allow = frame_navigation_allowed(&r, &h.nav, uri, &h.guard);
                if !allow {
                    eprintln!("[addons] cancelled a frame navigation");
                    step(&a, &h, "cancelling a frame navigation", unsafe { args.SetCancel(true) });
                    if h.guard.problem().is_some() {
                        fail_closed(&a, &h);
                    }
                }
                Ok(())
            }));
            let mut token = 0i64;
            step(app, host, "watching a frame's navigation", unsafe { frame2.add_NavigationStarting(&handler, &mut token) });
        }
        Err(e) => {
            step(app, host, "this WebView2 runtime cannot watch frame navigation", Err(e));
        }
    }

    // nested frames get the same treatment
    match frame.cast::<ICoreWebView2Frame7>() {
        Ok(frame7) => {
            let (h, a) = (host.clone(), app.clone());
            let handler = FrameChildFrameCreatedEventHandler::create(Box::new(move |_frame, args| {
                match args.and_then(|a| unsafe { a.Frame() }.ok()) {
                    Some(child) => guard_frame(&a, &h, &child),
                    None => {
                        step(&a, &h, "reading a nested frame", Err(windows::core::Error::from(windows::Win32::Foundation::E_POINTER)));
                    }
                }
                Ok(())
            }));
            let mut token = 0i64;
            step(app, host, "watching nested frames", unsafe { frame7.add_FrameCreated(&handler, &mut token) });
        }
        Err(e) => {
            step(app, host, "this WebView2 runtime cannot watch nested frames", Err(e));
        }
    }
}

/// Watches every frame of the main webview, including frames created after
/// this call (a pane opened later, or the page reloading). The outcome is
/// recorded in `host.guard`; until it is active the gate stays off.
pub fn install<R: Runtime>(window: &WebviewWindow<R>, app: AppHandle<R>, host: Arc<AddonHost>) {
    let (app2, host2) = (app.clone(), host.clone());
    let res = window.with_webview(move |wv| unsafe {
        let (app, host) = (app2, host2);
        let core = match wv.controller().CoreWebView2() {
            Ok(c) => c,
            Err(e) => {
                step(&app, &host, "reading the WebView2 core", Err(e));
                return;
            }
        };
        let core4 = match core.cast::<ICoreWebView2_4>() {
            Ok(c) => c,
            Err(e) => {
                step(&app, &host, "this WebView2 runtime has no FrameCreated", Err(e));
                return;
            }
        };
        let (h, a) = (host.clone(), app.clone());
        let handler = FrameCreatedEventHandler::create(Box::new(move |_core, args| {
            match args.and_then(|x| x.Frame().ok()) {
                Some(frame) => guard_frame(&a, &h, &frame),
                None => {
                    step(&a, &h, "reading a new frame", Err(windows::core::Error::from(windows::Win32::Foundation::E_POINTER)));
                }
            }
            Ok(())
        }));
        let mut token = 0i64;
        if step(&app, &host, "registering the frame guard", core4.add_FrameCreated(&handler, &mut token)) {
            host.guard.mark_active();
            eprintln!("[addons] frame guard installed");
        }
    });
    if let Err(e) = res {
        host.guard.fail(&format!("with_webview: {e}"));
        fail_closed(&app, &host);
    }
}
