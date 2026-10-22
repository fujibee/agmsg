//! `addon.conf` (design 1): data only, `key = value`, never executed.
//!
//! The wording of every message matches `npx agmsg addon check`
//! (`bin/addon.js`), and the shared corpus in
//! `app/addon-kit/fixtures/conf-cases.json` is run against both.

use std::collections::BTreeMap;

use super::panes::Declared;

/// An `addon.conf` is a short manifest. Larger than this is refused unread.
pub const MAX_CONF_BYTES: usize = 64 * 1024;
pub const MAX_CONF_LINES: usize = 1000;

pub const PERMISSIONS: [&str; 4] = ["messages:read", "files:read", "git:read", "network"];
const KEYS: [&str; 7] = ["title", "entry", "min_app", "protocol", "permissions", "network", "opens"];
const OPENS: [&str; 2] = ["path", "url"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AddonConf {
    pub title: String,
    pub entry: String,
    pub min_app: Option<String>,
    pub protocol: u32,
    pub permissions: Vec<String>,
    /// The raw `network` value (`*` or a list of origins), when declared.
    pub network: Option<String>,
    pub opens: Vec<String>,
    /// `why.<permission>` lines, shown next to each permission.
    pub why: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ConfReport {
    pub conf: Option<AddonConf>,
    pub errors: Vec<String>,
    pub warnings: Vec<String>,
}

/// Reads an `addon.conf` without trusting its size: absent, ok, or too large
/// (anything over the cap is not read past it).
#[derive(Debug, PartialEq, Eq)]
pub enum ConfRead {
    Absent,
    Ok(Vec<u8>),
    TooLarge,
}

pub fn read_bounded(path: &std::path::Path) -> ConfRead {
    use std::io::Read;
    let Ok(f) = std::fs::File::open(path) else { return ConfRead::Absent };
    let mut buf = Vec::new();
    if f.take(MAX_CONF_BYTES as u64 + 1).read_to_end(&mut buf).is_err() {
        return ConfRead::Absent;
    }
    if buf.len() > MAX_CONF_BYTES {
        ConfRead::TooLarge
    } else {
        ConfRead::Ok(buf)
    }
}

fn list(v: &str) -> Vec<String> {
    v.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect()
}

/// Parses and validates one `addon.conf`. `rel` is the file's path as shown in
/// messages (`app-panes/<name>/addon.conf`). `conf` is `Some` only without errors.
pub fn parse(text: &str, rel: &str) -> ConfReport {
    if text.len() > MAX_CONF_BYTES {
        return ConfReport { conf: None, errors: vec![format!("{rel}: is larger than {} KiB; an add-on manifest is a few lines.", MAX_CONF_BYTES / 1024)], warnings: Vec::new() };
    }
    if text.split('\n').count() > MAX_CONF_LINES {
        return ConfReport { conf: None, errors: vec![format!("{rel}: has more than {MAX_CONF_LINES} lines; an add-on manifest is a few lines.")], warnings: Vec::new() };
    }
    let mut errors: Vec<String> = Vec::new();
    let mut warnings: Vec<String> = Vec::new();
    let mut values: BTreeMap<String, (String, usize)> = BTreeMap::new();
    for (i, raw) in text.split('\n').enumerate() {
        let raw = raw.strip_suffix('\r').unwrap_or(raw);
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let n = i + 1;
        let Some(eq) = line.find('=') else {
            errors.push(format!("{rel} line {n}: expected key = value."));
            continue;
        };
        if eq < 1 {
            errors.push(format!("{rel} line {n}: expected key = value."));
            continue;
        }
        let key = line[..eq].trim().to_string();
        let value = strip_trailing_comment(&line[eq + 1..]).trim().to_string();
        let known = KEYS.contains(&key.as_str()) || is_why_key(&key);
        if !known {
            errors.push(format!("{rel} line {n}: unknown key \"{key}\"."));
            continue;
        }
        if values.contains_key(&key) {
            errors.push(format!("{rel} line {n}: duplicate key \"{key}\"."));
            continue;
        }
        values.insert(key, (value, n));
    }
    let val = |k: &str| values.get(k).map(|v| v.0.as_str());
    let at = |k: &str| format!("{rel} line {}", values[k].1);

    if val("title").map_or(true, str::is_empty) {
        errors.push(format!("{rel}: \"title\" is required."));
    }
    let mut protocol = 0u32;
    match val("protocol") {
        None => errors.push(format!("{rel}: \"protocol\" is required (protocol = 1).")),
        Some("1") => protocol = 1,
        Some(v) => errors.push(format!("{}: protocol {v} is not known to this version (1).", at("protocol"))),
    }
    if let Some(v) = val("min_app") {
        if !is_semver3(v) {
            errors.push(format!("{}: min_app must look like 0.6.0.", at("min_app")));
        }
    }
    let perms = val("permissions").map(list).unwrap_or_default();
    if val("permissions").is_some() {
        for p in &perms {
            if !PERMISSIONS.contains(&p.as_str()) {
                errors.push(format!("{}: unknown permission \"{p}\".", at("permissions")));
            }
        }
    }
    let has = |p: &str| perms.iter().any(|x| x == p);
    if has("git:read") && !has("files:read") {
        errors.push(format!("{}: git:read needs files:read too.", at("permissions")));
    }
    if has("network") {
        match val("network") {
            None | Some("") => errors.push(format!("{}: network is declared but \"network = *\" or a list of origins is missing.", at("permissions"))),
            Some("*") => {}
            Some(v) => {
                for o in list(v) {
                    if !is_https_origin(&o) {
                        errors.push(format!("{}: \"{o}\" is not an origin like https://api.example.com.", at("network")));
                    }
                }
            }
        }
    } else if values.contains_key("network") {
        errors.push(format!("{}: \"network\" is set but the network permission is not declared.", at("network")));
    }
    for p in &perms {
        if val(&format!("why.{p}")).map_or(true, str::is_empty) {
            warnings.push(format!("{rel}: no \"why.{p}\" line; users see it next to the permission."));
        }
    }
    for k in values.keys() {
        if let Some(p) = k.strip_prefix("why.") {
            if !perms.iter().any(|x| x == p) {
                warnings.push(format!("{}: \"{k}\" is for a permission that is not declared.", at(k)));
            }
        }
    }
    let opens = val("opens").map(list).unwrap_or_default();
    if val("opens").is_some() {
        for o in &opens {
            if !OPENS.contains(&o.as_str()) {
                errors.push(format!("{}: unknown \"{o}\" (path or url).", at("opens")));
            }
        }
    }
    if let Some(e) = val("entry") {
        if !e.is_empty() && !super::server::valid_relative(e) {
            errors.push(format!("{}: entry must be a plain path under web/.", at("entry")));
        }
    }

    let conf = if errors.is_empty() {
        let mut why = BTreeMap::new();
        for (k, v) in &values {
            if let Some(p) = k.strip_prefix("why.") {
                if !v.0.is_empty() {
                    why.insert(p.to_string(), v.0.clone());
                }
            }
        }
        Some(AddonConf {
            title: val("title").unwrap_or("").to_string(),
            entry: val("entry").filter(|e| !e.is_empty()).unwrap_or("index.html").to_string(),
            min_app: val("min_app").map(str::to_string),
            protocol,
            permissions: perms.clone(),
            network: val("network").map(str::to_string),
            opens,
            why,
        })
    } else {
        None
    };
    ConfReport { conf, errors, warnings }
}

fn is_why_key(k: &str) -> bool {
    // why.[a-z:]+
    k.strip_prefix("why.").is_some_and(|r| !r.is_empty() && r.bytes().all(|b| b.is_ascii_lowercase() || b == b':'))
}

fn strip_trailing_comment(v: &str) -> &str {
    // whitespace followed by `#` starts a comment (as in bin/addon.js)
    let b = v.as_bytes();
    for i in 0..b.len() {
        if b[i] == b'#' && i > 0 && b[i - 1].is_ascii_whitespace() {
            return v[..i].trim_end();
        }
    }
    v
}

fn is_semver3(v: &str) -> bool {
    let parts: Vec<&str> = v.split('.').collect();
    parts.len() == 3 && parts.iter().all(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()))
}

fn is_https_origin(o: &str) -> bool {
    // https://[a-z0-9.-]+(:\d{1,5})?   (same as bin/addon.js)
    let Some(rest) = o.strip_prefix("https://").or_else(|| o.strip_prefix("HTTPS://")) else { return false };
    let (host, port) = match rest.rsplit_once(':') {
        Some((h, p)) => (h, Some(p)),
        None => (rest, None),
    };
    if host.is_empty() || !host.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-') {
        return false;
    }
    match port {
        None => true,
        Some(p) => (1..=5).contains(&p.len()) && p.bytes().all(|b| b.is_ascii_digit()),
    }
}

impl AddonConf {
    /// What the broker and the CSP are built from. The UI never supplies this.
    pub fn declared(&self) -> Declared {
        let has = |p: &str| self.permissions.iter().any(|x| x == p);
        let network = if has("network") {
            // validated by `parse` above for the lexical form; the CSP parser is stricter
            self.network.as_deref().and_then(|n| super::csp::parse_network(n).ok())
        } else {
            None
        };
        Declared { messages_read: has("messages:read"), files_read: has("files:read"), git_read: has("git:read"), network }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::addons::csp::Network;

    fn ok(text: &str) -> AddonConf {
        let r = parse(text, "app-panes/x/addon.conf");
        assert!(r.errors.is_empty(), "{:?}", r.errors);
        r.conf.unwrap()
    }

    fn errs(text: &str) -> Vec<String> {
        parse(text, "app-panes/x/addon.conf").errors
    }

    #[test]
    fn the_builtin_confs_parse() {
        let f = ok("title=File view\nentry=index.html\nprotocol=1\npermissions=files:read\nopens=path\nwhy.files:read=Lists and reads.\n");
        assert_eq!(f.title, "File view");
        assert_eq!(f.permissions, vec!["files:read"]);
        assert_eq!(f.opens, vec!["path"]);
        assert_eq!(f.why["files:read"], "Lists and reads.");
        let d = f.declared();
        assert!(d.files_read && !d.git_read && !d.messages_read && d.network.is_none());
    }

    #[test]
    fn defaults_comments_and_crlf() {
        let c = ok("# a comment\r\ntitle = T   # trailing\r\n\r\nprotocol = 1\r\n");
        assert_eq!(c.entry, "index.html");
        assert_eq!(c.title, "T");
        assert!(c.permissions.is_empty() && c.network.is_none() && c.opens.is_empty());
        let d = c.declared();
        assert!(!d.messages_read && !d.files_read && !d.git_read);
    }

    #[test]
    fn required_keys_and_protocol() {
        assert!(errs("protocol=1\n").iter().any(|e| e.contains("\"title\" is required")));
        assert!(errs("title=T\n").iter().any(|e| e.contains("\"protocol\" is required (protocol = 1)")));
        assert!(errs("title=T\nprotocol=2\n").iter().any(|e| e == "app-panes/x/addon.conf line 2: protocol 2 is not known to this version (1)."));
    }

    #[test]
    fn unknown_things_are_refused_never_ignored() {
        let e = errs("title=T\nprotocol=1\nwidth=3\npermissions=files:read,root\n");
        assert!(e.contains(&"app-panes/x/addon.conf line 3: unknown key \"width\".".to_string()), "{e:?}");
        assert!(e.contains(&"app-panes/x/addon.conf line 4: unknown permission \"root\".".to_string()), "{e:?}");
        assert!(errs("title=T\nprotocol=1\ntitle=U\n").iter().any(|e| e.contains("duplicate key \"title\"")));
        assert!(errs("title=T\nprotocol=1\nnot a pair\n").iter().any(|e| e.contains("expected key = value")));
        assert!(errs("title=T\nprotocol=1\n=x\n").iter().any(|e| e.contains("expected key = value")));
        assert!(errs("title=T\nprotocol=1\nopens=file\n").iter().any(|e| e.contains("unknown \"file\" (path or url)")));
        assert!(errs("title=T\nprotocol=1\nmin_app=0.6\n").iter().any(|e| e.contains("min_app must look like 0.6.0")));
    }

    #[test]
    fn git_needs_files_and_network_needs_its_list() {
        assert!(errs("title=T\nprotocol=1\npermissions=git:read\n").iter().any(|e| e.contains("git:read needs files:read too")));
        assert!(errs("title=T\nprotocol=1\npermissions=network\n").iter().any(|e| e.contains("network is declared but")));
        assert!(errs("title=T\nprotocol=1\nnetwork=*\n").iter().any(|e| e.contains("network permission is not declared")));
        assert!(errs("title=T\nprotocol=1\npermissions=network\nnetwork=http://a.test\n").iter().any(|e| e.contains("is not an origin like https://api.example.com")));
        let c = ok("title=T\nprotocol=1\npermissions=network\nnetwork=https://a.test, https://b.test:8443\n");
        let d = c.declared();
        assert_eq!(d.network, Some(Network::Origins(vec!["https://a.test".into(), "https://b.test:8443".into()])));
        let any = ok("title=T\nprotocol=1\npermissions=network\nnetwork=*\n").declared();
        assert_eq!(any.network, Some(Network::Any));
    }

    #[test]
    fn why_lines_warn_both_ways() {
        let r = parse("title=T\nprotocol=1\npermissions=files:read\nwhy.messages:read=x\n", "c");
        assert!(r.warnings.iter().any(|w| w.contains("no \"why.files:read\" line")));
        assert!(r.warnings.iter().any(|w| w.contains("for a permission that is not declared")));
        assert!(r.errors.is_empty());
    }

    #[test]
    fn an_oversized_conf_is_refused_with_a_reason() {
        let big = format!("title = T\nprotocol = 1\n# {}\n", "x".repeat(MAX_CONF_BYTES));
        let r = parse(&big, "app-panes/x/addon.conf");
        assert!(r.conf.is_none() && r.errors[0].contains("larger than 64 KiB"), "{:?}", r.errors);
        let many = format!("title = T\nprotocol = 1\n{}", "# c\n".repeat(MAX_CONF_LINES));
        let r = parse(&many, "c");
        assert!(r.conf.is_none() && r.errors[0].contains("more than 1000 lines"), "{:?}", r.errors);
        let just = format!("title = T\nprotocol = 1\n{}", "# c\n".repeat(900));
        assert!(parse(&just, "c").conf.is_some());
    }

    #[test]
    fn read_bounded_splits_absent_ok_and_too_large() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(read_bounded(&d.path().join("nope")), ConfRead::Absent);
        std::fs::write(d.path().join("ok"), "title=T").unwrap();
        assert_eq!(read_bounded(&d.path().join("ok")), ConfRead::Ok(b"title=T".to_vec()));
        std::fs::write(d.path().join("big"), vec![b'a'; MAX_CONF_BYTES + 1]).unwrap();
        assert_eq!(read_bounded(&d.path().join("big")), ConfRead::TooLarge);
        std::fs::write(d.path().join("exact"), vec![b'#'; MAX_CONF_BYTES]).unwrap();
        assert!(matches!(read_bounded(&d.path().join("exact")), ConfRead::Ok(_)));
        assert_eq!(read_bounded(d.path()), ConfRead::Absent, "a directory is not a conf");
    }

    #[test]
    fn the_entry_must_be_a_plain_relative_path() {
        for bad in ["../x.html", "/x.html", "a//b.html", "C:/x.html", "a\\b.html"] {
            let e = errs(&format!("title=T\nprotocol=1\nentry={bad}\n"));
            assert!(e.iter().any(|m| m.contains("entry must be a plain path")), "{bad}: {e:?}");
        }
        assert_eq!(ok("title=T\nprotocol=1\nentry=ui/main.html\n").entry, "ui/main.html");
    }

    #[test]
    fn declared_matches_every_permission() {
        let d = ok("title=T\nprotocol=1\npermissions=messages:read,files:read,git:read\n").declared();
        assert!(d.messages_read && d.files_read && d.git_read);
    }
}
