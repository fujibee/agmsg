//! What changes between two versions of an add-on, and what that does to the
//! grants a user remembered (design 2, "Update"):
//! - permissions equal or fewer, network not wider -> grants carry over;
//! - any new permission, a wider network list, or `network` newly combined with
//!   a read permission -> the confirm dialog asks again with the difference
//!   highlighted, and the grants of the read permissions are cleared.

use super::grants::SavedGrant;
use crate::addons::csp::Network;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PermSet {
    pub permissions: Vec<String>,
    pub network: Network,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Diff {
    pub added: Vec<String>,
    pub removed: Vec<String>,
    /// The new network list reaches somewhere the old one did not (including `*`).
    pub network_widened: bool,
    /// `network` is now combined with a read permission and was not before.
    pub network_newly_combined: bool,
}

const READ: [&str; 3] = ["messages:read", "files:read", "git:read"];

fn has_read(p: &[String]) -> bool {
    p.iter().any(|x| READ.contains(&x.as_str()))
}

fn has(p: &[String], k: &str) -> bool {
    p.iter().any(|x| x == k)
}

fn widened(old: &Network, new: &Network) -> bool {
    match (old, new) {
        (_, Network::None) => false,
        (Network::Any, _) => false,
        (_, Network::Any) => !matches!(old, Network::Any),
        (Network::None, Network::Origins(n)) => !n.is_empty(),
        (Network::Origins(o), Network::Origins(n)) => n.iter().any(|x| !o.contains(x)),
    }
}

pub fn diff(old: &PermSet, new: &PermSet) -> Diff {
    let added = new.permissions.iter().filter(|p| !has(&old.permissions, p)).cloned().collect();
    let removed = old.permissions.iter().filter(|p| !has(&new.permissions, p)).cloned().collect();
    let old_combined = has(&old.permissions, "network") && has_read(&old.permissions);
    let new_combined = has(&new.permissions, "network") && has_read(&new.permissions);
    Diff { added, removed, network_widened: has(&new.permissions, "network") && widened(&old.network, &new.network), network_newly_combined: new_combined && !old_combined }
}

impl Diff {
    /// The confirm dialog must ask again before the new version runs.
    pub fn needs_confirm_again(&self) -> bool {
        !self.added.is_empty() || self.network_widened || self.network_newly_combined
    }

    /// Remembered grants of these permissions are cleared on update.
    pub fn cleared_permissions(&self) -> Vec<&'static str> {
        if self.network_widened || self.network_newly_combined {
            READ.to_vec()
        } else {
            Vec::new()
        }
    }
}

/// The grants that survive an update to `new_sha`, rewritten to it.
pub fn migrate_grants(grants: Vec<SavedGrant>, repo: &str, new_sha: &str, d: &Diff) -> Vec<SavedGrant> {
    let cleared = d.cleared_permissions();
    grants
        .into_iter()
        .filter_map(|mut g| {
            if g.repo != repo {
                return Some(g);
            }
            if d.removed.contains(&g.permission) || cleared.contains(&g.permission.as_str()) {
                return None;
            }
            g.sha = new_sha.to_string();
            Some(g)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ps(p: &[&str], n: Network) -> PermSet {
        PermSet { permissions: p.iter().map(|s| s.to_string()).collect(), network: n }
    }

    fn origins(o: &[&str]) -> Network {
        Network::Origins(o.iter().map(|s| s.to_string()).collect())
    }

    fn grant(perm: &str, scope: &str) -> SavedGrant {
        SavedGrant { repo: "o/r".into(), sha: "1".repeat(40), pane: "main".into(), permission: perm.into(), scope: scope.into(), granted_at: "t".into() }
    }

    #[test]
    fn equal_or_fewer_permissions_carry_grants_over() {
        let old = ps(&["files:read", "git:read"], Network::None);
        for new in [ps(&["files:read", "git:read"], Network::None), ps(&["files:read"], Network::None), ps(&[], Network::None)] {
            let d = diff(&old, &new);
            assert!(!d.needs_confirm_again(), "{new:?}");
            assert!(d.cleared_permissions().is_empty());
        }
        let d = diff(&old, &ps(&["files:read"], Network::None));
        assert_eq!(d.removed, vec!["git:read"]);
        let kept = migrate_grants(vec![grant("files:read", "/p"), grant("messages:read", "t")], "o/r", &"2".repeat(40), &d);
        assert_eq!(kept.len(), 2);
        assert!(kept.iter().all(|g| g.sha == "2".repeat(40)));
    }

    #[test]
    fn removed_permissions_drop_their_grants() {
        let d = diff(&ps(&["files:read", "messages:read"], Network::None), &ps(&["files:read"], Network::None));
        let kept = migrate_grants(vec![grant("files:read", "/p"), grant("messages:read", "t")], "o/r", &"2".repeat(40), &d);
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].permission, "files:read");
    }

    #[test]
    fn a_new_permission_asks_again() {
        let d = diff(&ps(&["files:read"], Network::None), &ps(&["files:read", "messages:read"], Network::None));
        assert_eq!(d.added, vec!["messages:read"]);
        assert!(d.needs_confirm_again());
        assert!(d.cleared_permissions().is_empty(), "a new permission has no old grant to clear; the old ones stay");
    }

    #[test]
    fn a_wider_network_asks_again_and_clears_read_grants() {
        let old = ps(&["files:read", "network"], origins(&["https://a.test"]));
        let wider = ps(&["files:read", "network"], origins(&["https://a.test", "https://b.test"]));
        let d = diff(&old, &wider);
        assert!(d.network_widened && d.needs_confirm_again());
        assert_eq!(d.cleared_permissions(), vec!["messages:read", "files:read", "git:read"]);
        let any = diff(&old, &ps(&["files:read", "network"], Network::Any));
        assert!(any.network_widened);
        let kept = migrate_grants(vec![grant("files:read", "/p"), grant("messages:read", "t")], "o/r", &"2".repeat(40), &d);
        assert!(kept.is_empty());
        // narrower or equal does not
        assert!(!diff(&wider, &old).network_widened);
        assert!(!diff(&old, &old).network_widened);
        assert!(!diff(&ps(&["network"], Network::Any), &ps(&["network"], origins(&["https://a.test"]))).network_widened);
        assert!(!diff(&ps(&["network"], Network::Any), &ps(&["network"], Network::Any)).network_widened);
    }

    #[test]
    fn network_newly_combined_with_a_read_permission_asks_again() {
        // network alone first, then a read permission arrives
        let old = ps(&["network"], origins(&["https://a.test"]));
        let new = ps(&["network", "files:read"], origins(&["https://a.test"]));
        let d = diff(&old, &new);
        assert!(d.network_newly_combined && d.needs_confirm_again());
        // already combined before: not new
        let both = ps(&["network", "files:read"], origins(&["https://a.test"]));
        assert!(!diff(&both, &both).network_newly_combined);
        // network added while a read permission already existed
        let d = diff(&ps(&["files:read"], Network::None), &ps(&["files:read", "network"], origins(&["https://a.test"])));
        assert!(d.network_newly_combined && d.added == vec!["network"]);
    }

    #[test]
    fn other_add_ons_grants_are_untouched() {
        let d = diff(&ps(&["files:read", "network"], origins(&["https://a.test"])), &ps(&["files:read", "network"], Network::Any));
        let mut other = grant("files:read", "/p");
        other.repo = "x/y".into();
        let kept = migrate_grants(vec![other.clone(), grant("files:read", "/p")], "o/r", &"2".repeat(40), &d);
        assert_eq!(kept, vec![other]);
    }
}
