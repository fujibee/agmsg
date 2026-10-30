// A cheap fingerprint of everything `api.sh get teams` and `api.sh get teams <team> store` read.
//
// Asking agmsg where each team's store is costs one `bash` per team (plus one for the list), and the
// add-on side needs that answer on every folder it opens. Nothing here starts a process: it only
// stats files. The answer is reused while the fingerprint is the same and asked for again when it
// changes, so a team added or a store moved shows up on the very next look. Anything that cannot
// be stat-ed makes the fingerprint `None`, and the caller then asks agmsg as it always did.
//
// What api.sh reads, traced from scripts/api.sh and scripts/lib/{storage,driver-registry}.sh:
//   get teams            <base>/teams/*/config.json (which directories have one)
//   get teams T store    path   = AGMSG_STORAGE_PATH, else <base>/db, plus the partition driver's
//                                 relative path (shared: messages.db, per-team: teams/T/messages.db)
//                        driver = AGMSG_STORAGE_DRIVER, else "storage" in AGMSG_CONFIG or
//                                 ~/.agents/agmsg/config.json, else sqlite
//                        partition driver of T = "drivers.partition" in <base>/teams/T/config.json,
//                                 found in <base>/scripts/drivers, <base>/plugins and the directories
//                                 listed in <base>/db/plugin-sources (external ones only when named
//                                 in <base>/db/trusted-plugins)
//                        exists = whether that path exists now

use std::fs;
use std::path::{Path, PathBuf};

/// Directory entries looked at below the plugin folders; past this the fingerprint gives up.
const MAX_ENTRIES: usize = 4000;
const PLUGIN_DEPTH: usize = 3;

/// The environment api.sh's answers depend on.
#[derive(Debug, Clone, Default)]
pub struct Env {
    pub storage_path: Option<String>,
    pub storage_driver: Option<String>,
    pub config: Option<String>,
    pub home: Option<String>,
}

impl Env {
    pub fn from_process() -> Env {
        let var = |k: &str| std::env::var(k).ok();
        Env { storage_path: var("AGMSG_STORAGE_PATH"), storage_driver: var("AGMSG_STORAGE_DRIVER"), config: var("AGMSG_CONFIG"), home: var("HOME").or_else(|| var("USERPROFILE")) }
    }
}

/// One file or folder as the fingerprint sees it: absent, or its size, modification time and (where the
/// platform has one) inode, so a file replaced by a rename shows even when size and time happen to match.
fn stat(p: &Path) -> Option<String> {
    match fs::metadata(p) {
        Ok(m) => {
            let mtime = m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_nanos()).unwrap_or(0);
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

/// Names in a folder, sorted. A folder that is not there is an empty list; one that cannot be read is `None`.
fn names(dir: &Path) -> Option<Vec<String>> {
    match fs::read_dir(dir) {
        Ok(rd) => {
            let mut v: Vec<String> = rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
            v.sort();
            Some(v)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(Vec::new()),
        Err(_) => None,
    }
}

/// Every file below `dir` (to `depth` levels) with its stat, appended to `out`.
fn tree(dir: &Path, depth: usize, budget: &mut usize, out: &mut String) -> Option<()> {
    for name in names(dir)? {
        if *budget == 0 {
            return None;
        }
        *budget -= 1;
        let p = dir.join(&name);
        out.push_str(&format!("{}={}\n", p.display(), stat(&p)?));
        if depth > 1 && fs::symlink_metadata(&p).map(|m| m.is_dir()).unwrap_or(false) {
            tree(&p, depth - 1, budget, out)?;
        }
    }
    Some(())
}

/// The part of the fingerprint that does not depend on which stores exist.
pub fn base_part(base: &Path, env: &Env) -> Option<String> {
    let mut out = String::new();
    out.push_str(&format!("base={}\nstorage_path={:?}\nstorage_driver={:?}\nconfig={:?}\nhome={:?}\n", base.display(), env.storage_path, env.storage_driver, env.config, env.home));
    // the machine-wide config that names the storage driver
    let config = match (&env.config, &env.home) {
        (Some(c), _) if !c.is_empty() => PathBuf::from(c),
        (_, Some(h)) => Path::new(h).join(".agents/agmsg/config.json"),
        _ => PathBuf::new(),
    };
    out.push_str(&format!("global_config={}\n", stat(&config)?));
    // which teams exist, and each team's own config (it names the team's partition driver)
    let teams = base.join("teams");
    for name in names(&teams)? {
        out.push_str(&format!("team {name} {}\n", stat(&teams.join(&name).join("config.json"))?));
    }
    // the drivers api.sh can load, and the opt-in that lets an external one load
    let mut budget = MAX_ENTRIES;
    tree(&base.join("scripts/drivers/partition"), 1, &mut budget, &mut out)?;
    tree(&base.join("scripts/drivers/storage"), 1, &mut budget, &mut out)?;
    tree(&base.join("plugins"), PLUGIN_DEPTH, &mut budget, &mut out)?;
    let sources = base.join("db/plugin-sources");
    out.push_str(&format!("plugin_sources={}\ntrusted={}\n", stat(&sources)?, stat(&base.join("db/trusted-plugins"))?));
    if let Ok(text) = fs::read_to_string(&sources) {
        for line in text.lines() {
            let cols: Vec<&str> = line.split('\t').collect();
            if cols.first().is_some_and(|id| id.is_empty() || id.starts_with('#')) {
                continue;
            }
            if let Some(dir) = cols.get(3).map(|d| d.trim_end_matches('\r')).filter(|d| !d.is_empty()) {
                tree(Path::new(dir), PLUGIN_DEPTH, &mut budget, &mut out)?;
            }
        }
    }
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
        fs::create_dir_all(b.join("scripts/drivers/partition")).unwrap();
        fs::write(b.join("scripts/drivers/partition/shared.sh"), "x").unwrap();
        (d, b)
    }

    fn env() -> Env {
        Env { home: Some("/nonexistent-home".into()), ..Env::default() }
    }

    #[test]
    fn the_same_files_give_the_same_fingerprint() {
        let (_d, b) = base();
        assert_eq!(base_part(&b, &env()).unwrap(), base_part(&b, &env()).unwrap());
    }

    #[test]
    fn a_new_team_a_changed_team_config_and_a_moved_driver_each_change_it() {
        let (_d, b) = base();
        let before = base_part(&b, &env()).unwrap();
        fs::create_dir_all(b.join("teams/beta")).unwrap();
        fs::write(b.join("teams/beta/config.json"), "{}").unwrap();
        let with_beta = base_part(&b, &env()).unwrap();
        assert_ne!(before, with_beta, "a team was added");
        fs::write(b.join("teams/alpha/config.json"), r#"{"drivers":{"partition":"per-team"}}"#).unwrap();
        let moved = base_part(&b, &env()).unwrap();
        assert_ne!(with_beta, moved, "a team's config changed (same inode, new size)");
        fs::write(b.join("scripts/drivers/partition/per-team.sh"), "y").unwrap();
        assert_ne!(moved, base_part(&b, &env()).unwrap(), "a partition driver appeared");
    }

    #[test]
    fn a_config_replaced_by_a_rename_changes_it_even_at_the_same_size() {
        let (_d, b) = base();
        let before = base_part(&b, &env()).unwrap();
        fs::write(b.join("teams/alpha/config.json.new"), "{}").unwrap();
        fs::rename(b.join("teams/alpha/config.json.new"), b.join("teams/alpha/config.json")).unwrap();
        #[cfg(unix)]
        assert_ne!(before, base_part(&b, &env()).unwrap());
        #[cfg(not(unix))]
        let _ = before;
    }

    #[test]
    fn the_environment_and_the_global_config_and_the_plugin_folders_are_part_of_it() {
        let (_d, b) = base();
        let plain = base_part(&b, &env()).unwrap();
        let moved = Env { storage_path: Some("/elsewhere".into()), ..env() };
        assert_ne!(plain, base_part(&b, &moved).unwrap());
        let cfg = b.join("global.json");
        let with_cfg = Env { config: Some(cfg.to_string_lossy().into_owned()), ..env() };
        let absent = base_part(&b, &with_cfg).unwrap();
        fs::write(&cfg, r#"{"storage":"jsonl"}"#).unwrap();
        assert_ne!(absent, base_part(&b, &with_cfg).unwrap(), "the storage driver is named there");
        let before = base_part(&b, &env()).unwrap();
        fs::create_dir_all(b.join("plugins/p/partition")).unwrap();
        fs::write(b.join("plugins/p/partition/mine.sh"), "z").unwrap();
        assert_ne!(before, base_part(&b, &env()).unwrap());
        let before = base_part(&b, &env()).unwrap();
        fs::create_dir_all(b.join("db")).unwrap();
        fs::write(b.join("db/trusted-plugins"), "partition/mine\t/x\n").unwrap();
        assert_ne!(before, base_part(&b, &env()).unwrap(), "trusting an external driver");
    }

    #[test]
    fn a_plugin_source_folder_is_followed() {
        let (_d, b) = base();
        let src = tempfile::tempdir().unwrap();
        fs::create_dir_all(b.join("db")).unwrap();
        fs::write(b.join("db/plugin-sources"), format!("id\tspec\trev\t{}\tnow\n", src.path().display())).unwrap();
        let before = base_part(&b, &env()).unwrap();
        fs::create_dir_all(src.path().join("partition")).unwrap();
        fs::write(src.path().join("partition/mine.sh"), "z").unwrap();
        assert_ne!(before, base_part(&b, &env()).unwrap());
    }

    #[test]
    fn a_store_appearing_changes_the_exists_part() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("messages.db");
        let before = exists_part(std::slice::from_ref(&p));
        fs::write(&p, "x").unwrap();
        assert_ne!(before, exists_part(&[p]));
    }

    #[test]
    #[cfg(unix)]
    fn what_cannot_be_read_gives_no_fingerprint() {
        use std::os::unix::fs::PermissionsExt;
        let (_d, b) = base();
        let teams = b.join("teams");
        fs::set_permissions(&teams, fs::Permissions::from_mode(0o000)).unwrap();
        let readable = fs::read_dir(&teams).is_ok(); // running as root can read anything
        let denied = base_part(&b, &env());
        fs::set_permissions(&teams, fs::Permissions::from_mode(0o755)).unwrap();
        if readable {
            return;
        }
        assert!(denied.is_none());
    }
}
