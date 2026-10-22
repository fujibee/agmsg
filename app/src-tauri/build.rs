//! Every custom command goes behind an explicit ACL (add-on panes, design 4.1).
//!
//! Tauri gates custom commands only when the app declares an ACL manifest; with
//! the bare `tauri_build::build()` they are open to any *local* origin. The list
//! is read from the `generate_handler!` in `src/lib.rs`, so a new command is
//! gated the moment it is registered. `capabilities/default.json` then has to
//! grant it to the main window; a test (`acl_parity` in `src/lib.rs`) fails when
//! a registered command is not granted or a grant names no command.

use std::fs;

fn registered_commands(lib_rs: &str) -> Vec<String> {
    let start = lib_rs.find("generate_handler![").expect("generate_handler! not found in src/lib.rs") + "generate_handler![".len();
    let end = start + lib_rs[start..].find(']').expect("unterminated generate_handler!");
    lib_rs[start..end]
        .lines()
        .map(|l| l.split("//").next().unwrap_or(""))
        .flat_map(|l| l.split(','))
        .map(|t| t.trim())
        .filter(|t| !t.is_empty())
        .map(|t| t.rsplit("::").next().unwrap().to_string())
        .collect()
}

fn main() {
    println!("cargo:rerun-if-changed=src/lib.rs");
    let lib_rs = fs::read_to_string("src/lib.rs").expect("read src/lib.rs");
    let names: Vec<&'static str> = registered_commands(&lib_rs).into_iter().map(|n| &*Box::leak(n.into_boxed_str())).collect();
    let commands: &'static [&'static str] = Box::leak(names.into_boxed_slice());
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(commands)))
        .expect("tauri build");
}
