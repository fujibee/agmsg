mod agmsg;
mod agent_state;
mod menu_i18n;
mod pty;

use pty::PtyManager;
use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use tauri::menu::{AboutMetadataBuilder, CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::{AppHandle, Emitter, Manager, Wry};

/// The PATH import_login_shell_path() resolved, kept around so every spawn
/// site (pty::pty_spawn, agmsg::bash_command) can attach it to the child
/// process explicitly via .env("PATH", ...) rather than relying on the
/// spawned process implicitly inheriting this process's own (mutated)
/// environment — a real Finder-launch hardware failure persisted even with
/// the process-level std::env::set_var in place, so this makes the
/// propagation explicit instead of trusting inheritance. None on Windows
/// (import_login_shell_path is unix-only) and on unix if the import failed,
/// in which case callers fall back to their own default behavior.
static IMPORTED_PATH: OnceLock<String> = OnceLock::new();

pub(crate) fn imported_path() -> Option<&'static str> {
    IMPORTED_PATH.get().map(|s| s.as_str())
}

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

/// Same idea as UserChatVisible, for View > Show Team Room — when off, the
/// frontend removes the Team Room tab entirely (not just its content), and
/// falls back to whichever pane tab is active, or an empty-state hint if
/// none exist yet.
struct TeamRoomVisible(AtomicBool);

/// Handles to the View menu's two checkboxes — see make_menu's comment on
/// why these can't just be looked up via app.menu().get(id) each time.
/// Rebuilt (and these Mutexes overwritten) on every set_menu_language call,
/// since that constructs an entirely new Menu with fresh CheckMenuItems.
struct ViewMenuCheckboxes {
    team_room: Mutex<CheckMenuItem<Wry>>,
    user_chat: Mutex<CheckMenuItem<Wry>>,
}

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

/// Replaces this process's own PATH with the one the user's login shell
/// resolves — a Finder/LaunchServices-launched GUI app gets the OS's
/// minimal default PATH, missing anything the shell profile adds (Homebrew,
/// ~/.claude/local, nvm, etc.), so every agent spawn (pty::pty_spawn) fails
/// with "not found in PATH" despite working fine from a terminal-launched
/// `tauri dev`, which inherits the terminal's own full PATH. Must run
/// before anything could spawn a pane. Windows doesn't have this problem
/// (PATH comes from the registry regardless of launch method), so this is
/// only ever called under cfg(unix).
///
/// Runs the shell with -i (interactive) as well as -l (login): some PATH
/// setups (e.g. nvm) only run in .zshrc/.bashrc, which plain -l wouldn't
/// source. An interactive shell can print other things to stdout first
/// (MOTD, prompts) — wrapping the $PATH readout in unique markers and
/// extracting just what's between them keeps that noise from corrupting it.
#[cfg(unix)]
fn import_login_shell_path() {
    const START: &str = "__AGMSG_PATH_START__";
    const END: &str = "__AGMSG_PATH_END__";
    let shell = resolve_login_shell();
    log_path_import(&format!("resolved login shell: {shell}"));
    let script = format!("printf '{START}%s{END}' \"$PATH\"");
    let output = match std::process::Command::new(&shell).args(["-ilc", &script]).output() {
        Ok(o) => o,
        Err(e) => {
            let msg = format!("couldn't run login shell ({shell}) to import PATH: {e}");
            eprintln!("warning: {msg}");
            log_path_import(&msg);
            return;
        }
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    // Look for END strictly after START, not just anywhere in stdout — shell
    // startup noise printing the literal END text before our own marker
    // output would otherwise false-match against it.
    let parsed = stdout.find(START).and_then(|s| {
        let after_start = s + START.len();
        stdout[after_start..].find(END).map(|e| &stdout[after_start..after_start + e])
    });
    match parsed {
        Some(path) if !path.is_empty() => {
            log_path_import(&format!("imported PATH: {path}"));
            std::env::set_var("PATH", path);
            let _ = IMPORTED_PATH.set(path.to_string());
        }
        _ => {
            let msg = format!(
                "couldn't parse login shell PATH output from {shell} (stdout: {:?})",
                stdout.trim()
            );
            eprintln!("warning: {msg}");
            log_path_import(&msg);
        }
    }
}

/// Resolves the user's login shell for import_login_shell_path() above.
/// $SHELL isn't reliably set for a Finder/LaunchServices-launched GUI
/// process — confirmed on real hardware: present in the same user's
/// Terminal session, absent (or stale) when the app itself is launched via
/// Finder. `dscl` asks Directory Services directly for the account's
/// configured shell, independent of whatever this process's own
/// environment happens to have inherited. /bin/zsh (macOS's default shell
/// since Catalina) is the last-resort fallback if even that comes up empty.
#[cfg(unix)]
fn resolve_login_shell() -> String {
    if let Ok(s) = std::env::var("SHELL") {
        if !s.is_empty() {
            return s;
        }
    }
    let user = std::env::var("USER").unwrap_or_default();
    if !user.is_empty() {
        if let Ok(output) =
            std::process::Command::new("dscl").args([".", "-read", &format!("/Users/{user}"), "UserShell"]).output()
        {
            if output.status.success() {
                let text = String::from_utf8_lossy(&output.stdout);
                if let Some(shell) = text.trim().strip_prefix("UserShell: ") {
                    if !shell.is_empty() {
                        return shell.to_string();
                    }
                }
            }
        }
    }
    "/bin/zsh".into()
}

/// What to spawn for the free-shell tab (App.tsx's "+" tab and a tab's "Open
/// shell" menu item, unattached to any agent). `args` carries login+
/// interactive flags on unix so the shell sources the user's profile
/// (aliases, PATH additions, prompt) the same way a real terminal window
/// would — plain PTY attachment alone doesn't imply that, since e.g. zsh
/// only treats stdin-is-a-tty as sufficient for *interactive*, not *login*.
/// `home` is the frontend's cwd fallback when the current team has no
/// project dir configured — the frontend's own default-project value always
/// wins when set (koit: cd'ing from $HOME every time is tedious), this is
/// only reached when that's empty. A login shell doesn't cd to $HOME on its
/// own; that's a real terminal app's spawn-time cwd, not shell behavior.
#[derive(Serialize)]
pub struct LoginShellInfo {
    cmd: String,
    args: Vec<String>,
    home: String,
}

#[tauri::command]
fn login_shell() -> LoginShellInfo {
    #[cfg(unix)]
    {
        LoginShellInfo {
            cmd: resolve_login_shell(),
            args: vec!["-il".into()],
            home: std::env::var("HOME").unwrap_or_default(),
        }
    }
    #[cfg(windows)]
    {
        let comspec = std::env::var("ComSpec").unwrap_or_else(|_| "cmd.exe".into());
        let home = std::env::var("USERPROFILE").unwrap_or_default();
        LoginShellInfo { cmd: comspec, args: vec![], home }
    }
}

/// Appends a timestamped line to ~/Library/Logs/agmsg/path-import.log. The
/// only real diagnostic available for import_login_shell_path(): it runs
/// before the webview (and thus DevTools) exists, and its failure mode was
/// otherwise silent — a prior Finder-launch gate failure took a slow
/// back-and-forth to root-cause because all it did on failure was warn to
/// stderr, which nothing launched from Finder is around to see.
#[cfg(unix)]
fn log_path_import(message: &str) {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let dir = std::path::PathBuf::from(home).join("Library/Logs/agmsg");
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    use std::io::Write;
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("path-import.log")) {
        let _ = writeln!(f, "[{now}] {message}");
    }
}

/// Build the application menu in `lang`. macOS derives the default menu's
/// About/Hide/Quit labels from the crate name (which can't contain a space),
/// so we define them explicitly to read "agmsg" (matching productName) and
/// give About the real app icon (macOS only — muda's Windows About dialog
/// ignores AboutMetadata.icon entirely, always showing the OS's own
/// info-bubble glyph; not fixable from here, see issue tracker). The Edit
/// menu's Copy/Paste are also needed for the embedded terminals. All labels
/// come from menu_i18n::t so the whole native menu tracks the app's
/// language selector rather than the OS locale.
fn make_menu(app: &AppHandle, lang: &str) -> tauri::Result<(Menu<Wry>, CheckMenuItem<Wry>, CheckMenuItem<Wry>)> {
    let name = "agmsg";
    let m = |key: &str| menu_i18n::t(lang, "nativeMenu", key, &[]);
    let m_name = |key: &str| menu_i18n::t(lang, "nativeMenu", key, &[("name", name)]);
    let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/icon.png")).ok();
    // This runs again on every language switch (set_menu_language rebuilds
    // the whole menu — Tauri has no per-item relabel API), which used to
    // hardcode both checkboxes back to checked regardless of their actual
    // current state (koit bug report: the checkmark went stale after
    // hiding Team Room, even though the real show/hide behavior was
    // correct). try_state — not state, which panics — since the very
    // FIRST call happens from the initial .menu(...) builder hook, before
    // .manage() has registered either of these yet; true is the correct
    // default for that one call only.
    let team_room_checked = app.try_state::<TeamRoomVisible>().map(|s| s.0.load(Ordering::Relaxed)).unwrap_or(true);
    let user_chat_checked = app.try_state::<UserChatVisible>().map(|s| s.0.load(Ordering::Relaxed)).unwrap_or(true);
    // A single combined string (rather than muda's separate version/
    // short_version fields, which map to different, platform-divergent
    // About-panel slots on macOS vs. a parenthetical suffix on Windows) so
    // both platforms show the exact same text verbatim: "0.1.4 (core
    // 1.1.6)". CARGO_PKG_VERSION is Cargo.toml's own version, always kept
    // in sync with tauri.conf.json/package.json at release time; the core
    // version is whatever AGMSG_CORE_REF this build bundled (agmsg::
    // pinned_core_version — the same source agmsg_core_version_status's
    // "pinned" field reads, so the two can never disagree).
    let version = format!("{} (core {})", env!("CARGO_PKG_VERSION"), agmsg::pinned_core_version());
    let about = PredefinedMenuItem::about(
        app,
        Some(&m_name("about")),
        Some(
            AboutMetadataBuilder::new()
                .name(Some(name.to_string()))
                .version(Some(version))
                .icon(icon)
                .build(),
        ),
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
    // "Show Team Room" / "Show User Chat" toggle the team-room tab and the
    // app-user send/receive panel (chat + composer), respectively, in the
    // frontend. The frontend owns the actual show/hide state; these
    // checkboxes just reflect it and emit a toggle event when clicked.
    // "Pane Layout" duplicates the right-click-tab context menu's Layout
    // submenu (frontend App.tsx) here too — that one works fine but users
    // reported not discovering it, being tucked inside a right-click. The
    // frontend remains the source of truth (this just emits which preset was
    // picked; App.tsx applies it to whichever tab is currently active, and
    // is a no-op on the team room, which has no panes). Zoom In/Out/Actual
    // Size mirror the standard browser-app trio (Cmd+=, Cmd+-, Cmd+0) — see
    // the ZoomLevel handler in run() for the logic.
    let pane_layout_menu = Submenu::with_items(
        app,
        m("paneLayout"),
        true,
        &[
            &MenuItem::with_id(app, PANE_LAYOUT_VERTICAL_ID, m("paneLayoutVertical"), true, None::<&str>)?,
            &MenuItem::with_id(app, PANE_LAYOUT_HORIZONTAL_ID, m("paneLayoutHorizontal"), true, None::<&str>)?,
            &MenuItem::with_id(app, PANE_LAYOUT_TILE_ID, m("paneLayoutTile"), true, None::<&str>)?,
        ],
    )?;
    // Owned locals (not inline in the items array below) so we can hand
    // clones back to the caller — Menu::get()/Submenu::get() only search a
    // menu's OWN direct children, never nested submenus, so app.menu().
    // get(TEAM_ROOM_MENU_ID) can never find an item that lives inside this
    // view_menu; every other call site that needs to flip these checkboxes
    // programmatically (on_menu_event, set_team_room_visible,
    // set_user_chat_visible) holds one of these clones instead of
    // re-searching a tree that doesn't contain them at the level searched.
    let team_room_item =
        CheckMenuItem::with_id(app, TEAM_ROOM_MENU_ID, m("showTeamRoom"), true, team_room_checked, None::<&str>)?;
    let user_chat_item =
        CheckMenuItem::with_id(app, USER_CHAT_MENU_ID, m("showUserChat"), true, user_chat_checked, None::<&str>)?;
    let view_menu = Submenu::with_items(
        app,
        m("viewMenu"),
        true,
        &[
            &team_room_item,
            &user_chat_item,
            &PredefinedMenuItem::separator(app)?,
            &pane_layout_menu,
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
    let menu = Menu::with_items(app, &[&app_menu, &edit_menu, &view_menu, &window_menu])?;
    Ok((menu, team_room_item, user_chat_item))
}

const TEAM_ROOM_MENU_ID: &str = "toggle_team_room";
const USER_CHAT_MENU_ID: &str = "toggle_user_chat";
const ZOOM_IN_ID: &str = "zoom_in";
const ZOOM_OUT_ID: &str = "zoom_out";
const ZOOM_RESET_ID: &str = "zoom_reset";
const CHECK_UPDATES_ID: &str = "check_updates";
const PANE_LAYOUT_VERTICAL_ID: &str = "pane_layout_vertical";
const PANE_LAYOUT_HORIZONTAL_ID: &str = "pane_layout_horizontal";
const PANE_LAYOUT_TILE_ID: &str = "pane_layout_tile";

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
    let (menu, team_room_item, user_chat_item) = make_menu(&app, &lang).map_err(|e| e.to_string())?;
    app.set_menu(menu).map_err(|e| e.to_string())?;
    let checkboxes = app.state::<ViewMenuCheckboxes>();
    *checkboxes.team_room.lock().unwrap() = team_room_item;
    *checkboxes.user_chat.lock().unwrap() = user_chat_item;
    Ok(())
}

/// Called by the frontend when it changes showTeamRoom from a surface OTHER
/// than the View > Show Team Room checkbox itself (the tab's own right-click
/// "Hide Team Room" — see App.tsx) — keeps the native checkbox and
/// TeamRoomVisible in sync with a change the menu didn't originate, the
/// same way clicking the checkbox itself does (see TEAM_ROOM_MENU_ID's
/// on_menu_event handler).
#[tauri::command]
fn set_team_room_visible(app: AppHandle, visible: bool) {
    app.state::<TeamRoomVisible>().0.store(visible, Ordering::Relaxed);
    let _ = app.state::<ViewMenuCheckboxes>().team_room.lock().unwrap().set_checked(visible);
}

/// Same idea as set_team_room_visible, for the chat pane header's own
/// right-click "Hide User Chat" (see App.tsx).
#[tauri::command]
fn set_user_chat_visible(app: AppHandle, visible: bool) {
    app.state::<UserChatVisible>().0.store(visible, Ordering::Relaxed);
    let _ = app.state::<ViewMenuCheckboxes>().user_chat.lock().unwrap().set_checked(visible);
}

/// Rust holds the only durable copy of these two flags — the frontend's
/// own showTeamRoom/showUserChat state defaulted to `true` unconditionally
/// and only ever updated reactively (via the toggle-team-room/toggle-user-
/// chat events below), with no way to ask what the real value currently
/// is. That's invisible on a cold start (both sides agree on `true`), but
/// during `tauri dev` Vite hot-reloads the webview independently of this
/// Rust process — the frontend remounts and its state resets to `true`
/// while Rust (and the menu checkbox) still hold whatever was last set,
/// so the menu checkbox and the actual visible pane silently disagree.
/// The frontend now calls this once on mount to seed its state from here
/// instead of guessing.
#[derive(Serialize)]
pub struct ViewVisibility {
    team_room: bool,
    user_chat: bool,
}

#[tauri::command]
fn view_visibility(app: AppHandle) -> ViewVisibility {
    ViewVisibility {
        team_room: app.state::<TeamRoomVisible>().0.load(Ordering::Relaxed),
        user_chat: app.state::<UserChatVisible>().0.load(Ordering::Relaxed),
    }
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
        // Restores the main window's size/position/maximized state on
        // launch and saves it on move/resize/close — fully automatic, no
        // frontend involvement needed (unlike zoom/view-visibility, which
        // are app-specific state the frontend also reads/writes).
        .plugin(tauri_plugin_window_state::Builder::default().build())
        // Built in English first — the frontend doesn't get a chance to
        // report its actual language until after the webview loads and
        // i18next resolves it, so set_menu_language rebuilds this shortly
        // after startup with the real choice.
        .menu(|app| {
            let (menu, team_room_item, user_chat_item) = make_menu(app, "en")?;
            app.manage(ViewMenuCheckboxes {
                team_room: Mutex::new(team_room_item),
                user_chat: Mutex::new(user_chat_item),
            });
            Ok(menu)
        })
        .manage(TeamRoomVisible(AtomicBool::new(true)))
        .manage(UserChatVisible(AtomicBool::new(true)))
        .manage(ZoomLevel(Mutex::new(1.0)))
        .manage(MenuLanguage(Mutex::new("en".to_string())))
        .on_menu_event(|app, event| {
            let id = event.id().as_ref();
            if id == TEAM_ROOM_MENU_ID {
                let state = app.state::<TeamRoomVisible>();
                let next = !state.0.load(Ordering::Relaxed);
                state.0.store(next, Ordering::Relaxed);
                let _ = app.state::<ViewMenuCheckboxes>().team_room.lock().unwrap().set_checked(next);
                let _ = app.emit("toggle-team-room", next);
            } else if id == USER_CHAT_MENU_ID {
                let state = app.state::<UserChatVisible>();
                let next = !state.0.load(Ordering::Relaxed);
                state.0.store(next, Ordering::Relaxed);
                let _ = app.state::<ViewMenuCheckboxes>().user_chat.lock().unwrap().set_checked(next);
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
            } else if id == PANE_LAYOUT_VERTICAL_ID || id == PANE_LAYOUT_HORIZONTAL_ID || id == PANE_LAYOUT_TILE_ID {
                let layout = match id {
                    _ if id == PANE_LAYOUT_VERTICAL_ID => "vertical",
                    _ if id == PANE_LAYOUT_HORIZONTAL_ID => "horizontal",
                    _ => "tile",
                };
                let _ = app.emit("set-pane-layout", layout);
            } else if id == CHECK_UPDATES_ID {
                let app_handle = app.clone();
                tauri::async_runtime::spawn(async move {
                    check_for_updates(&app_handle, true).await;
                });
            }
        })
        .manage(PtyManager::default())
        .setup(|app| {
            // A Finder/LaunchServices-launched GUI app gets the OS's minimal
            // default PATH, missing anything a login shell adds (Homebrew,
            // ~/.claude/local, etc.) — every agent spawn (pty::pty_spawn)
            // fails with "not found in PATH" despite working fine from a
            // terminal-launched `tauri dev`, which inherits the terminal's
            // full PATH. Must run before anything could spawn a pane.
            // Windows doesn't have this problem (PATH comes from the
            // registry regardless of launch method), hence unix-only.
            #[cfg(unix)]
            import_login_shell_path();

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
            app.state::<PtyManager>().start_detection_tick(app.handle().clone());
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
            pty::agent_state,
            login_shell,
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
            set_team_room_visible,
            set_user_chat_visible,
            view_visibility,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
