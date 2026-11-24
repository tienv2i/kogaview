//! KogaView Core: Qt-independent domain, state ownership and orchestration.
//!
//! The UI, CLI, IPC and MCP adapters all submit the same `Envelope` commands to
//! one ordered gateway. Core owns state, revisions, the journal and all I/O.

pub mod batch;
pub mod build_info;
pub mod config;
pub mod core;
// The Editor is a crate of its own now (`crates/app-editor`); Core re-exports it
// under the name the rest of this crate has always used, so `crate::editor::…`
// is unchanged for every handler and for the batch worker.
pub use kogaview_editor as editor;
pub mod identity;
pub mod journal;
pub mod logging;
pub mod ops;
pub mod paths;
pub mod plugins;
pub mod ram_preview;
pub mod state;

pub use config::Config;
pub use core::Core;
pub use identity::{AppIdentity, Profile};
pub use paths::AppPaths;
pub use state::{Crumb, Entry, SelectionInfo, UiState};
