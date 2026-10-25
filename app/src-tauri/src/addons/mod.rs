//! App add-on panes. The pure building blocks (paths, diffs, CSP, digests,
//! navigation policy) live here with their tests; the pieces that touch the
//! window system (`host`, `engine`, `probe`) are thin.

pub mod broker;
pub mod catalog;
pub mod commands;
pub mod conf;
pub mod openreq;
pub mod csp;
pub mod denylist;
pub mod dotenv;
pub mod diff;
pub mod digest;
#[cfg(debug_assertions)]
pub mod e2e;
pub mod engine;
pub mod feed;
pub mod gate;
pub mod git;
pub mod host;
pub mod index;
pub mod install;
pub mod install_cmds;
pub mod nav;
pub mod panes;
pub mod server;
