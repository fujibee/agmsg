//! GitHub, and nothing else, as the source of add-ons (design 3.1): resolve
//! `owner/repo[@ref]` to a full commit SHA, then download the tarball of that
//! SHA. Public repositories only, unauthenticated. Every failure is turned into
//! the words of the install failure table (design 3.2).

use std::io::Read;
use std::time::Duration;

use super::stage::Failure;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Source {
    pub owner: String,
    pub repo: String,
    /// A branch, tag or commit; `None` = the default branch.
    pub git_ref: Option<String>,
}

impl Source {
    pub fn slug(&self) -> String {
        format!("{}/{}", self.owner, self.repo)
    }
}

fn name_ok(s: &str) -> bool {
    !s.is_empty() && s.len() <= 100 && s != "." && s != ".." && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
}

fn ref_ok(s: &str) -> bool {
    // refs go into a URL path: no path tricks, no query, no spaces
    !s.is_empty()
        && s.len() <= 200
        && !s.starts_with('/')
        && !s.ends_with('/')
        && !s.contains("..")
        && !s.contains("//")
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_./+".contains(&b))
}

/// `owner/repo` or `owner/repo@ref`. Anything else (URLs, other hosts, extra
/// path) is refused with the "malformed" message.
pub fn parse_source(input: &str) -> Result<Source, Failure> {
    let bad = || Failure { code: "repo_not_found", message: format!("Couldn't find github.com/{}. Check the name. Private repositories aren't supported yet.", input.trim()) };
    let t = input.trim();
    let (slug, git_ref) = match t.split_once('@') {
        Some((a, b)) => (a, Some(b)),
        None => (t, None),
    };
    let mut it = slug.split('/');
    let (Some(owner), Some(repo), None) = (it.next(), it.next(), it.next()) else { return Err(bad()) };
    if !name_ok(owner) || !name_ok(repo) {
        return Err(bad());
    }
    if let Some(r) = git_ref {
        if !ref_ok(r) {
            return Err(Failure { code: "ref_not_found", message: format!("{owner}/{repo} has no branch, tag or commit named {r}.") });
        }
    }
    Ok(Source { owner: owner.to_string(), repo: repo.to_string(), git_ref: git_ref.map(str::to_string) })
}

pub struct Github {
    api_base: String,
    client: reqwest::blocking::Client,
}

fn host_allowed(host: &str) -> bool {
    matches!(host, "github.com" | "api.github.com" | "codeload.github.com" | "objects.githubusercontent.com") || host.ends_with(".githubusercontent.com")
}

fn ensure_tls_provider() {
    if rustls::crypto::CryptoProvider::get_default().is_none() {
        let _ = rustls::crypto::ring::default_provider().install_default();
    }
}

fn client(allow_loopback: bool, user_agent: &str) -> Result<reqwest::blocking::Client, Failure> {
    ensure_tls_provider();
    reqwest::blocking::Client::builder()
        .user_agent(user_agent)
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(600))
        .redirect(reqwest::redirect::Policy::custom(move |attempt| {
            let u = attempt.url();
            let ok = (u.scheme() == "https" && u.host_str().is_some_and(host_allowed)) || (allow_loopback && u.scheme() == "http" && u.host_str() == Some("127.0.0.1"));
            if attempt.previous().len() >= 5 {
                attempt.error("too many redirects")
            } else if ok {
                attempt.follow()
            } else {
                attempt.error("redirected to a host that is not GitHub")
            }
        }))
        .build()
        .map_err(|e| Failure { code: "network", message: format!("GitHub didn't answer: {e}. Try again.") })
}

fn reset_time(h: &reqwest::header::HeaderMap) -> String {
    let secs = h.get("x-ratelimit-reset").and_then(|v| v.to_str().ok()).and_then(|v| v.parse::<u64>().ok());
    match secs {
        Some(s) => {
            let rem = s % 86_400;
            format!("{:02}:{:02} UTC", rem / 3600, (rem % 3600) / 60)
        }
        None => "a few minutes".into(),
    }
}

fn explain(resp: &reqwest::blocking::Response) -> Failure {
    let status = resp.status();
    let h = resp.headers();
    let limited = (status.as_u16() == 403 || status.as_u16() == 429) && (h.get("x-ratelimit-remaining").and_then(|v| v.to_str().ok()) == Some("0") || h.get("retry-after").is_some());
    if limited {
        return Failure { code: "rate_limited", message: format!("GitHub limits unauthenticated downloads; try again after {}.", reset_time(h)) };
    }
    Failure { code: "network", message: format!("GitHub didn't answer: {}. Try again.", status.as_u16()) }
}

fn net_err(e: reqwest::Error) -> Failure {
    Failure { code: "network", message: format!("GitHub didn't answer: {}. Try again.", e.without_url()) }
}

impl Github {
    pub fn new(user_agent: &str) -> Result<Github, Failure> {
        Ok(Github { api_base: "https://api.github.com".into(), client: client(false, user_agent)? })
    }

    /// Test seam: another API base (a local server), loopback redirects allowed.
    #[cfg(test)]
    pub fn with_base(api_base: &str) -> Github {
        Github { api_base: api_base.trim_end_matches('/').to_string(), client: client(true, "agmsg-app-test").unwrap() }
    }

    fn get(&self, path: &str, accept: &str) -> Result<reqwest::blocking::Response, Failure> {
        self.client.get(format!("{}{}", self.api_base, path)).header("Accept", accept).send().map_err(net_err)
    }

    /// The full 40-hex commit SHA for the source's ref (or its default branch).
    pub fn resolve(&self, s: &Source) -> Result<String, Failure> {
        let not_found = || Failure { code: "repo_not_found", message: format!("Couldn't find github.com/{}. Check the name. Private repositories aren't supported yet.", s.slug()) };
        // the repository itself first, so "no such repo" and "no such ref" are told apart
        let r = self.get(&format!("/repos/{}/{}", s.owner, s.repo), "application/vnd.github+json")?;
        if r.status().as_u16() == 404 {
            return Err(not_found());
        }
        if !r.status().is_success() {
            return Err(explain(&r));
        }
        let body: serde_json::Value = r.json_value()?;
        if body.get("private").and_then(|v| v.as_bool()) == Some(true) {
            return Err(not_found());
        }
        let git_ref = match &s.git_ref {
            Some(r) => r.clone(),
            None => body.get("default_branch").and_then(|v| v.as_str()).map(str::to_string).ok_or_else(|| Failure { code: "network", message: "GitHub didn't answer: the repository has no default branch. Try again.".into() })?,
        };
        let c = self.get(&format!("/repos/{}/{}/commits/{}", s.owner, s.repo, git_ref), "application/vnd.github.sha")?;
        match c.status().as_u16() {
            404 | 422 => {
                return Err(Failure { code: "ref_not_found", message: format!("{} has no branch, tag or commit named {}.", s.slug(), git_ref) });
            }
            _ if !c.status().is_success() => return Err(explain(&c)),
            _ => {}
        }
        let sha = c.text().map_err(net_err)?.trim().to_string();
        if sha.len() == 40 && sha.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
            Ok(sha)
        } else {
            Err(Failure { code: "network", message: "GitHub didn't answer: the commit id was not understood. Try again.".into() })
        }
    }

    /// The tarball of exactly `sha`, as a reader (the caller bounds and hashes it).
    pub fn download(&self, s: &Source, sha: &str) -> Result<Box<dyn Read + Send>, Failure> {
        if sha.len() != 40 || !sha.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
            return Err(Failure { code: "ref_not_found", message: "internal: not a full commit id".into() });
        }
        let r = self.get(&format!("/repos/{}/{}/tarball/{}", s.owner, s.repo, sha), "application/vnd.github+json")?;
        if r.status().as_u16() == 404 {
            return Err(Failure { code: "repo_not_found", message: format!("Couldn't find github.com/{}. Check the name. Private repositories aren't supported yet.", s.slug()) });
        }
        if !r.status().is_success() {
            return Err(explain(&r));
        }
        Ok(Box::new(r))
    }
}

trait JsonValue {
    fn json_value(self) -> Result<serde_json::Value, Failure>;
}

impl JsonValue for reqwest::blocking::Response {
    fn json_value(self) -> Result<serde_json::Value, Failure> {
        let text = self.text().map_err(net_err)?;
        serde_json::from_str(&text).map_err(|_| Failure { code: "network", message: "GitHub didn't answer: the reply was not understood. Try again.".into() })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    #[test]
    fn sources_parse_and_malformed_ones_are_the_not_found_message() {
        let s = parse_source("shinshin86/agmsg-office").unwrap();
        assert_eq!((s.owner.as_str(), s.repo.as_str(), s.git_ref), ("shinshin86", "agmsg-office", None));
        let s = parse_source("  o/r@v1.2.3 ").unwrap();
        assert_eq!(s.git_ref.as_deref(), Some("v1.2.3"));
        assert_eq!(parse_source("o/r@feature/x-1").unwrap().git_ref.as_deref(), Some("feature/x-1"));
        for bad in ["", "o", "o/", "/r", "o/r/extra", "https://github.com/o/r", "github.com/o/r", "o/r@", "../r", "o/..", "o r/x", "o/r?x=1", "o/r#x", "o\\r"] {
            assert!(parse_source(bad).is_err(), "{bad:?}");
        }
        assert_eq!(parse_source("nope").unwrap_err().message, "Couldn't find github.com/nope. Check the name. Private repositories aren't supported yet.");
        assert_eq!(parse_source("o/r@a..b").unwrap_err().code, "ref_not_found");
        assert!(parse_source("o/r@x y").is_err());
    }

    /// A tiny fake GitHub: (path-prefix, status, headers, body); the first match wins.
    struct Fake {
        base: String,
        hits: Arc<Mutex<Vec<String>>>,
    }

    type Route = (String, u16, Vec<(String, String)>, Vec<u8>);

    fn fake(routes: Vec<Route>) -> Fake {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let hits = Arc::new(Mutex::new(Vec::new()));
        let h = hits.clone();
        std::thread::spawn(move || {
            for s in l.incoming().flatten() {
                let mut s = s;
                let mut buf = [0u8; 4096];
                let n = s.read(&mut buf).unwrap_or(0);
                let req = String::from_utf8_lossy(&buf[..n]).to_string();
                let path = req.split(' ').nth(1).unwrap_or("").to_string();
                h.lock().unwrap().push(path.clone());
                let r = routes.iter().find(|(p, ..)| path == *p || path.starts_with(&format!("{p}/")) && p.ends_with("tarball"));
                let (status, headers, body) = match r {
                    Some((_, st, hd, b)) => (*st, hd.clone(), b.clone()),
                    None => (404, vec![], b"{}".to_vec()),
                };
                let mut out = format!("HTTP/1.1 {status} X\r\nContent-Length: {}\r\nConnection: close\r\n", body.len());
                for (k, v) in headers {
                    out.push_str(&format!("{k}: {v}\r\n"));
                }
                out.push_str("\r\n");
                let _ = s.write_all(out.as_bytes());
                let _ = s.write_all(&body);
            }
        });
        Fake { base: format!("http://127.0.0.1:{port}"), hits }
    }

    fn route(path: &str, status: u16, body: &str) -> Route {
        (path.into(), status, vec![], body.as_bytes().to_vec())
    }

    const SHA: &str = "0123456789abcdef0123456789abcdef01234567";

    #[test]
    fn resolves_the_default_branch_and_a_named_ref_to_a_full_sha() {
        let f = fake(vec![route("/repos/o/r", 200, r#"{"default_branch":"trunk","private":false}"#), route("/repos/o/r/commits/trunk", 200, &format!("{SHA}\n")), route("/repos/o/r/commits/v1", 200, "ffffffffffffffffffffffffffffffffffffffff")]);
        let g = Github::with_base(&f.base);
        assert_eq!(g.resolve(&parse_source("o/r").unwrap()).unwrap(), SHA);
        assert_eq!(g.resolve(&parse_source("o/r@v1").unwrap()).unwrap(), "f".repeat(40));
        assert!(f.hits.lock().unwrap().contains(&"/repos/o/r/commits/trunk".to_string()));
    }

    #[test]
    fn missing_repo_private_repo_and_missing_ref_have_their_own_messages() {
        let f = fake(vec![route("/repos/o/r", 200, r#"{"default_branch":"main","private":false}"#), route("/repos/o/priv", 200, r#"{"default_branch":"main","private":true}"#), route("/repos/o/r/commits/nope", 422, "{}")]);
        let g = Github::with_base(&f.base);
        let e = g.resolve(&parse_source("o/missing").unwrap()).unwrap_err();
        assert_eq!((e.code, e.message.as_str()), ("repo_not_found", "Couldn't find github.com/o/missing. Check the name. Private repositories aren't supported yet."));
        assert_eq!(g.resolve(&parse_source("o/priv").unwrap()).unwrap_err().code, "repo_not_found");
        let e = g.resolve(&parse_source("o/r@nope").unwrap()).unwrap_err();
        assert_eq!((e.code, e.message.as_str()), ("ref_not_found", "o/r has no branch, tag or commit named nope."));
    }

    #[test]
    fn rate_limit_and_server_errors_are_explained() {
        let limited: Route = ("/repos/o/r".into(), 403, vec![("x-ratelimit-remaining".into(), "0".into()), ("x-ratelimit-reset".into(), "1792657018".into())], b"{}".to_vec());
        let g = Github::with_base(&fake(vec![limited]).base);
        let e = g.resolve(&parse_source("o/r").unwrap()).unwrap_err();
        assert_eq!(e.code, "rate_limited");
        assert_eq!(e.message, "GitHub limits unauthenticated downloads; try again after 08:16 UTC.");
        let g = Github::with_base(&fake(vec![route("/repos/o/r", 502, "bad gateway")]).base);
        let e = g.resolve(&parse_source("o/r").unwrap()).unwrap_err();
        assert_eq!((e.code, e.message.as_str()), ("network", "GitHub didn't answer: 502. Try again."));
        // nothing listening at all
        let dead = Github::with_base("http://127.0.0.1:9");
        let e = dead.resolve(&parse_source("o/r").unwrap()).unwrap_err();
        assert_eq!(e.code, "network");
        assert!(e.message.starts_with("GitHub didn't answer:") && e.message.ends_with("Try again."), "{}", e.message);
    }

    #[test]
    fn the_tarball_of_exactly_that_sha_is_downloaded_through_a_redirect() {
        let data = b"tar-bytes".to_vec();
        let f = fake(vec![("/repos/o/r/tarball".into(), 302, vec![("Location".into(), "/codeload/o-r-abc".into())], vec![]), ("/codeload/o-r-abc".into(), 200, vec![], data.clone())]);
        let g = Github::with_base(&f.base);
        let s = parse_source("o/r").unwrap();
        let mut r = g.download(&s, SHA).unwrap();
        let mut got = Vec::new();
        r.read_to_end(&mut got).unwrap();
        assert_eq!(got, data);
        assert!(f.hits.lock().unwrap().iter().any(|h| h == &format!("/repos/o/r/tarball/{SHA}")));
        // a ref is never downloaded: only a full sha
        assert!(g.download(&s, "main").is_err());
        assert!(g.download(&s, &SHA[..39]).is_err());
        assert!(g.download(&s, &SHA.to_uppercase()).is_err());
    }

    #[test]
    fn a_redirect_to_another_host_is_refused() {
        let f = fake(vec![("/repos/o/r/tarball".into(), 302, vec![("Location".into(), "http://evil.test/x".into())], vec![])]);
        let g = Github::with_base(&f.base);
        let e = g.download(&parse_source("o/r").unwrap(), SHA).err().expect("must fail");
        assert_eq!(e.code, "network");
    }

    #[test]
    fn resolve_download_stage_and_activate_end_to_end_against_a_fake_github() {
        use crate::addons::install::{stage, testutil::tarball};
        use serde_json::json;
        let tar = tarball(&[
            json!({"path": "agmsg-plugin.conf", "type": "file", "text": "name = x\n"}),
            json!({"path": "app-panes/main/addon.conf", "type": "file", "text": "title = E2E\nprotocol = 1\npermissions = files:read\nwhy.files:read = r\nopens = path\n"}),
            json!({"path": "app-panes/main/web/index.html", "type": "file", "text": "<div></div>"}),
        ]);
        let f = fake(vec![
            route("/repos/o/r", 200, r#"{"default_branch":"main","private":false}"#),
            route("/repos/o/r/commits/main", 200, SHA),
            ("/repos/o/r/tarball".into(), 302, vec![("Location".into(), "/dl/o-r-abc".into())], vec![]),
            ("/dl/o-r-abc".into(), 200, vec![], tar.clone()),
        ]);
        let g = Github::with_base(&f.base);
        let src = parse_source("o/r").unwrap();
        let sha = g.resolve(&src).unwrap();
        assert_eq!(sha, SHA);
        let body = g.download(&src, &sha).unwrap();
        let addons = tempfile::tempdir().unwrap();
        let staged = stage::stage(addons.path(), &src.slug(), &sha, body, "0.5.0", crate::addons::install::extract::Limits::default()).unwrap();
        assert_eq!(staged.archive_sha256, crate::addons::digest::sha256_hex(&tar), "the recorded archive hash is the hash of what GitHub sent");
        stage::activate(addons.path(), &staged, "2026-10-23T00:00:00Z").unwrap();
        let installed = crate::addons::index::read(addons.path());
        assert_eq!((installed[0].repo.as_str(), installed[0].sha.as_str()), ("o/r", SHA));
        // and it opens: pinned files, parsed conf
        let cat = crate::addons::catalog::Catalog::new(None, addons.path().to_path_buf());
        let r = cat.resolve("o/r", "main").unwrap();
        assert_eq!(r.conf.title, "E2E");
        assert!(r.pinned.contains_key("index.html"));
    }

    #[test]
    fn hosts_that_may_serve_a_download() {
        for h in ["github.com", "api.github.com", "codeload.github.com", "objects.githubusercontent.com", "raw.githubusercontent.com"] {
            assert!(host_allowed(h), "{h}");
        }
        for h in ["evil.test", "github.com.evil.test", "notgithub.com", "githubusercontent.com.evil.test", "127.0.0.1"] {
            assert!(!host_allowed(h), "{h}");
        }
    }
}
