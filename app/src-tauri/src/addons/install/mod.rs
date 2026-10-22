//! Install pipeline for add-ons (design 3.1): checked extraction, layout and
//! tree checks, staging, atomic activation. Network access lives in `github` only.
//!
//! `check_all` is the Rust twin of `npx agmsg addon check` (`collect` in
//! `bin/addon.js`); `app/addon-kit/fixtures/install-cases.json` is run against
//! both so an author sees before pushing exactly what the app refuses after.

pub mod extract;
pub mod github;
pub mod grants;
pub mod layout;
pub mod stage;
pub mod tree;
pub mod update;

#[cfg(test)]
pub(crate) mod testutil;

use std::path::Path;

use extract::Limits;
use layout::LayoutReport;

/// All findings that make the app refuse an extracted tree or a developer
/// folder: layout and `addon.conf` problems first, then tree problems (links,
/// reserved names, case collisions, limits). With no `app-panes/` at all the
/// tree is not looked at, like the CLI.
pub fn check_all(root: &Path, limits: Limits) -> (Vec<String>, LayoutReport) {
    let layout = layout::check_layout(root);
    let mut errors = layout.errors.clone();
    if layout.no_app_panes {
        return (errors, layout);
    }
    let files = tree::list_files(root);
    errors.extend(tree::check_tree(root, &files, limits).errors);
    (errors, layout)
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::testutil::{content, tarball};
    use extract::{extract_tar_gz, InstallErrorKind};
    use serde_json::Value;
    use std::fs;
    use std::io::Write;

    const CORPUS: &str = include_str!("../../../../addon-kit/fixtures/install-cases.json");

    fn limits_of(c: &Value) -> Limits {
        let mut l = Limits::default();
        if let Some(o) = c.get("limits") {
            if let Some(v) = o.get("totalBytes").and_then(Value::as_u64) {
                l.total_bytes = v;
            }
            if let Some(v) = o.get("files").and_then(Value::as_u64) {
                l.files = v as usize;
            }
            if let Some(v) = o.get("fileBytes").and_then(Value::as_u64) {
                l.file_bytes = v;
            }
        }
        l
    }

    #[cfg(unix)]
    fn materialize(dir: &Path, entries: &[Value]) {
        for e in entries {
            let path = e["path"].as_str().unwrap();
            let abs = dir.join(path);
            fs::create_dir_all(abs.parent().unwrap()).unwrap();
            match e["type"].as_str().unwrap() {
                "file" => fs::write(&abs, content(e)).unwrap(),
                "symlink" => std::os::unix::fs::symlink(e["target"].as_str().unwrap(), &abs).unwrap(),
                "hardlink" => fs::hard_link(dir.join(e["of"].as_str().unwrap()), &abs).unwrap(),
                t => panic!("unsupported fixture type {t}"),
            }
        }
    }

    #[cfg(unix)]
    #[test]
    fn the_shared_corpus_directory_checks_match_the_cli() {
        let corpus: Value = serde_json::from_str(CORPUS).unwrap();
        let mut ran = 0;
        for c in corpus["cases"].as_array().unwrap() {
            if c.get("archiveOnly").and_then(Value::as_bool).unwrap_or(false) {
                continue;
            }
            let tmp = tempfile::tempdir().unwrap();
            materialize(tmp.path(), c["entries"].as_array().unwrap());
            let (mut got, _) = check_all(tmp.path(), limits_of(c));
            got.sort();
            let mut want: Vec<String> = c["expect"]["errors"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect();
            want.sort();
            assert_eq!(got, want, "case {:?}", c["name"]);
            ran += 1;
        }
        assert!(ran >= 20, "{ran}");
    }

    #[cfg(unix)]
    #[test]
    fn the_shared_corpus_archive_extraction_refuses_the_same_things() {
        let corpus: Value = serde_json::from_str(CORPUS).unwrap();
        let mut ran = 0;
        for c in corpus["cases"].as_array().unwrap() {
            let entries = c["entries"].as_array().unwrap();
            let tar = tarball(entries);
            let tmp = tempfile::tempdir().unwrap();
            let r = extract_tar_gz(&tar[..], tmp.path(), limits_of(c));
            let name = c["name"].as_str().unwrap();
            match &c["extract"] {
                Value::String(s) if s == "ok" => {
                    r.unwrap_or_else(|e| panic!("{name}: extraction refused: {e}"));
                    // what extraction lets through must then pass the same layout/tree checks as the CLI
                    let (mut got, _) = check_all(tmp.path(), limits_of(c));
                    got.sort();
                    let mut want: Vec<String> = c["expect"]["errors"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect();
                    want.sort();
                    assert_eq!(got, want, "{name}: after extraction");
                }
                x => {
                    let err = r.expect_err(name);
                    if let Some(exact) = x.get("error").and_then(Value::as_str) {
                        assert_eq!(err.message, exact, "{name}");
                    }
                    for needle in x.get("contains").and_then(Value::as_array).into_iter().flatten() {
                        assert!(err.message.contains(needle.as_str().unwrap()), "{name}: {:?} lacks {needle}", err.message);
                    }
                    assert!(matches!(err.kind, InstallErrorKind::UnsafeEntry | InstallErrorKind::TooLarge), "{name}: {:?}", err.kind);
                }
            }
            ran += 1;
        }
        assert!(ran >= 30, "{ran}");
    }

    #[test]
    fn nothing_is_written_outside_the_staging_folder() {
        // a hostile archive: the refusal comes before any write outside `dest`
        let tmp = tempfile::tempdir().unwrap();
        let dest = tmp.path().join("stage");
        fs::create_dir_all(&dest).unwrap();
        let entries: Vec<Value> = serde_json::from_str(
            r#"[{"path":"app-panes/x/addon.conf","type":"file","text":"title=X\nprotocol=1\n"},
                {"path":"../../escaped.txt","type":"file","text":"EVIL"}]"#,
        )
        .unwrap();
        let tar = tarball(&entries);
        assert!(extract_tar_gz(&tar[..], &dest, Limits::default()).is_err());
        assert!(!tmp.path().join("escaped.txt").exists());
        assert!(!tmp.path().parent().unwrap().join("escaped.txt").exists());
    }

    #[test]
    fn extracted_files_get_plain_permissions_whatever_the_archive_says() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
            let mut b = tar::Builder::new(gz);
            let mut h = tar::Header::new_gnu();
            let name = b"o-r-abc/app-panes/x/web/run.sh";
            h.as_old_mut().name[..name.len()].copy_from_slice(name);
            h.set_size(2);
            h.set_mode(0o4755);
            h.set_cksum();
            b.append(&h, &b"#!"[..]).unwrap();
            let tar = b.into_inner().unwrap().finish().unwrap();
            let tmp = tempfile::tempdir().unwrap();
            extract_tar_gz(&tar[..], tmp.path(), Limits::default()).unwrap();
            let mode = fs::metadata(tmp.path().join("app-panes/x/web/run.sh")).unwrap().permissions().mode() & 0o7777;
            assert_eq!(mode & 0o111, 0, "no execute bit: {mode:o}");
            assert_eq!(mode & 0o7000, 0, "no setuid/setgid/sticky: {mode:o}");
        }
    }

    #[test]
    fn a_damaged_or_empty_download_is_a_clear_refusal() {
        let tmp = tempfile::tempdir().unwrap();
        let junk = b"this is not a gzip stream at all";
        let e = extract_tar_gz(&junk[..], tmp.path(), Limits::default()).unwrap_err();
        assert_eq!(e.kind, InstallErrorKind::BadArchive);
        let empty = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        let mut b = tar::Builder::new(empty);
        b.finish().unwrap();
        let tar = b.into_inner().unwrap().finish().unwrap();
        let e = extract_tar_gz(&tar[..], tmp.path(), Limits::default()).unwrap_err();
        assert!(e.message.contains("no files"), "{}", e.message);
        let mut w = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        w.write_all(&[0u8; 100]).unwrap();
        let truncated = w.finish().unwrap();
        assert!(extract_tar_gz(&truncated[..truncated.len() / 2], tmp.path(), Limits::default()).is_err());
    }
}
