//! Typed protocol shared by the UI, CLI, local IPC and MCP adapters.
//!
//! Commands are the only way to mutate Core state. Queries are read-only and
//! events are emitted by Core; they are separate types on purpose.

use serde::{Deserialize, Serialize};

mod command;
mod editor_types;
mod layout;
mod plugins;
#[cfg(test)]
mod tests;

pub use command::*;
pub use editor_types::*;
pub use layout::*;
pub use plugins::*;

/// Wire protocol version. Independent from the application semantic version.
pub const PROTOCOL_VERSION: u32 = 1;

/// A resize payload from before the transparent pad carried no alpha; its fill
/// was always opaque. Serde uses this when the field is absent.
pub(crate) fn opaque_fill_alpha() -> u8 {
    255
}

pub(crate) fn default_preserve_luminosity() -> bool {
    true
}

pub(crate) fn default_full_opacity() -> f32 {
    1.0
}

pub(crate) fn default_liquify_strength() -> f32 {
    0.5
}

/// Extensions the browser treats as images and the Editor decodes.
///
/// Kept here rather than in Core so every front end (the Qt file dialog now,
/// the CLI and the IPC/MCP adapters later) offers exactly the same list. The
/// decoders are compiled into or linked against the binary — nothing is fetched
/// at run time; AVIF's is the system libdav1d the `image` crate links — which is
/// what keeps a sandboxed Flatpak build able to open the same formats once that
/// library is carried with it. HEIC/HEIF are listed although no decoder exists
/// for them: hiding a modern phone format would be worse than saying "no
/// decoder" when one is opened. `.jpe` is a JPEG spelling `image` does not map
/// by name; it decodes by content sniffing.
pub const IMAGE_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "jpe", "jfif", "png", "webp", "gif", "bmp", "tif", "tiff", "avif", "heic",
    "heif", "dds", "exr", "hdr", "ico", "pnm", "pbm", "pgm", "ppm", "qoi", "tga", "ff", "ora",
    "kra",
];

/// The same list as a Qt file-dialog name filter (`Images (*.jpg …)`).
pub fn image_name_filter() -> String {
    let patterns: Vec<String> = IMAGE_EXTENSIONS
        .iter()
        .map(|extension| format!("*.{extension}"))
        .collect();
    format!("Images ({})", patterns.join(" "))
}

/// The three UI workspaces. Navigation is a Core concern, not QML state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Workspace {
    Browser,
    Viewer,
    Editor,
}

impl Workspace {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Browser => "browser",
            Self::Viewer => "viewer",
            Self::Editor => "editor",
        }
    }
}

impl Default for Workspace {
    fn default() -> Self {
        Self::Browser
    }
}
