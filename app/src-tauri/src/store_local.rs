// Where each team's store is, worked out in-process: no `bash`, no `api.sh`.
//
// The app needs this answer on every folder it opens and on a timer. Asking agmsg means one `bash` for the
// list of teams and one per team. For the configuration almost everyone has - agmsg's own drivers only -
// the answer is a few path joins, so it is computed here, mirroring scripts/api.sh `get teams` and
// `get teams <team> store` (with scripts/lib/storage.sh, driver-registry.sh, validate.sh and the partition
// drivers):
//   teams   the folders <base>/teams/*/ (not hidden ones) that hold a config.json, sorted by name
//   store   path   = <storage dir>/<messages.db | teams/<team>/messages.db>, by the team's partition driver
//                    ("drivers.partition" in the team's config.json: absent -> shared, or per-team)
//           storage dir = AGMSG_STORAGE_PATH without one trailing slash, else <base>/db
//           driver = AGMSG_STORAGE_DRIVER, else "storage" in AGMSG_CONFIG or ~/.agents/agmsg/config.json,
//                    else sqlite
//           exists = whether that path exists now
//           the team name is checked as scripts/lib/validate.sh checks it
//
// Nothing here is trusted blindly. Every function returns `None` ("ask agmsg") unless
//   - the scripts that decide this are the ones this was checked against: their SHA-256 is in `KNOWN`
//     (a test keeps that list equal to the scripts in this repository, so changing one means looking here),
//   - no driver from outside agmsg could be in play: AGMSG_PLUGIN_DIRS unset, no folder in <base>/plugins,
//     no plugin source listed, the team's partition and the storage driver are ones agmsg ships,
//   - everything read could be read (an error is never taken to mean "nothing there"), and the path
//     spellings are ones a plain join gives (an absolute base without `.` or `..`; not Windows, where the
//     facade turns paths into another form with a process).
// Tests run the real api.sh over each configuration and require the same answer.

use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Component, Path, PathBuf};

/// The scripts that decide the answer, as shipped in agmsg-core v1.7.0 (the core this app pins).
const KNOWN: &[(&str, &str)] = &[
    ("scripts/api.sh", "9d28d3887b5533c392b54a63ea04f022e202b9fc58fcc07b9f4944671bf22879"),
    ("scripts/lib/storage.sh", "36d73fb245b660d08dbdb7a11f37d8c8c40b5d7ce7f4415374200926808bbad5"),
    ("scripts/lib/driver-registry.sh", "3ff118142c0d8d8826003b28b152d71e2ceace6f9732d7f4092893ae086e6f34"),
    ("scripts/lib/validate.sh", "d1bd2a0cdd64596f3605cf0b51e81062a8590976e109d78756eb52b66330b805"),
    ("scripts/drivers/partition/shared.sh", "454ff3b4df0a8c9e1a7fbe286ab783a1599945d3aeb7bd7d0c5fd3bae43f7de3"),
    ("scripts/drivers/partition/per-team.sh", "bcf6fa5e5b70d36a17a9fca166307cd7256a7b988ccb40bae8153185a7f10c52"),
];

/// The storage driver whose answer was checked against the script. The others agmsg ships need more than
/// sqlite3 to load (jsonl needs more tools, sqlite-sync a sync setup): where something is missing api.sh fails
/// without a word, so what it would say is the script's to say, not this.
const STORAGE_DRIVERS: &[&str] = &["sqlite"];

/// The environment api.sh's answers depend on.
#[derive(Debug, Clone, Default)]
pub struct Env {
    pub storage_path: Option<String>,
    pub storage_driver: Option<String>,
    pub config: Option<String>,
    pub plugin_dirs: Option<String>,
    pub home: Option<String>,
}

impl Env {
    pub fn from_process() -> Env {
        let var = |k: &str| std::env::var(k).ok();
        Env { storage_path: var("AGMSG_STORAGE_PATH"), storage_driver: var("AGMSG_STORAGE_DRIVER"), config: var("AGMSG_CONFIG"), plugin_dirs: var("AGMSG_PLUGIN_DIRS"), home: var("HOME").or_else(|| var("USERPROFILE")) }
    }
}

/// What `api.sh get teams <team> store` says that the app uses.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Store {
    pub driver: String,
    pub path: String,
    pub exists: bool,
}

/// A file's SHA-256, read again only when its size, time or inode differ from the last time it was hashed
/// (a handful of small files are checked on every call).
fn content_hash(f: &Path) -> Option<String> {
    static MEMO: std::sync::Mutex<Option<std::collections::HashMap<PathBuf, (String, String)>>> = std::sync::Mutex::new(None);
    let m = fs::metadata(f).ok()?;
    let mtime = m.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_nanos();
    #[cfg(unix)]
    let ino = std::os::unix::fs::MetadataExt::ino(&m);
    #[cfg(not(unix))]
    let ino = 0u64;
    let st = format!("{}:{mtime}:{ino}", m.len());
    if let Some((s, h)) = MEMO.lock().unwrap().as_ref().and_then(|m| m.get(f)) {
        if *s == st {
            return Some(h.clone());
        }
    }
    let h: String = Sha256::digest(&fs::read(f).ok()?).iter().map(|x| format!("{x:02x}")).collect();
    MEMO.lock().unwrap().get_or_insert_with(Default::default).insert(f.to_path_buf(), (st, h.clone()));
    Some(h)
}

/// The text of a file: `Some(None)` when it is not there, `None` when it cannot be read.
fn read(p: &Path) -> Option<Option<String>> {
    match fs::read(p) {
        Ok(b) => Some(Some(String::from_utf8(b).ok()?)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(None),
        Err(_) => None,
    }
}

/// Names in a folder; a folder that is not there is an empty list, one that cannot be listed (or has an entry
/// that cannot be read) is `None`.
fn names(dir: &Path) -> Option<Vec<std::ffi::OsString>> {
    match fs::read_dir(dir) {
        Ok(rd) => {
            let mut v = Vec::new();
            for e in rd {
                v.push(e.ok()?.file_name());
            }
            Some(v)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(Vec::new()),
        Err(_) => None,
    }
}

fn plain_or_absent(p: &Path) -> Option<()> {
    match fs::symlink_metadata(p) {
        Ok(m) if m.file_type().is_symlink() => None,
        Ok(_) => Some(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(()),
        Err(_) => None,
    }
}

/// scripts/lib/validate.sh agmsg_validate_team_name.
fn valid_team_name(n: &str) -> bool {
    !(n.is_empty() || n == "." || n == ".." || n.contains('/') || n.contains('\\') || n.starts_with('-') || n.chars().any(|c| c.is_control()))
}

/// What every answer shares, or `None` when it cannot be vouched for.
struct Setting {
    base: PathBuf,
    storage_dir: String,
    driver: String,
}

fn setting(base: &Path, env: &Env) -> Option<Setting> {
    if cfg!(windows) || env.plugin_dirs.as_deref().is_some_and(|d| !d.is_empty()) {
        return None;
    }
    // an absolute base spelled the way the script's `cd .. && pwd` spells it
    if !base.is_absolute() || base.components().any(|c| matches!(c, Component::CurDir | Component::ParentDir)) {
        return None;
    }
    let base: PathBuf = base.components().collect();
    // the scripts are the ones this was checked against
    for (rel, want) in KNOWN {
        if content_hash(&base.join(rel)).as_deref() != Some(want) {
            return None;
        }
    }
    // no driver from outside agmsg: no folder in plugins (a README is fine), no plugin source
    plain_or_absent(&base.join("plugins"))?;
    for n in names(&base.join("plugins"))? {
        if !fs::symlink_metadata(base.join("plugins").join(n)).ok()?.is_file() {
            return None;
        }
    }
    if let Some(text) = read(&base.join("db/plugin-sources"))? {
        if text.lines().any(|l| !l.trim().is_empty() && !l.starts_with('#')) {
            return None;
        }
    }
    for d in ["scripts/drivers/partition", "scripts/drivers/storage", "scripts/lib", "teams"] {
        plain_or_absent(&base.join(d))?;
    }
    // the storage driver: environment, else the machine-wide config, else sqlite
    let config = match (&env.config, &env.home) {
        (Some(c), _) if !c.is_empty() => PathBuf::from(c),
        (_, Some(h)) => Path::new(h).join(".agents/agmsg/config.json"),
        _ => PathBuf::new(),
    };
    let from_config = if config.as_os_str().is_empty() {
        None
    } else {
        match read(&config)? {
            Some(t) => serde_json::from_str::<serde_json::Value>(&t).ok()?.get("storage").map(|v| v.as_str().map(str::to_string)),
            None => None,
        }
    };
    let driver = match env.storage_driver.as_deref().filter(|d| !d.is_empty()) {
        Some(d) => d.to_string(),
        None => match from_config {
            None | Some(None) => "sqlite".to_string(), // no key, or null
            Some(Some(s)) if s.is_empty() => "sqlite".to_string(),
            Some(Some(s)) => s,
        },
    };
    if !STORAGE_DRIVERS.contains(&driver.as_str()) || !base.join("scripts/drivers/storage").join(format!("{driver}.sh")).is_file() {
        return None;
    }
    let storage_dir = match env.storage_path.as_deref().filter(|p| !p.is_empty()) {
        Some(p) => p.strip_suffix('/').unwrap_or(p).to_string(),
        None => format!("{}/db", base.to_str()?),
    };
    Some(Setting { base, storage_dir, driver })
}

/// `api.sh get teams`: the team names, or `None` to ask agmsg.
pub fn teams(base: &Path, env: &Env) -> Option<Vec<String>> {
    let s = setting(base, env)?;
    let dir = s.base.join("teams");
    let mut out: Vec<String> = Vec::new();
    for n in names(&dir)? {
        let name = n.to_str()?.to_string(); // a name that is not text is for the script
        if name.starts_with('.') {
            continue; // the shell glob does not match hidden folders
        }
        let p = dir.join(&n);
        // `"$teams_dir"/*/` follows a link to a folder; `[ -f config.json ]` follows a link to a file
        match fs::metadata(&p) {
            Ok(m) if m.is_dir() => {}
            Ok(_) => continue,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => return None,
        }
        match fs::metadata(p.join("config.json")) {
            Ok(m) if m.is_file() => out.push(name),
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return None,
        }
    }
    out.sort_by(|a, b| a.as_bytes().cmp(b.as_bytes())); // sqlite's ORDER BY: bytes
    Some(out)
}

/// `api.sh get teams <team> store`: `Some(Err)` is the script's refusal (an invalid name), `None` is "ask agmsg".
pub fn store(base: &Path, env: &Env, team: &str) -> Option<Result<Store, String>> {
    let s = setting(base, env)?;
    if !valid_team_name(team) {
        return Some(Err(format!("agmsg: invalid team name '{team}'")));
    }
    // the team's own choice of partition driver: none, or one agmsg ships
    let partition = match read(&s.base.join("teams").join(team).join("config.json"))? {
        None => String::new(),
        Some(t) => match serde_json::from_str::<serde_json::Value>(&t).ok()?.get("drivers").and_then(|d| d.get("partition")) {
            None | Some(serde_json::Value::Null) => String::new(),
            Some(serde_json::Value::String(p)) => p.clone(),
            Some(_) => return None,
        },
    };
    let (driver_file, rel) = match partition.as_str() {
        "" | "shared" => ("shared", "messages.db".to_string()),
        "per-team" => ("per-team", format!("teams/{team}/messages.db")),
        _ => return None,
    };
    if !s.base.join("scripts/drivers/partition").join(format!("{driver_file}.sh")).is_file() {
        return None;
    }
    let path = format!("{}/{rel}", s.storage_dir);
    let exists = Path::new(&path).exists();
    Some(Ok(Store { driver: s.driver, path, exists }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;
    use std::process::Command;

    /// The scripts this repository ships (the app lives in the same repository as the core it pins).
    fn repo_scripts() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../scripts")
    }

    fn copy_dir(from: &Path, to: &Path) {
        fs::create_dir_all(to).unwrap();
        for e in fs::read_dir(from).unwrap() {
            let e = e.unwrap();
            let t = to.join(e.file_name());
            if e.file_type().unwrap().is_dir() {
                copy_dir(&e.path(), &t);
            } else {
                fs::copy(e.path(), t).unwrap();
            }
        }
    }

    /// An install base with the real scripts, so the real api.sh can be asked as well.
    fn base() -> (tempfile::TempDir, PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let b = d.path().canonicalize().unwrap().join("agmsg");
        copy_dir(&repo_scripts(), &b.join("scripts"));
        fs::create_dir_all(b.join("teams")).unwrap();
        (d, b)
    }

    fn team(b: &Path, name: &str, config: &str) {
        let d = b.join("teams").join(name);
        fs::create_dir_all(&d).unwrap();
        fs::write(d.join("config.json"), config).unwrap();
    }

    fn api(b: &Path, env: &Env, args: &[&str]) -> String {
        let mut c = Command::new("bash");
        c.arg("--noprofile").arg("--norc").arg(b.join("scripts/api.sh")).args(args).env_remove("AGMSG_STORAGE_PATH").env_remove("AGMSG_STORAGE_DRIVER").env_remove("AGMSG_CONFIG").env_remove("AGMSG_PLUGIN_DIRS");
        for (k, v) in [("AGMSG_STORAGE_PATH", &env.storage_path), ("AGMSG_STORAGE_DRIVER", &env.storage_driver), ("AGMSG_CONFIG", &env.config)] {
            if let Some(v) = v {
                c.env(k, v);
            }
        }
        if let Some(h) = &env.home {
            c.env("HOME", h);
        }
        let o = c.output().unwrap();
        String::from_utf8_lossy(&o.stdout).into_owned()
    }

    fn script_teams(b: &Path, env: &Env) -> Vec<String> {
        api(b, env, &["get", "teams"]).lines().filter(|l| !l.trim().is_empty()).map(|l| serde_json::from_str::<serde_json::Value>(l).unwrap()["name"].as_str().unwrap().to_string()).collect()
    }

    fn script_store(b: &Path, env: &Env, team: &str) -> Option<Store> {
        let out = api(b, env, &["get", "teams", team, "store"]);
        let v: serde_json::Value = serde_json::from_str(out.lines().next()?).ok()?;
        Some(Store { driver: v["driver"].as_str()?.into(), path: v["path"].as_str()?.into(), exists: v["exists"].as_bool()? })
    }

    fn env(home: &Path) -> Env {
        Env { home: Some(home.to_string_lossy().into_owned()), ..Env::default() }
    }

    /// Rust and the real script agree on the list of teams and on every team's store.
    fn same_answer(b: &Path, env: &Env) {
        let t = teams(b, env).expect("answered in-process");
        assert_eq!(t, script_teams(b, env), "teams");
        for name in &t {
            let rust = store(b, env, name).expect("answered in-process");
            assert_eq!(rust.ok(), script_store(b, env, name), "store of {name}");
        }
    }

    #[test]
    #[cfg(unix)]
    fn the_scripts_this_was_checked_against_are_the_ones_in_this_repository() {
        for (rel, want) in KNOWN {
            let got = content_hash(&repo_scripts().join("..").join(rel)).unwrap();
            assert_eq!(&got, want, "{rel} changed: check store_local.rs against it, rerun these tests, then update KNOWN");
        }
    }

    #[test]
    #[serial] // runs bash, which another serial test hides by emptying PATH
    #[cfg(unix)]
    fn shared_per_team_and_mixed_teams_give_the_scripts_answer() {
        let (d, b) = base();
        let home = d.path().join("home");
        team(&b, "alpha", "{}");
        team(&b, "beta", r#"{"drivers":{"partition":"per-team"}}"#);
        team(&b, "gamma", r#"{"drivers":{"partition":"shared"}}"#);
        team(&b, "delta", r#"{"drivers":{"partition":null},"agents":{}}"#);
        team(&b, "weird name 'q' ü", "{}");
        same_answer(&b, &env(&home));
        // stores that exist
        fs::create_dir_all(b.join("db/teams/beta")).unwrap();
        fs::write(b.join("db/messages.db"), "x").unwrap();
        fs::write(b.join("db/teams/beta/messages.db"), "x").unwrap();
        same_answer(&b, &env(&home));
        assert!(store(&b, &env(&home), "beta").unwrap().unwrap().exists);
    }

    #[test]
    #[serial] // runs bash, which another serial test hides by emptying PATH
    #[cfg(unix)]
    fn a_storage_path_with_and_without_a_trailing_slash_and_the_storage_driver_named_by_the_environment_or_the_config() {
        let (d, b) = base();
        let home = d.path().join("home");
        team(&b, "alpha", "{}");
        team(&b, "beta", r#"{"drivers":{"partition":"per-team"}}"#);
        let elsewhere = d.path().join("elsewhere");
        fs::create_dir_all(&elsewhere).unwrap();
        fs::write(elsewhere.join("messages.db"), "x").unwrap();
        for sp in [elsewhere.to_string_lossy().into_owned(), format!("{}/", elsewhere.display())] {
            same_answer(&b, &Env { storage_path: Some(sp), ..env(&home) });
        }
        for drv in ["sqlite"] {
            same_answer(&b, &Env { storage_driver: Some(drv.into()), ..env(&home) });
        }
        // named in the machine-wide config instead
        let cfg = d.path().join("config.json");
        for body in [r#"{"storage":"sqlite"}"#, r#"{"storage":""}"#, r#"{"storage":null}"#, r#"{"other":1}"#] {
            fs::write(&cfg, body).unwrap();
            same_answer(&b, &Env { config: Some(cfg.to_string_lossy().into_owned()), ..env(&home) });
        }
    }

    #[test]
    #[serial] // runs bash, which another serial test hides by emptying PATH
    #[cfg(unix)]
    fn what_the_script_skips_or_refuses_is_skipped_or_refused_here() {
        let (d, b) = base();
        let home = d.path().join("home");
        team(&b, "alpha", "{}");
        team(&b, ".hidden", "{}"); // a shell glob skips it
        fs::create_dir_all(b.join("teams/no-config")).unwrap();
        fs::write(b.join("teams/a-file"), "x").unwrap();
        team(&b, "-dash", "{}"); // refused by the name check
        std::os::unix::fs::symlink(b.join("teams/alpha"), b.join("teams/linked")).unwrap();
        let e = env(&home);
        let t = teams(&b, &e).unwrap();
        assert_eq!(t, script_teams(&b, &e));
        assert!(!t.contains(&".hidden".to_string()) && !t.contains(&"no-config".to_string()) && t.contains(&"linked".to_string()), "{t:?}");
        for name in &t {
            assert_eq!(store(&b, &e, name).unwrap().ok(), script_store(&b, &e, name), "{name}");
        }
        assert!(store(&b, &e, "-dash").unwrap().is_err(), "an invalid name is refused as the script refuses it");
        for bad in ["", ".", "..", "a/b", "a\\b", "x\ty"] {
            assert!(store(&b, &e, bad).unwrap().is_err(), "{bad:?}");
        }
        // a name that is not a team at all still gets the answer the script gives
        assert_eq!(store(&b, &e, "nobody").unwrap().ok(), script_store(&b, &e, "nobody"));
        // no teams folder
        fs::remove_dir_all(b.join("teams")).unwrap();
        assert_eq!(teams(&b, &e).unwrap(), script_teams(&b, &e));
    }

    #[test]
    #[cfg(unix)]
    fn anything_not_known_to_be_the_same_is_left_to_the_script() {
        let (d, b) = base();
        let e = env(&d.path().join("home"));
        team(&b, "alpha", "{}");
        assert!(teams(&b, &e).is_some() && store(&b, &e, "alpha").is_some());
        // a team on a partition driver agmsg does not ship, or a config that is not JSON, for that team only
        team(&b, "ext", r#"{"drivers":{"partition":"mine"}}"#);
        assert!(store(&b, &e, "ext").is_none());
        assert!(store(&b, &e, "alpha").is_some());
        team(&b, "broken", "{not json");
        assert!(store(&b, &e, "broken").is_none());
        // AGMSG_PLUGIN_DIRS, a plugin folder, a listed plugin source, an unshipped storage driver
        assert!(store(&b, &Env { plugin_dirs: Some("/x".into()), ..e.clone() }, "alpha").is_none());
        assert!(store(&b, &Env { storage_driver: Some("mine".into()), ..e.clone() }, "alpha").is_none());
        for other in ["jsonl", "sqlite-sync"] {
            assert!(store(&b, &Env { storage_driver: Some(other.into()), ..e.clone() }, "alpha").is_none(), "{other} needs more than this checks");
        }
        fs::create_dir_all(b.join("plugins")).unwrap();
        fs::write(b.join("plugins/README.md"), "docs").unwrap();
        assert!(store(&b, &e, "alpha").is_some(), "a plain file in plugins is not a driver");
        fs::create_dir_all(b.join("plugins/p/partition")).unwrap();
        assert!(teams(&b, &e).is_none() && store(&b, &e, "alpha").is_none());
        fs::remove_dir_all(b.join("plugins/p")).unwrap();
        fs::create_dir_all(b.join("db")).unwrap();
        fs::write(b.join("db/plugin-sources"), "id\tspec\trev\t/x\tnow\n").unwrap();
        assert!(teams(&b, &e).is_none());
        fs::remove_file(b.join("db/plugin-sources")).unwrap();
        assert!(teams(&b, &e).is_some());
        // a base that is not spelled the plain way
        assert!(teams(&b.join("../agmsg"), &e).is_none());
        assert!(teams(Path::new("relative/base"), &e).is_none());
        // resolution code that is not the code this was checked against, in every file that matters
        for (rel, _) in KNOWN {
            let p = b.join(rel);
            let old = fs::read_to_string(&p).unwrap();
            fs::write(&p, format!("{old}\n# changed\n")).unwrap();
            assert!(teams(&b, &e).is_none(), "{rel}");
            assert!(store(&b, &e, "alpha").is_none(), "{rel}");
            fs::write(&p, old).unwrap();
            assert!(teams(&b, &e).is_some(), "{rel} restored");
        }
    }

    #[test]
    #[cfg(unix)]
    fn what_cannot_be_read_or_is_a_link_is_left_to_the_script() {
        use std::os::unix::fs::PermissionsExt;
        let (d, b) = base();
        let e = env(&d.path().join("home"));
        team(&b, "alpha", "{}");
        let cfg = b.join("teams/alpha/config.json");
        fs::set_permissions(&cfg, fs::Permissions::from_mode(0o000)).unwrap();
        let readable = fs::read(&cfg).is_ok(); // running as root can read anything
        let got = store(&b, &e, "alpha");
        fs::set_permissions(&cfg, fs::Permissions::from_mode(0o644)).unwrap();
        if !readable {
            assert!(got.is_none(), "an unreadable team config is not 'no config'");
        }
        let teams_dir = b.join("teams");
        fs::set_permissions(&teams_dir, fs::Permissions::from_mode(0o000)).unwrap();
        let readable = fs::read_dir(&teams_dir).is_ok();
        let got = teams(&b, &e);
        fs::set_permissions(&teams_dir, fs::Permissions::from_mode(0o755)).unwrap();
        if !readable {
            assert!(got.is_none());
        }
        let lib = b.join("scripts/lib");
        let moved = b.join("scripts/lib-real");
        fs::rename(&lib, &moved).unwrap();
        std::os::unix::fs::symlink(&moved, &lib).unwrap();
        assert!(teams(&b, &e).is_none(), "a resolution folder that is a link");
    }
}
