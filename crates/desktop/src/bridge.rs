use core::pin::Pin;

use cxx_qt_lib::QString;
use kogaview_core::AppIdentity;
use kogaview_protocol::Workspace;

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
        #[qproperty(u64, stateRevision)]
        #[qproperty(QString, workspace)]
        #[qproperty(QString, statusMessage)]
        #[qproperty(u32, probeCount)]
        type KogaViewBridge = super::KogaViewBridgeRust;

        /// Temporary M0 probe: proves QML -> Rust invokable and property update.
        #[qinvokable]
        #[cxx_name = "devProbe"]
        fn dev_probe(self: Pin<&mut Self>, message: &QString);
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
    stateRevision: u64,
    workspace: QString,
    statusMessage: QString,
    probeCount: u32,
}

impl Default for KogaViewBridgeRust {
    fn default() -> Self {
        let identity = AppIdentity::current();
        Self {
            appName: identity.display_name.into(),
            appId: identity.app_id.into(),
            appVersion: identity.version.into(),
            profile: identity.profile.as_str().into(),
            gitSha: identity.git_sha.into(),
            protocolVersion: identity.protocol_version,
            stateRevision: 0,
            workspace: Workspace::Browser.as_str().into(),
            statusMessage: "M0 shell: command bus and image workspaces arrive in M1".into(),
            probeCount: 0,
        }
    }
}

impl qobject::KogaViewBridge {
    pub fn dev_probe(mut self: Pin<&mut Self>, message: &QString) {
        let next = *self.probeCount() + 1;
        self.as_mut().set_probeCount(next);
        tracing::info!(
            target: "kogaview::bridge",
            probe_message = %message,
            probe_count = next,
            "M0 bridge probe"
        );
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
