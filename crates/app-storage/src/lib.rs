//! Persistence, XDG paths, app identity, command journal, and structured logging.

pub mod build_info;
pub mod config;
pub mod identity;
pub mod journal;
pub mod logging;
pub mod paths;

pub use config::Config;
pub use identity::{AppIdentity, Profile};
pub use paths::AppPaths;
