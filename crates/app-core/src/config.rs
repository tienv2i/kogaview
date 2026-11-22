//! Persistent user configuration.
//!
//! The file lives at `$XDG_CONFIG_HOME/kogaview[-dev]/config.json` (see ADR
//! 0002). Writes are atomic: a temporary file in the same directory is written
//! and renamed over the target. A corrupt file is preserved for inspection and
//! replaced by defaults instead of preventing startup.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use kogaview_protocol::{Language, LayoutState, Theme};
use serde::{Deserialize, Serialize};

use crate::paths;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub theme: Theme,
    /// Interface language. `system` (the default) leaves the desktop locale in
    /// charge.
    pub language: Language,
    pub quick_access: Vec<String>,
    /// Folder the file list showed when the app last saved. Restored on the
    /// next start, independently from the explorer root below.
    pub last_folder: Option<String>,
    /// Folder the explorer tree was rooted at when the app last saved. It is
    /// **not** the folder that was open: the tree may be rooted higher up, so
    /// the user gets the same two-level view back (`~/Pictures` open in the
    /// sidebar, `~/Pictures/Child` in the list).
    pub tree_root: Option<String>,
    /// Which panels each workspace shows, the two dock widths and the Editor's
    /// split. Visibility used to be four booleans here; the fields below are
    /// what an older file meant and are read once, then dropped.
    pub layout: LayoutState,
    #[serde(
        rename = "left_panel",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub legacy_left_panel: Option<bool>,
    #[serde(
        rename = "right_panel",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub legacy_right_panel: Option<bool>,
    #[serde(
        rename = "right_panel_viewer",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub legacy_right_panel_viewer: Option<bool>,
    #[serde(
        rename = "right_panel_editor",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub legacy_right_panel_editor: Option<bool>,
    pub filmstrip: bool,
    pub remember_last_folder: bool,
    pub background_thumbnails: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            theme: Theme::Dark,
            language: Language::System,
            quick_access: default_quick_access(),
            last_folder: None,
            tree_root: None,
            layout: LayoutState::default(),
            legacy_left_panel: None,
            legacy_right_panel: None,
            legacy_right_panel_viewer: None,
            legacy_right_panel_editor: None,
            filmstrip: true,
            remember_last_folder: true,
            background_thumbnails: true,
        }
    }
}

impl Config {
    /// Load the configuration, repairing a missing or corrupt file.
    ///
    /// Returns the effective config plus an optional warning to log. The
    /// warning is never fatal: startup must succeed with defaults.
    pub fn load_or_create(path: &Path) -> (Self, Option<String>) {
        match fs::read_to_string(path) {
            Ok(text) => match serde_json::from_str::<Self>(&text) {
                Ok(config) => (config.sanitized(), None),
                Err(error) => {
                    let backup = path.with_extension("json.corrupt");
                    let _ = fs::copy(path, &backup);
                    let config = Self::default();
                    let warning = format!(
                        "config is corrupt ({error}); defaults restored, previous file kept at {}",
                        backup.display()
                    );
                    let _ = config.save(path);
                    (config, Some(warning))
                }
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let config = Self::default();
                let warning = config
                    .save(path)
                    .err()
                    .map(|error| format!("cannot create initial config: {error}"));
                (config, warning)
            }
            Err(error) => (
                Self::default(),
                Some(format!("cannot read config {}: {error}", path.display())),
            ),
        }
    }

    /// Drop entries that cannot be used and remove duplicates while preserving
    /// the user's order.
    fn sanitized(mut self) -> Self {
        let mut seen = std::collections::HashSet::new();
        self.quick_access.retain(|path| {
            let path = path.trim();
            !path.is_empty() && seen.insert(path.to_owned())
        });
        if self.quick_access.is_empty() {
            self.quick_access = default_quick_access();
        }
        // Four booleans used to say which docks were shown. A file written by
        // that build is read once — `false` hides that dock's panels — and the
        // fields are then dropped, so the next save carries only the layout.
        let legacy = (
            self.legacy_left_panel.take(),
            self.legacy_right_panel.take(),
            self.legacy_right_panel_viewer.take(),
            self.legacy_right_panel_editor.take(),
        );
        if legacy.0.is_some() || legacy.1.is_some() || legacy.2.is_some() || legacy.3.is_some() {
            self.layout = LayoutState::from_legacy(legacy.0, legacy.1, legacy.2, legacy.3);
        }
        self.layout = self.layout.sanitized();
        self
    }

    pub fn save(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp = path.with_extension("json.tmp");
        let json = serde_json::to_vec_pretty(self)
            .map_err(|error| std::io::Error::other(error.to_string()))?;
        {
            let mut file = fs::File::create(&tmp)?;
            file.write_all(&json)?;
            file.write_all(b"\n")?;
            file.sync_all()?;
        }
        fs::rename(&tmp, path)?;
        Ok(())
    }

    pub fn config_path(&self, config_dir: &Path) -> PathBuf {
        config_dir.join("config.json")
    }
}

fn default_quick_access() -> Vec<String> {
    let home = paths::home_dir();
    let mut entries = Vec::new();
    let pictures = home.join("Pictures");
    if pictures.is_dir() {
        entries.push(pictures.to_string_lossy().into_owned());
    }
    entries.push(home.to_string_lossy().into_owned());
    entries
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "kogaview-config-test-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn missing_config_is_created_with_defaults() {
        let dir = temp_dir();
        let path = dir.join("config.json");
        let (config, warning) = Config::load_or_create(&path);
        assert!(path.is_file());
        assert!(warning.is_none());
        assert_eq!(config.theme, Theme::Dark);
        assert!(!config.quick_access.is_empty());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn config_roundtrips_theme_and_favorites() {
        let dir = temp_dir();
        let path = dir.join("config.json");
        let mut config = Config::default();
        config.theme = Theme::Light;
        config.quick_access = vec!["/tmp".into(), "/home".into()];
        config.last_folder = Some("/tmp".into());
        config.layout = config.layout.with_panel("browser.preview", false);
        config.save(&path).unwrap();

        let (loaded, warning) = Config::load_or_create(&path);
        assert!(warning.is_none());
        assert_eq!(loaded, config);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn corrupt_config_is_backed_up_and_replaced() {
        let dir = temp_dir();
        let path = dir.join("config.json");
        fs::write(&path, "{not json").unwrap();
        let (config, warning) = Config::load_or_create(&path);
        assert!(warning.is_some());
        assert_eq!(config, Config::default());
        assert!(path.with_extension("json.corrupt").is_file());
        // The repaired file must be readable on the next start.
        let (reloaded, warning) = Config::load_or_create(&path);
        assert!(warning.is_none());
        assert_eq!(reloaded, config);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_older_configs_panel_flags_become_a_layout_once() {
        let dir = temp_dir();
        let path = dir.join("config.json");
        // The shape the previous build wrote: four booleans, no layout.
        fs::write(
            &path,
            r#"{"theme":"light","left_panel":false,"right_panel":true,
                "right_panel_viewer":false,"right_panel_editor":true}"#,
        )
        .unwrap();
        let (config, warning) = Config::load_or_create(&path);
        assert!(warning.is_none());
        assert_eq!(config.theme, Theme::Light);
        assert!(!config.layout.panel("browser.quickAccess"));
        assert!(!config.layout.panel("editor.explorer"));
        assert!(config.layout.panel("browser.preview"));
        assert!(!config.layout.panel("viewer.info"));
        assert!(config.layout.panel("editor.info"));
        // The flags are not written back: one source, the layout.
        config.save(&path).unwrap();
        let text = fs::read_to_string(&path).unwrap();
        assert!(!text.contains("left_panel"), "{text}");
        assert!(text.contains("\"layout\""), "{text}");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_saved_layout_survives_a_restart() {
        let dir = temp_dir();
        let path = dir.join("config.json");
        let mut config = Config::default();
        config.layout = config
            .layout
            .with_panel("editor.history", false)
            .with_panel("browser.explorer", false);
        config.layout.left_width = 321;
        config.layout.editor_reference_tab = "original".into();
        config.save(&path).unwrap();
        let (loaded, _) = Config::load_or_create(&path);
        assert!(!loaded.layout.panel("editor.history"));
        assert!(!loaded.layout.panel("browser.explorer"));
        assert!(loaded.layout.panel("editor.info"));
        assert_eq!(loaded.layout.left_width, 321);
        assert_eq!(loaded.layout.editor_reference_tab, "original");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_layout_is_clamped_when_it_is_loaded() {
        let dir = temp_dir();
        let path = dir.join("config.json");
        fs::write(
            &path,
            r#"{"layout":{"leftWidth":9,"rightWidth":4000,
                 "editorToolColumns":9,"editorReferenceHeight":99999,
                 "editorReferenceTab":"nope",
                 "panels":{"editor.tools":false,"not.a.panel":false}}}"#,
        )
        .unwrap();
        let (config, _) = Config::load_or_create(&path);
        assert_eq!(config.layout.left_width, 180);
        assert_eq!(config.layout.right_width, 640);
        assert_eq!(config.layout.editor_tool_columns, 2);
        assert_eq!(config.layout.editor_reference_height, 900);
        assert_eq!(config.layout.editor_reference_tab, "info");
        assert!(!config.layout.panel("editor.tools"));
        assert!(config.layout.panel("editor.options"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn save_is_atomic_and_leaves_no_tmp_file() {
        let dir = temp_dir();
        let path = dir.join("config.json");
        Config::default().save(&path).unwrap();
        assert!(path.is_file());
        assert!(!path.with_extension("json.tmp").exists());
        fs::remove_dir_all(dir).unwrap();
    }
}
