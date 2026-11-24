//! KogaView Core: Qt-independent domain, state ownership and orchestration.
//!
//! The UI, CLI, IPC and MCP adapters all submit the same `Envelope` commands to
//! one ordered gateway. Core owns state, revisions, the journal and all I/O.

pub mod batch;
pub mod core;
// The Editor, Storage, and Plugins are crates of their own now; Core re-exports
// them under the names the rest of this crate has always used, so every handler
// and external caller stays unchanged.
pub use kogaview_editor as editor;
pub use kogaview_plugins as plugins;
pub use kogaview_storage::{build_info, config, identity, journal, logging, paths};
pub mod ops;
pub mod ram_preview;
pub mod state;

pub use config::Config;
pub use core::Core;
pub use identity::{AppIdentity, Profile};
pub use paths::AppPaths;
pub use state::{Crumb, Entry, SelectionInfo, UiState};
