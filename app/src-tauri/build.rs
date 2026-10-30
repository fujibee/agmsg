//! Every custom command goes behind an explicit ACL (add-on panes, design 4.1).
//!
//! Tauri gates custom commands only when the app declares an ACL manifest; with
//! the bare `tauri_build::build()` they are open to any *local* origin. The list
//! is read from the `generate_handler!` in `src/lib.rs`, so a new command is
//! gated the moment it is registered. `capabilities/default.json` then has to
//! grant it to the main window; a test (`acl_parity` in `src/lib.rs`) fails when
//! a registered command is not granted or a grant names no command.

use std::fs;
use std::path::Path;

// The same digest the app computes when it opens a built-in add-on.
#[path = "src/addons/digest.rs"]
#[allow(dead_code)]
mod digest;

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

/// `src/builtin_digests.rs`: `(name, digest)` for every folder under `../addons`
/// that has an `app-panes/` (the built-in add-ons, shipped as app resources).
fn write_builtin_digests() {
    println!("cargo:rerun-if-changed=../addons");
    let root = Path::new("../addons");
    let mut rows: Vec<(String, String)> = Vec::new();
    if let Ok(rd) = fs::read_dir(root) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with('_') || name.starts_with('.') {
                continue;
            }
            let panes = e.path().join("app-panes");
            if panes.is_dir() {
                let d = digest::payload_digest(&panes).unwrap_or_else(|err| panic!("cannot hash built-in add-on {name}: {err}"));
                rows.push((name, d));
            }
        }
    }
    rows.sort();
    let mut out = String::from("pub const BUILTIN_DIGESTS: &[(&str, &str)] = &[\n");
    for (n, d) in rows {
        out.push_str(&format!("    ({n:?}, {d:?}),\n"));
    }
    out.push_str("];\n");
    let dest = Path::new(&std::env::var("OUT_DIR").expect("OUT_DIR")).join("builtin_digests.rs");
    fs::write(dest, out).expect("write builtin_digests.rs");
}

fn main() {
    write_builtin_digests();
    println!("cargo:rerun-if-changed=src/lib.rs");
    let lib_rs = fs::read_to_string("src/lib.rs").expect("read src/lib.rs");
    let names: Vec<&'static str> = registered_commands(&lib_rs).into_iter().map(|n| &*Box::leak(n.into_boxed_str())).collect();
    let commands: &'static [&'static str] = Box::leak(names.into_boxed_slice());
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(commands)))
        .expect("tauri build");
}
