//! Structured, redaction-aware logging.
//!
//! Logs are newline-delimited JSON under the XDG state directory, with a
//! compact human-readable copy on stderr for development. The command journal
//! (M1) is separate and records sanitized command envelopes.

use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::{fmt, layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

use crate::{identity::AppIdentity, paths::AppPaths};

static LOG_GUARD: OnceLock<WorkerGuard> = OnceLock::new();

pub fn initialize() -> Result<(), String> {
    if LOG_GUARD.get().is_some() {
        return Ok(());
    }

    let paths = AppPaths::current();
    paths
        .ensure_runtime_dirs()
        .map_err(|error| format!("cannot create log directories: {error}"))?;

    let appender = tracing_appender::rolling::daily(&paths.log_dir, "kogaview.jsonl");
    let (writer, guard) = tracing_appender::non_blocking(appender);

    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,kogaview_core=debug,kogaview_desktop=debug"));

    tracing_subscriber::registry()
        .with(filter)
        .with(fmt::layer().json().with_ansi(false).with_writer(writer))
        .with(fmt::layer().compact().with_writer(std::io::stderr))
        .try_init()
        .map_err(|error| format!("cannot initialize tracing subscriber: {error}"))?;

    // Keep the appender worker alive for the process lifetime.
    let _ = LOG_GUARD.set(guard);
    Ok(())
}

pub fn log_startup() {
    let identity = AppIdentity::current();
    let paths = AppPaths::current();
    let boot_id = format!(
        "boot-{}-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_millis())
            .unwrap_or_default(),
        std::process::id()
    );

    tracing::info!(
        target: "kogaview::startup",
        app_id = identity.app_id,
        display_name = identity.display_name,
        profile = identity.profile.as_str(),
        version = identity.version,
        git_sha = identity.git_sha,
        protocol_version = identity.protocol_version,
        state_dir = %paths.state_dir.display(),
        log_dir = %paths.log_dir.display(),
        boot_id = %boot_id,
        "application starting"
    );
}

pub fn log_shutdown() {
    tracing::info!(target: "kogaview::startup", "application stopping");
}
