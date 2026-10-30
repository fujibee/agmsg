//! Debug builds only: drive the real window for an end-to-end check.
//!
//! With `AGMSG_ADDON_E2E=<file.js>` set, the script in that file is evaluated in
//! the main window once it has had time to load (the same `eval` the startup
//! probe uses). The script clicks the real UI: the "+ New" menu, the grant cards.
//! What it did is read from the broker trace (`AGMSG_ADDON_TRACE=1`), which logs
//! every request an add-on frame made and how it ended. Nothing here exists in a
//! release build.

use std::time::Duration;
use tauri::{AppHandle, Listener, Manager, Runtime};

pub fn spawn_driver<R: Runtime>(app: AppHandle<R>) {
    let Ok(path) = std::env::var("AGMSG_ADDON_E2E") else { return };
    // The script reports what it did through an event; it is printed here.
    app.listen("e2e-report", |ev| eprintln!("[addons-e2e] {}", ev.payload()));
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(
            std::env::var("AGMSG_ADDON_E2E_DELAY").ok().and_then(|v| v.parse().ok()).unwrap_or(12),
        ));
        let js = match std::fs::read_to_string(&path) {
            Ok(j) => j,
            Err(e) => return eprintln!("[addons-e2e] cannot read {path}: {e}"),
        };
        let Some(window) = app.get_webview_window("main") else { return eprintln!("[addons-e2e] no main window") };
        // A window behind others is throttled; bring it forward so the script's timers run.
        let _ = window.show();
        let _ = window.set_focus();
        eprintln!("[addons-e2e] driver injected: {}", window.eval(&js).is_ok());
        // Further scripts, "file@seconds,file@seconds": run later, to see whether the page is alive.
        if let Ok(list) = std::env::var("AGMSG_ADDON_E2E_LATER") {
            let mut last = 0u64;
            for item in list.split(',').filter(|i| !i.is_empty()) {
                let Some((file, at)) = item.rsplit_once('@') else { continue };
                let at: u64 = at.parse().unwrap_or(0);
                std::thread::sleep(Duration::from_secs(at.saturating_sub(last)));
                last = at;
                match std::fs::read_to_string(file) {
                    Ok(j) => eprintln!("[addons-e2e] later script {file} injected: {}", window.eval(&j).is_ok()),
                    Err(e) => eprintln!("[addons-e2e] cannot read {file}: {e}"),
                }
            }
        }
    });
}
