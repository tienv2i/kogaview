//! KogaView Core: Qt-independent domain, state ownership and orchestration.
//!
//! M0 contains identity, XDG paths, build metadata and structured logging.
//! AppState, the command gateway and handlers arrive in M1.

pub mod build_info;
pub mod identity;
pub mod logging;
pub mod paths;

pub use identity::{AppIdentity, Profile};
pub use paths::AppPaths;
