//! The Content-Security-Policy of one add-on pane (design 4.4).
//!
//! Code may come only from the pinned payload: no `'unsafe-inline'`,
//! `'unsafe-eval'`, `'wasm-unsafe-eval'`, `blob:` or `data:` in `script-src`
//! or `worker-src`. Inline `<script>` blocks are allowed only by the SHA-256
//! the installer computed over the confirmed bytes.

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use sha2::{Digest, Sha256};

/// What the pane's `network` permission allows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Network {
    /// No `network` permission.
    None,
    /// Any origin (`network = *`).
    Any,
    /// Exactly these origins, each `https://host[:port]` or `wss://host[:port]`.
    Origins(Vec<String>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NetworkError(pub String);

impl std::fmt::Display for NetworkError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Parses the `network` key of `addon.conf`: `*` or a comma list of origins.
/// Anything that could alter the policy text is refused, never trimmed away.
pub fn parse_network(value: &str) -> Result<Network, NetworkError> {
    let value = value.trim();
    if value.is_empty() {
        return Ok(Network::None);
    }
    if value == "*" {
        return Ok(Network::Any);
    }
    let mut out = Vec::new();
    for raw in value.split(',') {
        let item = raw.trim();
        if !valid_origin(item) {
            return Err(NetworkError(format!(
                "`{item}` is not an origin of the form https://host[:port] or wss://host[:port]"
            )));
        }
        if !out.iter().any(|o| o == item) {
            out.push(item.to_string());
        }
    }
    Ok(Network::Origins(out))
}

fn valid_origin(s: &str) -> bool {
    let rest = if let Some(r) = s.strip_prefix("https://") {
        r
    } else if let Some(r) = s.strip_prefix("wss://") {
        r
    } else {
        return false;
    };
    let (host, port) = match rest.rsplit_once(':') {
        Some((h, p)) => (h, Some(p)),
        None => (rest, None),
    };
    if let Some(p) = port {
        if p.is_empty() || p.len() > 5 || !p.bytes().all(|b| b.is_ascii_digit()) || p.parse::<u32>().map_or(true, |n| n == 0 || n > 65535) {
            return false;
        }
    }
    if host.is_empty() || host.len() > 253 || host.starts_with('.') || host.ends_with('.') || host.starts_with('-') {
        return false;
    }
    // Hostname labels only: no wildcards, paths, credentials, quotes or separators.
    host.split('.').all(|label| {
        !label.is_empty()
            && label.len() <= 63
            && !label.starts_with('-')
            && !label.ends_with('-')
            && label.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
    })
}

pub struct PaneCsp<'a> {
    /// The pane's exact origin, `http://127.0.0.1:<port>` (not `'self'`: its
    /// meaning in an opaque-origin frame differs between engines).
    pub own: &'a str,
    pub network: &'a Network,
    /// `'sha256-…'` source expressions of the confirmed inline scripts.
    pub script_hashes: &'a [String],
}

pub fn build(c: &PaneCsp<'_>) -> String {
    let net = match c.network {
        Network::None => String::new(),
        Network::Any => " *".to_string(),
        Network::Origins(list) => list.iter().map(|o| format!(" {o}")).collect(),
    };
    let hashes: String = c.script_hashes.iter().map(|h| format!(" {h}")).collect();
    let own = c.own;
    format!(
        "default-src {own}; script-src {own}{hashes}; style-src {own} 'unsafe-inline'; \
         img-src {own}{net} data: blob:; font-src {own}{net} data:; media-src {own}{net} blob:; \
         connect-src {own}{net}; frame-src 'none'; worker-src {own}; form-action 'none'; base-uri 'none'"
    )
}

/// `'sha256-<base64>'` of a script's exact text.
pub fn script_hash(text: &str) -> String {
    let digest = Sha256::digest(text.as_bytes());
    format!("'sha256-{}'", STANDARD.encode(digest))
}

/// Hashes of every inline classic or module `<script>` in an HTML document.
/// `src=` scripts and data blocks (`type` other than JavaScript/module) are
/// skipped; the result has no duplicates.
pub fn inline_script_hashes(html: &str) -> Vec<String> {
    let lower = html.to_ascii_lowercase();
    let bytes = lower.as_bytes();
    let mut out: Vec<String> = Vec::new();
    let mut i = 0;
    while let Some(pos) = lower[i..].find("<script") {
        let start = i + pos;
        let after = start + "<script".len();
        // `<scripts>` or `<script-x>` is not a script element.
        match bytes.get(after) {
            Some(b) if b.is_ascii_whitespace() || *b == b'>' || *b == b'/' => {}
            _ => {
                i = after;
                continue;
            }
        }
        let Some(tag_end_rel) = lower[after..].find('>') else { break };
        let tag_end = after + tag_end_rel;
        let attrs = &lower[after..tag_end];
        let body_start = tag_end + 1;
        let Some(close_rel) = lower[body_start..].find("</script") else { break };
        let body_end = body_start + close_rel;
        i = body_end;
        if has_attr(attrs, "src") || !is_js_type(attrs) {
            continue;
        }
        let h = script_hash(&html[body_start..body_end]);
        if !out.contains(&h) {
            out.push(h);
        }
    }
    out
}

fn has_attr(attrs: &str, name: &str) -> bool {
    attr_value(attrs, name).is_some()
}

fn attr_value<'a>(attrs: &'a str, name: &str) -> Option<&'a str> {
    let b = attrs.as_bytes();
    let mut i = 0;
    while i < b.len() {
        while i < b.len() && (b[i].is_ascii_whitespace() || b[i] == b'/') {
            i += 1;
        }
        let s = i;
        while i < b.len() && !b[i].is_ascii_whitespace() && b[i] != b'=' && b[i] != b'/' {
            i += 1;
        }
        let key = &attrs[s..i];
        while i < b.len() && b[i].is_ascii_whitespace() {
            i += 1;
        }
        let mut val = "";
        if i < b.len() && b[i] == b'=' {
            i += 1;
            while i < b.len() && b[i].is_ascii_whitespace() {
                i += 1;
            }
            if i < b.len() && (b[i] == b'"' || b[i] == b'\'') {
                let q = b[i];
                let vs = i + 1;
                i = vs;
                while i < b.len() && b[i] != q {
                    i += 1;
                }
                val = &attrs[vs..i.min(b.len())];
                i += 1;
            } else {
                let vs = i;
                while i < b.len() && !b[i].is_ascii_whitespace() {
                    i += 1;
                }
                val = &attrs[vs..i];
            }
        }
        if key == name {
            return Some(val);
        }
    }
    None
}

fn is_js_type(attrs: &str) -> bool {
    match attr_value(attrs, "type") {
        None => true,
        Some(t) => {
            let t = t.trim();
            t.is_empty() || t == "module" || t == "text/javascript" || t == "application/javascript" || t == "text/ecmascript" || t == "application/ecmascript"
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn network_parses_star_empty_and_lists() {
        assert_eq!(parse_network("").unwrap(), Network::None);
        assert_eq!(parse_network(" * ").unwrap(), Network::Any);
        assert_eq!(
            parse_network("https://api.example.com, https://cdn.example.com:8443,https://api.example.com").unwrap(),
            Network::Origins(vec!["https://api.example.com".into(), "https://cdn.example.com:8443".into()])
        );
        assert_eq!(parse_network("wss://ws.example.com").unwrap(), Network::Origins(vec!["wss://ws.example.com".into()]));
    }

    #[test]
    fn network_refuses_anything_that_could_change_the_policy() {
        for bad in [
            "http://example.com",
            "https://*.example.com",
            "https://example.com/path",
            "https://user@example.com",
            "https://example.com;script-src *",
            "https://example.com 'unsafe-eval'",
            "https://exa'mple.com",
            "https://",
            "https://example.com:",
            "https://example.com:0",
            "https://example.com:70000",
            "https://example.com:80a",
            "https://.example.com",
            "https://example..com",
            "https://-a.example.com",
            "*,https://example.com",
            "https://example.com,",
            "data:",
            "https://exa\nmple.com",
        ] {
            assert!(parse_network(bad).is_err(), "{bad:?} must be refused");
        }
    }

    #[test]
    fn csp_without_network_has_only_own_and_data() {
        let c = build(&PaneCsp { own: "http://127.0.0.1:5000", network: &Network::None, script_hashes: &[] });
        assert_eq!(
            c,
            "default-src http://127.0.0.1:5000; script-src http://127.0.0.1:5000; style-src http://127.0.0.1:5000 'unsafe-inline'; \
             img-src http://127.0.0.1:5000 data: blob:; font-src http://127.0.0.1:5000 data:; media-src http://127.0.0.1:5000 blob:; \
             connect-src http://127.0.0.1:5000; frame-src 'none'; worker-src http://127.0.0.1:5000; form-action 'none'; base-uri 'none'"
        );
    }

    #[test]
    fn csp_network_goes_only_where_the_design_says() {
        let n = Network::Origins(vec!["https://a.test".into()]);
        let c = build(&PaneCsp { own: "http://127.0.0.1:1", network: &n, script_hashes: &[] });
        for d in ["img-src", "font-src", "media-src", "connect-src"] {
            let part = c.split("; ").find(|p| p.starts_with(d)).unwrap();
            assert!(part.contains("https://a.test"), "{d}: {part}");
        }
        for d in ["default-src", "script-src", "style-src", "worker-src", "frame-src", "form-action", "base-uri"] {
            let part = c.split("; ").find(|p| p.starts_with(d)).unwrap();
            assert!(!part.contains("a.test"), "{d}: {part}");
        }
        let any = build(&PaneCsp { own: "http://127.0.0.1:1", network: &Network::Any, script_hashes: &[] });
        assert!(any.contains("connect-src http://127.0.0.1:1 *;"));
    }

    #[test]
    fn code_directives_never_allow_unpinned_code() {
        let h = vec![script_hash("x")];
        let c = build(&PaneCsp { own: "http://127.0.0.1:1", network: &Network::Any, script_hashes: &h });
        for d in ["script-src", "worker-src", "default-src"] {
            let part = c.split("; ").find(|p| p.starts_with(d)).unwrap();
            for t in part.split(' ').skip(1) {
                assert!(t == "http://127.0.0.1:1" || t.starts_with("'sha256-"), "{d} has {t}: {part}");
            }
        }
        assert!(c.contains("script-src http://127.0.0.1:1 'sha256-"));
    }

    #[test]
    fn hash_is_the_standard_sha256_base64_of_the_exact_text() {
        // sha256("") is the well-known e3b0c442… ; its base64 is 47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=
        assert_eq!(script_hash(""), "'sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU='");
        assert_ne!(script_hash("a"), script_hash("a "));
    }

    #[test]
    fn finds_inline_scripts_only() {
        let html = r#"<html><head>
            <script type="module" crossorigin src="./a.js"></script>
            <script>var a = 1;</script>
            <SCRIPT type="module">import "./b.js";</SCRIPT>
            <script type="application/json">{"x":1}</script>
            <script type="text/template"><b>t</b></script>
            <scriptx>no</scriptx>
            <script src='./c.js'>ignored body</script>
            <script>var a = 1;</script>
        </head></html>"#;
        let hs = inline_script_hashes(html);
        assert_eq!(hs, vec![script_hash("var a = 1;"), script_hash("import \"./b.js\";")]);
    }

    #[test]
    fn a_vite_style_page_has_no_hashes() {
        let html = r#"<!doctype html><script type="module" crossorigin src="./assets/index.js"></script><link rel="stylesheet" href="./a.css"><div id=root></div>"#;
        assert!(inline_script_hashes(html).is_empty());
    }

    #[test]
    fn unterminated_script_does_not_panic_or_hash() {
        assert!(inline_script_hashes("<script>var a").is_empty());
        assert!(inline_script_hashes("<script").is_empty());
        assert!(inline_script_hashes("<script src=x").is_empty());
    }
}
