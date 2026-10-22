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

/// The change of one add-on between two versions, pane by pane: what a pane
/// could do is decided per pane, so moving a network origin from pane B to
/// pane A, or giving pane A `network` while B already had it, is a change even
/// when the union over all panes stays the same.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct PaneDiffs {
    pub per_pane: Vec<(String, Diff)>,
    /// Panes the new version no longer has (their remembered grants go).
    pub removed_panes: Vec<String>,
    /// Union of the per-pane differences, for the one summary the dialog leads with.
    pub summary: Diff,
}

pub fn diff_panes(old: &[(String, PermSet)], new: &[(String, PermSet)]) -> PaneDiffs {
    let nothing = PermSet { permissions: Vec::new(), network: Network::None };
    let mut per_pane = Vec::new();
    let mut summary = Diff::default();
    for (name, n) in new {
        let o = old.iter().find(|(on, _)| on == name).map(|(_, p)| p).unwrap_or(&nothing);
        let d = diff(o, n);
        for a in &d.added {
            if !summary.added.contains(a) {
                summary.added.push(a.clone());
            }
        }
        for r in &d.removed {
            if !summary.removed.contains(r) {
                summary.removed.push(r.clone());
            }
        }
        summary.network_widened |= d.network_widened;
        summary.network_newly_combined |= d.network_newly_combined;
        per_pane.push((name.clone(), d));
    }
    let removed_panes = old.iter().filter(|(on, _)| !new.iter().any(|(n, _)| n == on)).map(|(n, _)| n.clone()).collect();
    PaneDiffs { per_pane, removed_panes, summary }
}

impl PaneDiffs {
    pub fn needs_confirm_again(&self) -> bool {
        self.per_pane.iter().any(|(_, d)| d.needs_confirm_again())
    }
}

/// The grants that survive an update to `new_sha`, rewritten to it: a grant stays
/// only if its own pane still exists, still has that permission, and did not
/// gain something that makes what it reads more dangerous.
pub fn migrate_grants(grants: Vec<SavedGrant>, repo: &str, new_sha: &str, d: &PaneDiffs) -> Vec<SavedGrant> {
    grants
        .into_iter()
        .filter_map(|mut g| {
            if g.repo != repo {
                return Some(g);
            }
            if d.removed_panes.contains(&g.pane) {
                return None;
            }
            let (_, pd) = d.per_pane.iter().find(|(n, _)| *n == g.pane)?;
            if pd.removed.contains(&g.permission) || pd.cleared_permissions().contains(&g.permission.as_str()) {
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

    fn one(old: &PermSet, new: &PermSet) -> PaneDiffs {
        diff_panes(&[("main".to_string(), old.clone())], &[("main".to_string(), new.clone())])
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
        let kept = migrate_grants(vec![grant("files:read", "/p"), grant("messages:read", "t")], "o/r", &"2".repeat(40), &one(&old, &ps(&["files:read"], Network::None)));
        assert_eq!(kept.len(), 2);
        assert!(kept.iter().all(|g| g.sha == "2".repeat(40)));
    }

    #[test]
    fn removed_permissions_drop_their_grants() {
        let d = one(&ps(&["files:read", "messages:read"], Network::None), &ps(&["files:read"], Network::None));
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
        let kept = migrate_grants(vec![grant("files:read", "/p"), grant("messages:read", "t")], "o/r", &"2".repeat(40), &one(&old, &wider));
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
        let d = one(&ps(&["files:read", "network"], origins(&["https://a.test"])), &ps(&["files:read", "network"], Network::Any));
        let mut other = grant("files:read", "/p");
        other.repo = "x/y".into();
        let kept = migrate_grants(vec![other.clone(), grant("files:read", "/p")], "o/r", &"2".repeat(40), &d);
        assert_eq!(kept, vec![other]);
    }

    fn pane_grant(pane: &str, perm: &str, scope: &str) -> SavedGrant {
        SavedGrant { pane: pane.into(), ..grant(perm, scope) }
    }

    #[test]
    fn network_given_to_the_pane_that_reads_is_a_change_even_when_the_union_is_unchanged() {
        // old: A reads files, B has network(*); new: A reads files AND has network(*) - the union is the same
        let old = [("a".to_string(), ps(&["files:read"], Network::None)), ("b".to_string(), ps(&["network"], Network::Any))];
        let new = [("a".to_string(), ps(&["files:read", "network"], Network::Any)), ("b".to_string(), ps(&["network"], Network::Any))];
        let d = diff_panes(&old, &new);
        assert!(d.needs_confirm_again(), "the dialog must ask again");
        assert!(d.summary.network_newly_combined);
        let a = &d.per_pane.iter().find(|(n, _)| n == "a").unwrap().1;
        assert!(a.network_newly_combined && a.added == vec!["network"]);
        let b = &d.per_pane.iter().find(|(n, _)| n == "b").unwrap().1;
        assert!(!b.needs_confirm_again());
        let kept = migrate_grants(vec![pane_grant("a", "files:read", "/p"), pane_grant("b", "files:read", "/q")], "o/r", &"2".repeat(40), &d);
        assert!(kept.iter().all(|g| g.pane != "a"), "pane a's read grant is voided: {kept:?}");
    }

    #[test]
    fn moving_a_network_origin_to_the_pane_that_reads_widens_that_pane() {
        let old = [("a".to_string(), ps(&["files:read", "network"], origins(&["https://x.test"]))), ("b".to_string(), ps(&["network"], origins(&["https://y.test"])))];
        let new = [("a".to_string(), ps(&["files:read", "network"], origins(&["https://x.test", "https://y.test"]))), ("b".to_string(), ps(&["network"], origins(&["https://x.test"])))];
        let d = diff_panes(&old, &new);
        assert!(d.needs_confirm_again());
        assert!(d.per_pane[0].1.network_widened, "a gained y.test");
        let kept = migrate_grants(vec![pane_grant("a", "files:read", "/p")], "o/r", &"2".repeat(40), &d);
        assert!(kept.is_empty());
    }

    #[test]
    fn an_unchanged_pane_keeps_its_grants_while_another_pane_changes() {
        let old = [("a".to_string(), ps(&["files:read"], Network::None)), ("b".to_string(), ps(&["files:read"], Network::None))];
        let new = [("a".to_string(), ps(&["files:read"], Network::None)), ("b".to_string(), ps(&["files:read", "network"], Network::Any))];
        let d = diff_panes(&old, &new);
        assert!(d.needs_confirm_again());
        let kept = migrate_grants(vec![pane_grant("a", "files:read", "/p"), pane_grant("b", "files:read", "/p")], "o/r", &"2".repeat(40), &d);
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].pane, "a");
        assert_eq!(kept[0].sha, "2".repeat(40));
    }

    #[test]
    fn new_and_removed_panes() {
        let old = [("a".to_string(), ps(&["files:read"], Network::None)), ("gone".to_string(), ps(&["files:read"], Network::None))];
        let new = [("a".to_string(), ps(&["files:read"], Network::None)), ("fresh".to_string(), ps(&["files:read", "network"], Network::Any))];
        let d = diff_panes(&old, &new);
        assert_eq!(d.removed_panes, vec!["gone"]);
        assert!(d.needs_confirm_again(), "a new pane that reads and sends asks");
        let kept = migrate_grants(vec![pane_grant("a", "files:read", "/p"), pane_grant("gone", "files:read", "/p"), pane_grant("unknown", "files:read", "/p")], "o/r", &"2".repeat(40), &d);
        assert_eq!(kept.iter().map(|g| g.pane.as_str()).collect::<Vec<_>>(), vec!["a"]);
        // a new harmless pane does not ask
        let d2 = diff_panes(&old[..1], &[("a".to_string(), ps(&["files:read"], Network::None)), ("viewer".to_string(), ps(&["files:read"], Network::None))]);
        assert!(d2.needs_confirm_again(), "any permission a pane did not have before is a change");
    }
}
