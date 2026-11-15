//! KogaView Core: Qt-independent domain, state ownership and orchestration.
//!
//! The UI, CLI, IPC and MCP adapters all submit the same `Envelope` commands to
//! one ordered gateway. Core owns state, revisions, the journal and all I/O.

pub mod build_info;
pub mod config;
pub mod core;
pub mod identity;
pub mod journal;
pub mod logging;
pub mod ops;
pub mod paths;
pub mod state;

pub use config::Config;
pub use core::Core;
pub use identity::{AppIdentity, Profile};
pub use paths::AppPaths;
pub use state::{Crumb, Entry, SelectionInfo, UiState};
