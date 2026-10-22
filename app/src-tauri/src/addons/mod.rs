//! App add-on panes. The pure building blocks (paths, diffs, CSP, digests,
//! navigation policy) live here with their tests; the pieces that touch the
//! window system (`host`, `engine`, `probe`) are thin.

pub mod broker;
pub mod commands;
pub mod csp;
pub mod denylist;
pub mod diff;
pub mod digest;
pub mod engine;
pub mod feed;
pub mod gate;
pub mod host;
pub mod nav;
pub mod panes;
pub mod server;
