mod agmsg;
mod pty;

use pty::PtyManager;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use tauri::menu::{AboutMetadataBuilder, CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::{AppHandle, Emitter, Manager, Wry};

/// Explicit toggle state for View > Show User Chat. We don't rely on
/// CheckMenuItem flipping its own checked state on click (that's an
/// implementation detail of the underlying menu library and isn't guaranteed),
/// so this is the single source of truth: the handler flips it, pushes it to
/// the checkbox via set_checked, and emits it to the frontend.
struct UserChatVisible(AtomicBool);

/// Current webview zoom factor (1.0 = 100%). Tauri's WebviewWindow can set
/// the zoom but not read it back, so this is the source of truth the Zoom
/// In/Out/Actual Size menu items adjust and apply via set_zoom.
struct ZoomLevel(Mutex<f64>);

const ZOOM_STEP: f64 = 0.1;
const ZOOM_MIN: f64 = 0.5;
const ZOOM_MAX: f64 = 3.0;

/// Build the application menu. macOS derives the default menu's About/Hide/Quit
/// labels from the crate name (which can't contain a space), so we define them
/// explicitly to read "agmsg app" and give About the real app icon. The Edit
/// menu's Copy/Paste are also needed for the embedded terminals.
fn make_menu(app: &AppHandle) -> tauri::Result<Menu<Wry>> {
    let name = "agmsg app";
    let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/icon.png")).ok();
    let about = PredefinedMenuItem::about(
        app,
        Some(&format!("About {name}")),
        Some(AboutMetadataBuilder::new().name(Some(name.to_string())).icon(icon).build()),
    )?;
    let app_menu = Submenu::with_items(
        app,
        name,
        true,
        &[
            &about,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::services(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::hide(app, Some(&format!("Hide {name}")))?,
            &PredefinedMenuItem::hide_others(app, None)?,
            &PredefinedMenuItem::show_all(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::quit(app, Some(&format!("Quit {name}")))?,
        ],
    )?;
    let edit_menu = Submenu::with_items(
        app,
        "Edit",
        true,
        &[
            &PredefinedMenuItem::undo(app, None)?,
            &PredefinedMenuItem::redo(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::cut(app, None)?,
            &PredefinedMenuItem::copy(app, None)?,
            &PredefinedMenuItem::paste(app, None)?,
            &PredefinedMenuItem::select_all(app, None)?,
        ],
    )?;
    // "Show User Chat" toggles the app-user send/receive panel (chat +
    // composer) in the frontend. The frontend owns the actual show/hide state;
    // this checkbox just reflects it and emits a toggle event when clicked.
    // Zoom In/Out/Actual Size mirror the standard browser-app trio (Cmd+=,
    // Cmd+-, Cmd+0) — see the ZoomLevel handler in run() for the logic.
    let view_menu = Submenu::with_items(
        app,
        "View",
        true,
        &[
            &CheckMenuItem::with_id(app, USER_CHAT_MENU_ID, "Show User Chat", true, true, None::<&str>)?,
            &PredefinedMenuItem::separator(app)?,
            &MenuItem::with_id(app, ZOOM_IN_ID, "Zoom In", true, Some("CmdOrCtrl+="))?,
            &MenuItem::with_id(app, ZOOM_OUT_ID, "Zoom Out", true, Some("CmdOrCtrl+-"))?,
            &MenuItem::with_id(app, ZOOM_RESET_ID, "Actual Size", true, Some("CmdOrCtrl+0"))?,
        ],
    )?;
    let window_menu = Submenu::with_items(
        app,
        "Window",
        true,
        &[
            &PredefinedMenuItem::minimize(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::close_window(app, None)?,
        ],
    )?;
    Menu::with_items(app, &[&app_menu, &edit_menu, &view_menu, &window_menu])
}

const USER_CHAT_MENU_ID: &str = "toggle_user_chat";
const ZOOM_IN_ID: &str = "zoom_in";
const ZOOM_OUT_ID: &str = "zoom_out";
const ZOOM_RESET_ID: &str = "zoom_reset";

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .menu(|app| make_menu(app))
        .manage(UserChatVisible(AtomicBool::new(true)))
        .manage(ZoomLevel(Mutex::new(1.0)))
        .on_menu_event(|app, event| {
            let id = event.id().as_ref();
            if id == USER_CHAT_MENU_ID {
                let state = app.state::<UserChatVisible>();
                let next = !state.0.load(Ordering::Relaxed);
                state.0.store(next, Ordering::Relaxed);
                if let Some(menu) = app.menu() {
                    if let Some(item) = menu.get(USER_CHAT_MENU_ID) {
                        if let Some(check) = item.as_check_menuitem() {
                            let _ = check.set_checked(next);
                        }
                    }
                }
                let _ = app.emit("toggle-user-chat", next);
            } else if id == ZOOM_IN_ID || id == ZOOM_OUT_ID || id == ZOOM_RESET_ID {
                let state = app.state::<ZoomLevel>();
                let mut zoom = state.0.lock().unwrap();
                *zoom = match id {
                    _ if id == ZOOM_IN_ID => (*zoom + ZOOM_STEP).min(ZOOM_MAX),
                    _ if id == ZOOM_OUT_ID => (*zoom - ZOOM_STEP).max(ZOOM_MIN),
                    _ => 1.0,
                };
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.set_zoom(*zoom);
                }
            }
        })
        .manage(PtyManager::default())
        .setup(|app| {
            // Start the agmsg DB watcher so the team room updates live.
            agmsg::start_watcher(app.handle().clone());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            pty::pty_spawn,
            pty::pty_write,
            pty::pty_resize,
            pty::pty_kill,
            pty::pty_inject,
            agmsg::agmsg_teams,
            agmsg::agmsg_members,
            agmsg::agmsg_messages,
            agmsg::agmsg_send,
            agmsg::agmsg_join,
            agmsg::agmsg_rename,
            agmsg::agmsg_leave,
            agmsg::agmsg_delivery_mode,
            agmsg::agmsg_default_project,
            agmsg::agmsg_command_name,
            agmsg::agmsg_spawnable_types,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
