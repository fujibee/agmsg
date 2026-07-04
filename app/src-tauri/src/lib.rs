mod agmsg;
mod menu_i18n;
mod pty;

use pty::PtyManager;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use tauri::menu::{AboutMetadataBuilder, CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::{AppHandle, Emitter, Manager, Wry};

/// The native menu's current language (BCP-47 code, e.g. "ja", "zh-CN") —
/// the frontend pushes its i18next language here via `set_menu_language` on
/// startup and on every change, since React's i18n can't reach this
/// Rust-owned window chrome. Defaults to "en" until that first call arrives.
struct MenuLanguage(Mutex<String>);

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

/// Where the zoom level survives a restart — the only bit of window state
/// persisted so far (see App.tsx's LAST_TEAM_KEY for the equivalent on the
/// frontend side, which owns everything else). A flat `{"zoom": 1.2}` file
/// rather than reaching for a config crate — one f64, not worth it yet.
fn zoom_config_path(app: &AppHandle) -> Option<std::path::PathBuf> {
    app.path().app_config_dir().ok().map(|dir| dir.join("zoom.json"))
}

fn load_zoom(app: &AppHandle) -> f64 {
    (|| -> Option<f64> {
        let raw = std::fs::read_to_string(zoom_config_path(app)?).ok()?;
        let json: serde_json::Value = serde_json::from_str(&raw).ok()?;
        json.get("zoom")?.as_f64()
    })()
    .unwrap_or(1.0)
    .clamp(ZOOM_MIN, ZOOM_MAX)
}

fn save_zoom(app: &AppHandle, zoom: f64) {
    let Some(path) = zoom_config_path(app) else { return };
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(path, serde_json::json!({ "zoom": zoom }).to_string());
}

/// Build the application menu in `lang`. macOS derives the default menu's
/// About/Hide/Quit labels from the crate name (which can't contain a space),
/// so we define them explicitly to read "agmsg" (matching productName) and
/// give About the real app icon. The Edit menu's Copy/Paste are also needed
/// for the embedded terminals. All labels come from menu_i18n::t so the
/// whole native menu tracks the app's language selector rather than the OS
/// locale.
fn make_menu(app: &AppHandle, lang: &str) -> tauri::Result<Menu<Wry>> {
    let name = "agmsg";
    let m = |key: &str| menu_i18n::t(lang, "nativeMenu", key, &[]);
    let m_name = |key: &str| menu_i18n::t(lang, "nativeMenu", key, &[("name", name)]);
    let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/icon.png")).ok();
    let about = PredefinedMenuItem::about(
        app,
        Some(&m_name("about")),
        Some(AboutMetadataBuilder::new().name(Some(name.to_string())).icon(icon).build()),
    )?;
    let check_updates =
        MenuItem::with_id(app, CHECK_UPDATES_ID, m("checkForUpdates"), true, None::<&str>)?;
    let app_menu = Submenu::with_items(
        app,
        name,
        true,
        &[
            &about,
            &PredefinedMenuItem::separator(app)?,
            &check_updates,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::services(app, None)?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::hide(app, Some(&m_name("hide")))?,
            &PredefinedMenuItem::hide_others(app, Some(&m("hideOthers")))?,
            &PredefinedMenuItem::show_all(app, Some(&m("showAll")))?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::quit(app, Some(&m_name("quit")))?,
        ],
    )?;
    let edit_menu = Submenu::with_items(
        app,
        m("editMenu"),
        true,
        &[
            &PredefinedMenuItem::undo(app, Some(&m("undo")))?,
            &PredefinedMenuItem::redo(app, Some(&m("redo")))?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::cut(app, Some(&m("cut")))?,
            &PredefinedMenuItem::copy(app, Some(&m("copy")))?,
            &PredefinedMenuItem::paste(app, Some(&m("paste")))?,
            &PredefinedMenuItem::select_all(app, Some(&m("selectAll")))?,
        ],
    )?;
    // "Show User Chat" toggles the app-user send/receive panel (chat +
    // composer) in the frontend. The frontend owns the actual show/hide state;
    // this checkbox just reflects it and emits a toggle event when clicked.
    // Zoom In/Out/Actual Size mirror the standard browser-app trio (Cmd+=,
    // Cmd+-, Cmd+0) — see the ZoomLevel handler in run() for the logic.
    let view_menu = Submenu::with_items(
        app,
        m("viewMenu"),
        true,
        &[
            &CheckMenuItem::with_id(app, USER_CHAT_MENU_ID, m("showUserChat"), true, true, None::<&str>)?,
            &PredefinedMenuItem::separator(app)?,
            &MenuItem::with_id(app, ZOOM_IN_ID, m("zoomIn"), true, Some("CmdOrCtrl+="))?,
            &MenuItem::with_id(app, ZOOM_OUT_ID, m("zoomOut"), true, Some("CmdOrCtrl+-"))?,
            &MenuItem::with_id(app, ZOOM_RESET_ID, m("actualSize"), true, Some("CmdOrCtrl+0"))?,
        ],
    )?;
    let window_menu = Submenu::with_items(
        app,
        m("windowMenu"),
        true,
        &[
            &PredefinedMenuItem::minimize(app, Some(&m("minimize")))?,
            &PredefinedMenuItem::separator(app)?,
            &PredefinedMenuItem::close_window(app, Some(&m("closeWindow")))?,
        ],
    )?;
    Menu::with_items(app, &[&app_menu, &edit_menu, &view_menu, &window_menu])
}

const USER_CHAT_MENU_ID: &str = "toggle_user_chat";
const ZOOM_IN_ID: &str = "zoom_in";
const ZOOM_OUT_ID: &str = "zoom_out";
const ZOOM_RESET_ID: &str = "zoom_reset";
const CHECK_UPDATES_ID: &str = "check_updates";

/// Check the updater endpoint and, if a newer build is available, confirm
/// with the user before downloading, installing, and restarting. When
/// `user_initiated` is true (menu click) we also report "up to date" /
/// errors; a silent startup check stays quiet unless there's an update.
async fn check_for_updates(app: &AppHandle, user_initiated: bool) {
    use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};
    use tauri_plugin_updater::UpdaterExt;

    let lang = app.state::<MenuLanguage>().0.lock().unwrap().clone();
    let d = |key: &str, vars: &[(&str, &str)]| menu_i18n::t(&lang, "nativeDialog", key, vars);

    let updater = match app.updater() {
        Ok(u) => u,
        Err(e) => {
            if user_initiated {
                app.dialog()
                    .message(d("updateCheckFailed", &[("error", &e.to_string())]))
                    .kind(MessageDialogKind::Error)
                    .blocking_show();
            }
            return;
        }
    };

    match updater.check().await {
        Ok(Some(update)) => {
            let version = update.version.clone();
            let proceed = app
                .dialog()
                .message(d("updateAvailableBody", &[("name", "agmsg"), ("version", &version)]))
                .title(d("updateAvailableTitle", &[]))
                .kind(MessageDialogKind::Info)
                .buttons(MessageDialogButtons::OkCancelCustom(
                    d("installAndRestart", &[]),
                    d("later", &[]),
                ))
                .blocking_show();
            if !proceed {
                return;
            }
            if let Err(e) = update.download_and_install(|_, _| {}, || {}).await {
                app.dialog()
                    .message(d("updateFailed", &[("error", &e.to_string())]))
                    .kind(MessageDialogKind::Error)
                    .blocking_show();
                return;
            }
            app.restart();
        }
        Ok(None) => {
            if user_initiated {
                app.dialog()
                    .message(d("upToDate", &[]))
                    .title(d("noUpdatesTitle", &[]))
                    .kind(MessageDialogKind::Info)
                    .blocking_show();
            }
        }
        Err(e) => {
            if user_initiated {
                app.dialog()
                    .message(d("updateCheckFailed", &[("error", &e.to_string())]))
                    .kind(MessageDialogKind::Error)
                    .blocking_show();
            }
        }
    }
}

/// Called by the frontend (on i18next init, and on every language change)
/// to keep the native menu and update-check dialogs in the app's chosen
/// language rather than the OS locale. Rebuilds the whole menu — Tauri has
/// no per-item relabel API, and this only runs on an explicit language
/// switch, not per-frame, so rebuilding is cheap enough.
#[tauri::command]
fn set_menu_language(app: AppHandle, lang: String) -> Result<(), String> {
    *app.state::<MenuLanguage>().0.lock().unwrap() = lang.clone();
    let menu = make_menu(&app, &lang).map_err(|e| e.to_string())?;
    app.set_menu(menu).map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // Must be the first plugin registered (required on macOS) — a
        // second launch focuses the existing window instead of opening a
        // new one, so quitting/relaunching from the Dock or a second
        // double-click doesn't spawn duplicate instances each with their
        // own PTYs and agmsg DB watcher.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_focus();
                let _ = window.unminimize();
            }
        }))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        // Built in English first — the frontend doesn't get a chance to
        // report its actual language until after the webview loads and
        // i18next resolves it, so set_menu_language rebuilds this shortly
        // after startup with the real choice.
        .menu(|app| make_menu(app, "en"))
        .manage(UserChatVisible(AtomicBool::new(true)))
        .manage(ZoomLevel(Mutex::new(1.0)))
        .manage(MenuLanguage(Mutex::new("en".to_string())))
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
                save_zoom(app, *zoom);
            } else if id == CHECK_UPDATES_ID {
                let app_handle = app.clone();
                tauri::async_runtime::spawn(async move {
                    check_for_updates(&app_handle, true).await;
                });
            }
        })
        .manage(PtyManager::default())
        .setup(|app| {
            // Restore the zoom level saved on the last quit/change — .manage()
            // above only had 1.0 to work with (no AppHandle yet to read the
            // config file at that point).
            let zoom = load_zoom(app.handle());
            *app.state::<ZoomLevel>().0.lock().unwrap() = zoom;
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_zoom(zoom);
            }
            // Start the agmsg DB watcher so the team room updates live.
            agmsg::start_watcher(app.handle().clone());
            // Quiet startup check — only surfaces a dialog when an update is
            // actually available (see check_for_updates's user_initiated flag).
            let app_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                check_for_updates(&app_handle, false).await;
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            pty::pty_spawn,
            pty::pty_write,
            pty::pty_resize,
            pty::pty_kill,
            pty::pty_inject,
            agmsg::agmsg_is_installed,
            agmsg::agmsg_install,
            agmsg::agmsg_core_version_status,
            agmsg::agmsg_update_core,
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
            set_menu_language,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
