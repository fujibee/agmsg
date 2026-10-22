//! Pure building blocks of the app add-on broker. Nothing here touches the
//! network, spawns a process or reads outside the paths a caller hands in.

pub mod denylist;
pub mod diff;
pub mod git;
