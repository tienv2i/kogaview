//! Compile-time build metadata for diagnostics and startup logs.

/// Semantic version from Cargo.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Short git SHA captured by `build.rs`, or `unknown` outside a git checkout.
pub const GIT_SHA: &str = match option_env!("KOGAVIEW_GIT_SHA") {
    Some(sha) => sha,
    None => "unknown",
};

/// Cargo build profile.
pub const BUILD_PROFILE: &str = if cfg!(debug_assertions) {
    "debug"
} else {
    "release"
};
