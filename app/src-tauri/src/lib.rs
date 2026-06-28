mod agmsg;
mod pty;

use pty::PtyManager;
use tauri::menu::{AboutMetadataBuilder, Menu, PredefinedMenuItem, Submenu};
use tauri::{AppHandle, Wry};

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
    Menu::with_items(app, &[&app_menu, &edit_menu, &window_menu])
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .menu(|app| make_menu(app))
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
            agmsg::agmsg_default_project,
            agmsg::agmsg_command_name,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
