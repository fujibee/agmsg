//! Install pipeline for add-ons (design 3.1): checked extraction, layout checks,
//! staging, atomic activation. Network access lives in `github` only.

pub mod extract;
pub mod layout;
pub mod tree;
