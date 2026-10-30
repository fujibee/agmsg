// A fingerprint of everything `api.sh get teams` and `api.sh get teams <team> store` read, for the
// one situation where that can be known: only agmsg's own built-in drivers are in play.
//
// Asking agmsg where each team's store is costs one `bash` per team (plus one for the list), and the
// add-on side needs that answer on every folder it opens. Nothing here starts a process. The answer is
// reused while the fingerprint is the same and asked for again when it changes, so a team added or a
// store moved shows up on the very next look.
//
// `base_part` returns `None` ("do not keep an answer; ask agmsg") whenever it cannot vouch for the
// inputs, which is the safe direction. That is the case when
//   - a driver outside agmsg's own could be in play: AGMSG_PLUGIN_DIRS is set, <base>/plugins has
//     anything in it, <base>/db/plugin-sources lists a source, a team's partition or the storage
//     driver is anything but a built-in one (an external driver is arbitrary shell and may read any
//     config or environment, so no list of files covers it);
//   - anything the fingerprint reads cannot be read, a folder entry cannot be listed, or a modification
//     time cannot be taken (an error is never taken to mean "nothing there");
//   - a folder the driver search reads is a link (where it leads is not what is being looked at).
//
// What api.sh reads, traced from scripts/api.sh and scripts/lib/{storage,driver-registry}.sh:
//   get teams            <base>/teams/*/config.json (which directories have one)
//   get teams T store    path   = AGMSG_STORAGE_PATH, else <base>/db, plus the partition driver's
//                                 relative path (shared: messages.db, per-team: teams/T/messages.db)
//                        driver = AGMSG_STORAGE_DRIVER, else "storage" in AGMSG_CONFIG or
//                                 ~/.agents/agmsg/config.json, else sqlite
//                        partition driver of T = "drivers.partition" in <base>/teams/T/config.json
//                        exists = whether that path exists now
// and the code that does it: api.sh, scripts/lib/*.sh and the built-in drivers, identified by content.

use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};

/// The partition drivers agmsg ships; a team may name only these (or none) for its answer to be kept.
const BUILTIN_PARTITIONS: &[&str] = &["shared", "per-team"];

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

/// A file or folder as the fingerprint sees it: absent, or size, modification time and (where the
/// platform has one) inode, so a file replaced by a rename shows even when size and time happen to match.
/// A time that cannot be taken, or any error but "not found", is `None`.
fn stat(p: &Path) -> Option<String> {
    match fs::metadata(p) {
        Ok(m) => {
            let mtime = m.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_nanos();
            #[cfg(unix)]
            let ino = std::os::unix::fs::MetadataExt::ino(&m);
            #[cfg(not(unix))]
            let ino = 0u64;
            Some(format!("{}:{mtime}:{ino}", m.len()))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some("-".into()),
        Err(_) => None,
    }
}

/// Names in a folder, sorted. A folder that is not there is an empty list; one that cannot be listed,
/// or has an entry that cannot be read, is `None`.
fn names(dir: &Path) -> Option<Vec<String>> {
    match fs::read_dir(dir) {
        Ok(rd) => {
            let mut v = Vec::new();
            for e in rd {
                v.push(e.ok()?.file_name().to_string_lossy().into_owned());
            }
            v.sort();
            Some(v)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(Vec::new()),
        Err(_) => None,
    }
}

/// A folder the driver search reads must be a real folder (or absent), not a link.
fn plain_dir(p: &Path) -> Option<()> {
    match fs::symlink_metadata(p) {
        Ok(m) if m.file_type().is_symlink() => None,
        Ok(_) => Some(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(()),
        Err(_) => None,
    }
}

/// The text of a file, `Ok(None)` when it is not there, `None` when it cannot be read.
fn read(p: &Path) -> Option<Option<String>> {
    match fs::read(p) {
        Ok(b) => Some(Some(String::from_utf8(b).ok()?)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(None),
        Err(_) => None,
    }
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// SHA-256 of a file, read again only when its size, time or inode differ from the last time it was hashed
/// (about a hundred small files are looked at on every call; reading them all each time is the cost this
/// whole cache exists to avoid).
fn content_hash(f: &Path, st: &str) -> Option<String> {
    static MEMO: std::sync::Mutex<Option<std::collections::HashMap<PathBuf, (String, String)>>> = std::sync::Mutex::new(None);
    if let Some((s, h)) = MEMO.lock().unwrap().as_ref().and_then(|m| m.get(f)) {
        if s == st {
            return Some(h.clone());
        }
    }
    let h = hex(&Sha256::digest(&fs::read(f).ok()?));
    MEMO.lock().unwrap().get_or_insert_with(Default::default).insert(f.to_path_buf(), (st.to_string(), h.clone()));
    Some(h)
}

/// `path size:mtime:inode sha256` for each `.sh` / `api.sh` file the resolution runs, in a fixed order.
fn code(base: &Path, out: &mut String) -> Option<()> {
    let scripts = base.join("scripts");
    let mut files = vec![scripts.join("api.sh")];
    for dir in ["lib", "drivers/partition", "drivers/storage"] {
        let d = scripts.join(dir);
        plain_dir(&d)?;
        for n in names(&d)? {
            files.push(d.join(n));
        }
    }
    plain_dir(&scripts.join("drivers"))?;
    for f in files {
        if f.is_dir() {
            continue;
        }
        let st = stat(&f)?;
        out.push_str(&format!("{} {st} {}\n", f.display(), content_hash(&f, &st)?));
    }
    Some(())
}

/// The part of the fingerprint that does not depend on which stores exist. `None`: do not keep an answer.
pub fn base_part(base: &Path, env: &Env) -> Option<String> {
    if env.plugin_dirs.as_deref().is_some_and(|d| !d.is_empty()) {
        return None;
    }
    let mut out = String::new();
    out.push_str(&format!("base={}\nstorage_path={:?}\nstorage_driver={:?}\nconfig={:?}\nhome={:?}\n", base.display(), env.storage_path, env.storage_driver, env.config, env.home));
    // no driver from outside agmsg: no plugin folder content, no plugin source
    plain_dir(&base.join("plugins"))?;
    // plain files in it (the README agmsg ships there) are not drivers; any folder could hold one
    let plugins = base.join("plugins");
    for n in names(&plugins)? {
        if !fs::symlink_metadata(plugins.join(n)).ok()?.is_file() {
            return None;
        }
    }
    let sources = base.join("db/plugin-sources");
    if let Some(text) = read(&sources)? {
        if text.lines().any(|l| !l.trim().is_empty() && !l.starts_with('#')) {
            return None;
        }
    }
    // the storage driver: from the environment, else the machine-wide config, else sqlite; a built-in one
    let config = match (&env.config, &env.home) {
        (Some(c), _) if !c.is_empty() => PathBuf::from(c),
        (_, Some(h)) => Path::new(h).join(".agents/agmsg/config.json"),
        _ => PathBuf::new(),
    };
    let config_text = if config.as_os_str().is_empty() { None } else { read(&config)? };
    out.push_str(&format!("global_config={} {:?}\n", stat(&config)?, config_text));
    let storage = match env.storage_driver.as_deref().filter(|d| !d.is_empty()) {
        Some(d) => d.to_string(),
        None => match &config_text {
            Some(t) => serde_json::from_str::<serde_json::Value>(t).ok()?.get("storage").and_then(|v| v.as_str()).filter(|s| !s.is_empty()).unwrap_or("sqlite").to_string(),
            None => "sqlite".to_string(),
        },
    };
    if storage.is_empty() || !storage.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') || !base.join("scripts/drivers/storage").join(format!("{storage}.sh")).is_file() {
        return None;
    }
    // which teams exist, and the partition driver each names: absent, or a built-in one
    let teams = base.join("teams");
    plain_dir(&teams)?;
    for name in names(&teams)? {
        let cfg = teams.join(&name).join("config.json");
        let text = read(&cfg)?;
        if let Some(t) = &text {
            let v: serde_json::Value = serde_json::from_str(t).ok()?;
            match v.get("drivers").and_then(|d| d.get("partition")) {
                None | Some(serde_json::Value::Null) => {}
                Some(serde_json::Value::String(s)) if s.is_empty() || BUILTIN_PARTITIONS.contains(&s.as_str()) => {}
                Some(_) => return None,
            }
        }
        out.push_str(&format!("team {name} {} {:?}\n", stat(&cfg)?, text.as_deref().map(|t| hex(&Sha256::digest(t.as_bytes())))));
    }
    // the code that resolves it
    code(base, &mut out)?;
    Some(out)
}

/// Whether each store path exists right now (the `exists` field of the answer follows it).
pub fn exists_part(paths: &[PathBuf]) -> String {
    paths.iter().map(|p| format!("{}={}\n", p.display(), p.exists())).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> (tempfile::TempDir, PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let b = d.path().to_path_buf();
        fs::create_dir_all(b.join("teams/alpha")).unwrap();
        fs::write(b.join("teams/alpha/config.json"), "{}").unwrap();
        for dir in ["lib", "drivers/partition", "drivers/storage"] {
            fs::create_dir_all(b.join("scripts").join(dir)).unwrap();
        }
        fs::write(b.join("scripts/api.sh"), "api").unwrap();
        fs::write(b.join("scripts/lib/storage.sh"), "s").unwrap();
        fs::write(b.join("scripts/lib/driver-registry.sh"), "r").unwrap();
        fs::write(b.join("scripts/drivers/partition/shared.sh"), "x").unwrap();
        fs::write(b.join("scripts/drivers/partition/per-team.sh"), "y").unwrap();
        fs::write(b.join("scripts/drivers/storage/sqlite.sh"), "q").unwrap();
        (d, b)
    }

    fn env() -> Env {
        Env { home: Some("/nonexistent-home".into()), ..Env::default() }
    }

    fn fp(b: &Path) -> String {
        base_part(b, &env()).unwrap()
    }

    #[test]
    fn the_same_files_give_the_same_fingerprint() {
        let (_d, b) = base();
        assert_eq!(fp(&b), fp(&b));
    }

    #[test]
    fn a_new_team_and_a_changed_team_config_each_change_it() {
        let (_d, b) = base();
        let before = fp(&b);
        fs::create_dir_all(b.join("teams/beta")).unwrap();
        fs::write(b.join("teams/beta/config.json"), "{}").unwrap();
        let with_beta = fp(&b);
        assert_ne!(before, with_beta, "a team was added");
        fs::write(b.join("teams/alpha/config.json"), r#"{"drivers":{"partition":"per-team"}}"#).unwrap();
        assert_ne!(with_beta, fp(&b), "a team moved to its own store");
    }

    #[test]
    fn a_config_rewritten_at_the_same_size_and_time_still_changes_it() {
        let (_d, b) = base();
        let cfg = b.join("teams/alpha/config.json");
        fs::write(&cfg, r#"{"note":"1"}"#).unwrap();
        let before = fp(&b);
        let mtime = fs::metadata(&cfg).unwrap().modified().unwrap();
        fs::write(&cfg, r#"{"note":"2"}"#).unwrap();
        fs::OpenOptions::new().write(true).open(&cfg).unwrap().set_modified(mtime).unwrap();
        assert_ne!(before, fp(&b));
    }

    #[test]
    fn the_code_that_resolves_is_part_of_it_by_size_time_inode_and_content() {
        let (_d, b) = base();
        for f in ["scripts/api.sh", "scripts/lib/driver-registry.sh", "scripts/lib/storage.sh", "scripts/drivers/partition/per-team.sh", "scripts/drivers/storage/sqlite.sh"] {
            let before = fp(&b);
            let p = b.join(f);
            let len = fs::metadata(&p).unwrap().len() as usize;
            fs::write(&p, "z".repeat(len)).unwrap(); // same size, new time
            fs::OpenOptions::new().write(true).open(&p).unwrap().set_modified(std::time::SystemTime::now() + std::time::Duration::from_secs(5)).unwrap();
            assert_ne!(before, fp(&b), "{f}");
        }
        let before = fp(&b);
        fs::write(b.join("scripts/lib/new.sh"), "n").unwrap();
        assert_ne!(before, fp(&b), "a new resolution file");
    }

    #[test]
    fn the_environment_and_the_global_config_are_part_of_it() {
        let (_d, b) = base();
        let plain = fp(&b);
        let moved = Env { storage_path: Some("/elsewhere".into()), ..env() };
        assert_ne!(plain, base_part(&b, &moved).unwrap());
        let cfg = b.join("global.json");
        let with_cfg = Env { config: Some(cfg.to_string_lossy().into_owned()), ..env() };
        let absent = base_part(&b, &with_cfg).unwrap();
        fs::write(&cfg, r#"{"storage":"sqlite"}"#).unwrap();
        assert_ne!(absent, base_part(&b, &with_cfg).unwrap());
    }

    #[test]
    fn nothing_is_kept_when_a_driver_from_outside_agmsg_could_be_in_play() {
        let (_d, b) = base();
        assert!(base_part(&b, &Env { plugin_dirs: Some("/some/dir".into()), ..env() }).is_none(), "AGMSG_PLUGIN_DIRS");
        assert!(base_part(&b, &Env { storage_driver: Some("mine".into()), ..env() }).is_none(), "a storage driver agmsg does not ship");
        let cfg = b.join("global.json");
        fs::write(&cfg, r#"{"storage":"custom"}"#).unwrap();
        assert!(base_part(&b, &Env { config: Some(cfg.to_string_lossy().into_owned()), ..env() }).is_none(), "named in the machine-wide config");
        fs::write(b.join("teams/alpha/config.json"), r#"{"drivers":{"partition":"mine"}}"#).unwrap();
        assert!(base_part(&b, &env()).is_none(), "a team on a partition driver agmsg does not ship");
        fs::write(b.join("teams/alpha/config.json"), "{}").unwrap();
        assert!(base_part(&b, &env()).is_some());
        fs::create_dir_all(b.join("plugins")).unwrap();
        fs::write(b.join("plugins/README.md"), "docs").unwrap();
        assert!(base_part(&b, &env()).is_some(), "a plain file in plugins is not a driver");
        fs::create_dir_all(b.join("plugins/p/partition")).unwrap();
        assert!(base_part(&b, &env()).is_none(), "a plugin folder");
        fs::remove_dir_all(b.join("plugins/p")).unwrap();
        assert!(base_part(&b, &env()).is_some());
        fs::create_dir_all(b.join("db")).unwrap();
        fs::write(b.join("db/plugin-sources"), "# none\n").unwrap();
        assert!(base_part(&b, &env()).is_some(), "an empty source list");
        fs::write(b.join("db/plugin-sources"), "id\tspec\trev\t/x\tnow\n").unwrap();
        assert!(base_part(&b, &env()).is_none(), "a listed source");
    }

    #[test]
    fn a_broken_team_config_gives_no_fingerprint() {
        let (_d, b) = base();
        fs::write(b.join("teams/alpha/config.json"), "{not json").unwrap();
        assert!(base_part(&b, &env()).is_none());
    }

    #[test]
    #[cfg(unix)]
    fn what_cannot_be_read_or_is_a_link_gives_no_fingerprint() {
        use std::os::unix::fs::PermissionsExt;
        let (_d, b) = base();
        let teams = b.join("teams");
        fs::set_permissions(&teams, fs::Permissions::from_mode(0o000)).unwrap();
        let readable = fs::read_dir(&teams).is_ok(); // running as root can read anything
        let denied = base_part(&b, &env());
        fs::set_permissions(&teams, fs::Permissions::from_mode(0o755)).unwrap();
        if !readable {
            assert!(denied.is_none());
        }
        let cfg = b.join("teams/alpha/config.json");
        fs::set_permissions(&cfg, fs::Permissions::from_mode(0o000)).unwrap();
        let readable = fs::read(&cfg).is_ok();
        let denied = base_part(&b, &env());
        fs::set_permissions(&cfg, fs::Permissions::from_mode(0o644)).unwrap();
        if !readable {
            assert!(denied.is_none(), "an unreadable team config is not 'no config'");
        }
        let real = b.join("scripts/lib");
        let moved = b.join("scripts/lib-real");
        fs::rename(&real, &moved).unwrap();
        std::os::unix::fs::symlink(&moved, &real).unwrap();
        assert!(base_part(&b, &env()).is_none(), "the resolution code folder is a link");
    }

    #[test]
    fn a_store_appearing_changes_the_exists_part() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("messages.db");
        let before = exists_part(std::slice::from_ref(&p));
        fs::write(&p, "x").unwrap();
        assert_ne!(before, exists_part(&[p]));
    }
}
