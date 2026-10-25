//! Frame navigation guard for WebView2.
//!
//! Tauri's `on_navigation` does not report subframe navigations on Windows
//! (measured on WebView2 155), so a pane frame could navigate itself to the app
//! origin unseen. WebView2 does report them per frame: `FrameCreated` fires for
//! every frame (and `ChildFrameCreated` for nested ones), and each frame's
//! `NavigationStarting` carries the target. Every frame gets its own `FrameNav`,
//! so the frame-to-origin mapping needs no lookup; a frame that was never
//! assigned a pane origin is refused (fail closed) and logged.

use std::sync::Arc;

use tauri::{Runtime, Url, WebviewWindow};
use webview2_com::Microsoft::Web::WebView2::Win32::{
    ICoreWebView2Frame, ICoreWebView2Frame2, ICoreWebView2Frame7, ICoreWebView2_4,
};
use webview2_com::{take_pwstr, FrameChildFrameCreatedEventHandler, FrameCreatedEventHandler, FrameNavigationStartingEventHandler};
use windows::core::{Interface, PWSTR};

use super::host::AddonHost;
use super::nav::FrameNav;

fn guard_frame(host: &Arc<AddonHost>, frame: &ICoreWebView2Frame) {
    let rule = Arc::new(FrameNav::default());

    if let Ok(frame2) = frame.cast::<ICoreWebView2Frame2>() {
        let host = host.clone();
        let rule = rule.clone();
        let handler = FrameNavigationStartingEventHandler::create(Box::new(move |_frame, args| {
            let Some(args) = args else { return Ok(()) };
            let mut raw = PWSTR::null();
            unsafe { args.Uri(&mut raw)? };
            let uri = take_pwstr(raw);
            let allow = match Url::parse(&uri) {
                Ok(url) => {
                    let d = rule.decide(&host.nav, &url);
                    if !d.is_allow() {
                        eprintln!("[addons] cancelled frame navigation to {} ({:?})", super::host::redact(&url), d);
                    }
                    d.is_allow()
                }
                Err(_) => {
                    eprintln!("[addons] cancelled frame navigation to an unparsable address");
                    false
                }
            };
            if !allow {
                unsafe { args.SetCancel(true)? };
            }
            Ok(())
        }));
        let mut token = 0i64;
        if unsafe { frame2.add_NavigationStarting(&handler, &mut token) }.is_err() {
            eprintln!("[addons] could not watch a frame's navigation; the frame stays under the CSP only");
        }
    } else {
        eprintln!("[addons] this WebView2 runtime cannot watch frame navigation; frames stay under the CSP only");
    }

    // nested frames get the same treatment
    if let Ok(frame7) = frame.cast::<ICoreWebView2Frame7>() {
        let host = host.clone();
        let handler = FrameChildFrameCreatedEventHandler::create(Box::new(move |_frame, args| {
            if let Some(child) = args.and_then(|a| unsafe { a.Frame() }.ok()) {
                guard_frame(&host, &child);
            }
            Ok(())
        }));
        let mut token = 0i64;
        let _ = unsafe { frame7.add_FrameCreated(&handler, &mut token) };
    }
}

/// Watches every frame of the main webview, including frames created after
/// this call (a pane opened later, or the page reloading).
pub fn install<R: Runtime>(window: &WebviewWindow<R>, host: Arc<AddonHost>) {
    let res = window.with_webview(move |wv| unsafe {
        let core = match wv.controller().CoreWebView2() {
            Ok(c) => c,
            Err(e) => {
                eprintln!("[addons] frame guard not installed: no WebView2 core ({e})");
                return;
            }
        };
        let Ok(core4) = core.cast::<ICoreWebView2_4>() else {
            eprintln!("[addons] frame guard not installed: this WebView2 runtime has no FrameCreated");
            return;
        };
        let handler = FrameCreatedEventHandler::create(Box::new(move |_core, args| {
            if let Some(frame) = args.and_then(|a| a.Frame().ok()) {
                guard_frame(&host, &frame);
            }
            Ok(())
        }));
        let mut token = 0i64;
        match core4.add_FrameCreated(&handler, &mut token) {
            Ok(()) => eprintln!("[addons] frame guard installed"),
            Err(e) => eprintln!("[addons] frame guard not installed: {e}"),
        }
    });
    if let Err(e) = res {
        eprintln!("[addons] frame guard not installed: {e}");
    }
}
