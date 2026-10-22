// M1 spike: M1_VARIANT selects the ACL shape under test.
//   none   (default) bare tauri_build::build(), as on main
//   acl    explicit AppManifest::commands, granted to the main UI only
//   remote acl plus a remote capability that allows the loopback origin to call addon_canary
fn main() {
    println!("cargo:rerun-if-env-changed=M1_VARIANT");
    let cmds: &[&str] = &[
        "pty_spawn", "pty_write", "pty_resize", "pty_kill", "pty_inject", "agent_state",
        "login_shell", "agmsg_is_installed", "agmsg_install", "agmsg_core_version_status",
        "agmsg_update_core", "agmsg_teams", "agmsg_members", "agmsg_messages", "agmsg_send",
        "agmsg_join", "agmsg_rename", "agmsg_leave", "agmsg_rename_team", "agmsg_delete_team",
        "agmsg_delete_team_force", "agmsg_purge_team_messages", "agmsg_delivery_mode",
        "agmsg_default_project", "agmsg_command_name", "agmsg_spawnable_types",
        "set_menu_language", "set_team_room_visible", "set_user_chat_visible", "view_visibility",
        "addon_canary", "addon_channel_feed",
    ];
    let variant = std::env::var("M1_VARIANT").unwrap_or_else(|_| "none".into());
    println!("cargo:rustc-env=M1_VARIANT={variant}");
    match variant.as_str() {
        "acl" => tauri_build::try_build(
            tauri_build::Attributes::new()
                .capabilities_path_pattern("./capabilities-m1-acl/**/*")
                .app_manifest(tauri_build::AppManifest::new().commands(cmds)),
        )
        .unwrap(),
        "remote" => tauri_build::try_build(
            tauri_build::Attributes::new()
                .capabilities_path_pattern("./capabilities-m1-remote/**/*")
                .app_manifest(tauri_build::AppManifest::new().commands(cmds)),
        )
        .unwrap(),
        _ => tauri_build::build(),
    }
}
