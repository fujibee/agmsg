//! Test helpers shared by the install tests.

use serde_json::Value;

pub(crate) fn content(e: &Value) -> Vec<u8> {
    match e.get("size").and_then(Value::as_u64) {
        Some(n) => vec![b'a'; n as usize],
        None => e.get("text").and_then(Value::as_str).unwrap_or("").as_bytes().to_vec(),
    }
}


/// A tar.gz as GitHub makes one: everything under one top-level folder.
/// Names are written raw, so hostile paths (absolute, `..`, backslash) can be expressed.
pub(crate) fn tarball(entries: &[Value]) -> Vec<u8> {
    let gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    let mut b = tar::Builder::new(gz);
    for e in entries {
        let name = if e.get("raw").and_then(Value::as_bool).unwrap_or(false) { e["path"].as_str().unwrap().to_string() } else { format!("o-r-abc123/{}", e["path"].as_str().unwrap()) };
        assert!(name.len() < 100, "fixture path too long for a plain header: {name}");
        let mut h = tar::Header::new_gnu();
        h.as_old_mut().name[..name.len()].copy_from_slice(name.as_bytes());
        let data = content(e);
        h.set_mode(0o644);
        h.set_mtime(0);
        let ty = match e["type"].as_str().unwrap() {
            "file" => tar::EntryType::Regular,
            "symlink" => tar::EntryType::Symlink,
            "hardlink" => tar::EntryType::Link,
            "char" => tar::EntryType::Char,
            "fifo" => tar::EntryType::Fifo,
            t => panic!("unsupported fixture type {t}"),
        };
        h.set_entry_type(ty);
        match ty {
            tar::EntryType::Symlink => {
                h.set_size(0);
                h.set_link_name(e["target"].as_str().unwrap()).unwrap();
            }
            tar::EntryType::Link => {
                h.set_size(0);
                h.set_link_name(format!("o-r-abc123/{}", e["of"].as_str().unwrap())).unwrap();
            }
            tar::EntryType::Regular => h.set_size(data.len() as u64),
            _ => h.set_size(0),
        }
        h.set_cksum();
        b.append(&h, &data[..]).unwrap();
    }
    let gz = b.into_inner().unwrap();
    gz.finish().unwrap()
}

