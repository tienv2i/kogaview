//! Application identity: dev and production builds never share state.

use crate::build_info;

pub const PROD_APP_ID: &str = "io.github.huynhat.KogaView";
pub const DEV_APP_ID: &str = "io.github.huynhat.KogaView.Dev";
pub const BASE_DISPLAY_NAME: &str = "KogaView";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Profile {
    Dev,
    Prod,
}

impl Profile {
    /// Debug builds are dev builds. A runtime override is accepted only in
    /// debug builds, for tests and screenshots.
    pub fn current() -> Self {
        if cfg!(debug_assertions) {
            if let Ok(value) = std::env::var("KOGAVIEW_PROFILE") {
                match value.as_str() {
                    "dev" => return Self::Dev,
                    "prod" => return Self::Prod,
                    _ => {}
                }
            }
            Self::Dev
        } else {
            Self::Prod
        }
    }

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Dev => "dev",
            Self::Prod => "prod",
        }
    }

    pub const fn app_id(self) -> &'static str {
        match self {
            Self::Dev => DEV_APP_ID,
            Self::Prod => PROD_APP_ID,
        }
    }

    pub const fn display_name(self) -> &'static str {
        match self {
            Self::Dev => "KogaView (Dev)",
            Self::Prod => BASE_DISPLAY_NAME,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppIdentity {
    pub profile: Profile,
    pub app_id: &'static str,
    pub display_name: &'static str,
    pub version: &'static str,
    pub git_sha: &'static str,
    pub protocol_version: u32,
}

impl AppIdentity {
    pub fn current() -> Self {
        let profile = Profile::current();
        Self {
            profile,
            app_id: profile.app_id(),
            display_name: profile.display_name(),
            version: build_info::VERSION,
            git_sha: build_info::GIT_SHA,
            protocol_version: kogaview_protocol::PROTOCOL_VERSION,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dev_and_prod_identities_are_distinct() {
        assert_ne!(DEV_APP_ID, PROD_APP_ID);
        assert_ne!(Profile::Dev.display_name(), Profile::Prod.display_name());
        assert!(Profile::Dev.display_name().ends_with("(Dev)"));
        assert_eq!(Profile::Prod.display_name(), BASE_DISPLAY_NAME);
    }

    #[test]
    fn app_ids_share_the_project_namespace() {
        assert!(DEV_APP_ID.starts_with(PROD_APP_ID));
        assert!(Profile::Dev.app_id().ends_with(".Dev"));
    }
}
