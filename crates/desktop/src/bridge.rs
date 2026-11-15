//! Qt adapter: exposes Core state as a JSON snapshot plus the single command
//! gateway. QML never mutates domain state directly.
//!
//! Commands are submitted as serialized protocol envelopes and results are
//! returned as JSON. The whole state snapshot is re-published after every
//! command or completed background task so QML has one authoritative source.

use core::pin::Pin;

use cxx_qt::CxxQtType;
use cxx_qt_lib::QString;
use kogaview_core::{AppIdentity, Core};
use kogaview_protocol::PROTOCOL_VERSION;

#[cxx_qt::bridge]
pub mod qobject {
    unsafe extern "C++" {
        include!("cxx-qt-lib/qstring.h");
        type QString = cxx_qt_lib::QString;
    }

    extern "Rust" {
        fn kogaview_initialize() -> bool;
        fn kogaview_shutdown();
        fn kogaview_app_id() -> QString;
        fn kogaview_display_name() -> QString;
        fn kogaview_app_version() -> QString;
    }

    extern "RustQt" {
        #[qobject]
        #[qml_element]
        #[qproperty(QString, appName)]
        #[qproperty(QString, appId)]
        #[qproperty(QString, appVersion)]
        #[qproperty(QString, profile)]
        #[qproperty(QString, gitSha)]
        #[qproperty(u32, protocolVersion)]
        #[qproperty(QString, stateJson)]
        #[qproperty(QString, statusMessage)]
        #[qproperty(bool, busy)]
        #[qproperty(u64, revision)]
        type KogaViewBridge = super::KogaViewBridgeRust;

        /// Submit one typed command envelope. Returns a JSON result.
        #[qinvokable]
        #[cxx_name = "dispatch"]
        fn dispatch(self: Pin<&mut Self>, command_json: &QString) -> QString;

        /// Run one read-only query. Returns a JSON result.
        #[qinvokable]
        #[cxx_name = "query"]
        fn query(self: Pin<&mut Self>, query_json: &QString) -> QString;

        /// Deliver completed background work. True when state changed.
        #[qinvokable]
        #[cxx_name = "poll"]
        fn poll(self: Pin<&mut Self>) -> bool;
    }
}

#[allow(non_snake_case)]
pub struct KogaViewBridgeRust {
    appName: QString,
    appId: QString,
    appVersion: QString,
    profile: QString,
    gitSha: QString,
    protocolVersion: u32,
    stateJson: QString,
    statusMessage: QString,
    busy: bool,
    revision: u64,
    core: Core,
}

impl Default for KogaViewBridgeRust {
    fn default() -> Self {
        let identity = AppIdentity::current();
        let core = Core::new();
        Self {
            appName: identity.display_name.into(),
            appId: identity.app_id.into(),
            appVersion: identity.version.into(),
            profile: identity.profile.as_str().into(),
            gitSha: identity.git_sha.into(),
            protocolVersion: PROTOCOL_VERSION,
            stateJson: core.snapshot_json().into(),
            statusMessage: core.status().into(),
            busy: core.busy(),
            revision: core.revision(),
            core,
        }
    }
}

impl qobject::KogaViewBridge {
    pub fn dispatch(mut self: Pin<&mut Self>, command_json: &QString) -> QString {
        let command = command_json.to_string();
        let result = self.as_mut().rust_mut().get_mut().core.dispatch(&command);
        self.refresh_properties();
        result.into()
    }

    pub fn query(mut self: Pin<&mut Self>, query_json: &QString) -> QString {
        let query = query_json.to_string();
        self.as_mut()
            .rust_mut()
            .get_mut()
            .core
            .query_json(&query)
            .into()
    }

    pub fn poll(mut self: Pin<&mut Self>) -> bool {
        let changed = self.as_mut().rust_mut().get_mut().core.poll();
        if changed {
            self.refresh_properties();
        }
        changed
    }

    fn refresh_properties(mut self: Pin<&mut Self>) {
        let (state, status, busy, revision) = {
            let this = self.as_mut().rust_mut().get_mut();
            (
                this.core.snapshot_json(),
                this.core.status().to_owned(),
                this.core.busy(),
                this.core.revision(),
            )
        };
        self.as_mut().set_stateJson(state.into());
        self.as_mut().set_statusMessage(status.into());
        self.as_mut().set_busy(busy);
        self.as_mut().set_revision(revision);
    }
}

/// Initialize non-Qt infrastructure before the QML engine starts.
pub fn kogaview_initialize() -> bool {
    match kogaview_core::logging::initialize() {
        Ok(()) => {
            kogaview_core::logging::log_startup();
            true
        }
        Err(error) => {
            eprintln!("kogaview: logging initialization failed: {error}");
            false
        }
    }
}

pub fn kogaview_shutdown() {
    kogaview_core::logging::log_shutdown();
}

pub fn kogaview_app_id() -> QString {
    AppIdentity::current().app_id.into()
}

pub fn kogaview_display_name() -> QString {
    AppIdentity::current().display_name.into()
}

pub fn kogaview_app_version() -> QString {
    AppIdentity::current().version.into()
}
