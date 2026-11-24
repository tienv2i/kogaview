//! Sandbox-compatible XDG paths, namespaced by the application's short name.
//!
//! Paths are derived from environment variables so the Core stays independent
//! of Qt. Packaging and Flatpak must be able to redirect every root.
//!
//! Runtime directory names are `kogaview` (production) and `kogaview-dev`
//! (development); see `docs/adr/0002-runtime-directories-and-config.md`.

use std::path::PathBuf;

use crate::identity::AppIdentity;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppPaths {
    pub state_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub config_dir: PathBuf,
    pub data_dir: PathBuf,
    pub log_dir: PathBuf,
    pub journal_dir: PathBuf,
    pub screenshot_dir: PathBuf,
    pub plugins_dir: PathBuf,
    pub models_dir: PathBuf,
    pub ai_ipc_dir: PathBuf,
}

impl AppPaths {
    pub fn for_identity(identity: &AppIdentity) -> Self {
        let dir_name = identity.profile.dir_name();
        let state_dir = state_home().join(dir_name);
        let cache_dir = cache_home().join(dir_name);
        let data_dir = data_home().join(dir_name);
        let log_dir = state_dir.join("logs");
        let journal_dir = state_dir.join("journal");
        let screenshot_dir = state_dir.join("screenshots");
        let plugins_dir = data_dir.join("plugins");
        let models_dir = data_dir.join("models");
        let ai_ipc_dir = cache_dir.join("ai-ipc");
        Self {
            cache_dir,
            config_dir: config_home().join(dir_name),
            data_dir,
            state_dir,
            log_dir,
            journal_dir,
            screenshot_dir,
            plugins_dir,
            models_dir,
            ai_ipc_dir,
        }
    }

    pub fn current() -> Self {
        Self::for_identity(&AppIdentity::current())
    }

    /// Create the directories that must exist before startup logging.
    pub fn ensure_runtime_dirs(&self) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.log_dir)?;
        std::fs::create_dir_all(&self.journal_dir)?;
        Ok(())
    }
}

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

pub fn home_dir() -> PathBuf {
    env_path("HOME")
        .or_else(|| env_path("USERPROFILE"))
        .unwrap_or_else(std::env::temp_dir)
}

#[cfg(target_os = "windows")]
fn state_home() -> PathBuf {
    env_path("LOCALAPPDATA").unwrap_or_else(home_dir)
}

#[cfg(not(target_os = "windows"))]
fn state_home() -> PathBuf {
    env_path("XDG_STATE_HOME").unwrap_or_else(|| home_dir().join(".local/state"))
}

#[cfg(target_os = "windows")]
fn cache_home() -> PathBuf {
    env_path("LOCALAPPDATA").unwrap_or_else(home_dir)
}

#[cfg(not(target_os = "windows"))]
fn cache_home() -> PathBuf {
    env_path("XDG_CACHE_HOME").unwrap_or_else(|| home_dir().join(".cache"))
}

#[cfg(target_os = "windows")]
fn config_home() -> PathBuf {
    env_path("APPDATA").unwrap_or_else(home_dir)
}

#[cfg(not(target_os = "windows"))]
fn config_home() -> PathBuf {
    env_path("XDG_CONFIG_HOME").unwrap_or_else(|| home_dir().join(".config"))
}

#[cfg(target_os = "windows")]
fn data_home() -> PathBuf {
    env_path("LOCALAPPDATA").unwrap_or_else(home_dir)
}

#[cfg(not(target_os = "windows"))]
fn data_home() -> PathBuf {
    env_path("XDG_DATA_HOME").unwrap_or_else(|| home_dir().join(".local/share"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::Profile;

    fn identity(profile: Profile) -> AppIdentity {
        AppIdentity {
            profile,
            app_id: profile.app_id(),
            display_name: profile.display_name(),
            version: "0.0.0-test",
            git_sha: "test",
            protocol_version: 1,
        }
    }

    #[test]
    fn paths_use_the_short_application_name() {
        let dev = AppPaths::for_identity(&identity(Profile::Dev));
        assert!(dev.state_dir.ends_with("kogaview-dev"));
        assert!(dev.config_dir.ends_with("kogaview-dev"));
        assert!(dev.log_dir.ends_with("logs"));
        assert!(dev.journal_dir.ends_with("journal"));
        assert!(dev.screenshot_dir.ends_with("screenshots"));

        let prod = AppPaths::for_identity(&identity(Profile::Prod));
        assert!(prod.state_dir.ends_with("kogaview"));
        assert!(!prod.config_dir.ends_with("kogaview-dev"));
    }

    #[test]
    fn dev_and_prod_roots_differ() {
        let dev = AppPaths::for_identity(&identity(Profile::Dev));
        let prod = AppPaths::for_identity(&identity(Profile::Prod));
        assert_ne!(dev.state_dir, prod.state_dir);
        assert_ne!(dev.cache_dir, prod.cache_dir);
        assert_ne!(dev.config_dir, prod.config_dir);
        assert_ne!(dev.data_dir, prod.data_dir);
    }

    #[test]
    fn directory_names_are_single_path_components() {
        for profile in [Profile::Dev, Profile::Prod] {
            let name = profile.dir_name();
            assert_eq!(std::path::Path::new(name).components().count(), 1);
            assert!(!name.contains('/'));
        }
    }
}
