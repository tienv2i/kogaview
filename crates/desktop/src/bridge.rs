//! Qt adapter: exposes Core state as a JSON snapshot plus the single command
//! gateway. QML never mutates domain state directly.
//!
//! Commands are submitted as serialized protocol envelopes and results are
//! returned as JSON. The state snapshot is re-published after every command or
//! completed background task so QML has one authoritative source.

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
        /// Cache root for this profile (`$XDG_CACHE_HOME/kogaview[-dev]`).
        /// Owned by Core so the C++ side never re-derives the naming rule.
        fn kogaview_cache_dir() -> QString;
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
        /// The folder listing on its own — `{ entries, viewerImages }` — shipped
        /// only when `listingEpoch` moves. It is the only part of the snapshot
        /// that grows with the folder (a thousand photos is a 200 KB string), so
        /// re-publishing it on every selection change would cost every command a
        /// full serialise, a 200 KB copy and a 200 KB JSON parse in QML.
        #[qproperty(QString, listingJson)]
        #[qproperty(u64, listingEpoch)]
        #[qproperty(QString, statusMessage)]
        #[qproperty(bool, busy)]
        #[qproperty(u64, revision)]
        /// The configured interface language. It only exists so the C++ side
        /// can tell when the settings changed it; the translations themselves
        /// live in Qt.
        #[qproperty(QString, language)]
        type KogaViewBridge = super::KogaViewBridgeRust;

        /// Publish a fresh snapshot after a language change, so QML rebuilds
        /// the views with the new strings.
        #[qinvokable]
        #[cxx_name = "retranslate"]
        fn retranslate(self: Pin<&mut Self>);

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
    listingJson: QString,
    listingEpoch: u64,
    statusMessage: QString,
    busy: bool,
    revision: u64,
    language: QString,
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
            stateJson: core.meta_json().into(),
            listingJson: core.folder_json().into(),
            listingEpoch: core.listing_epoch(),
            statusMessage: core.status().into(),
            busy: core.busy(),
            revision: core.revision(),
            language: core.language().into(),
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
        // The listing is only re-serialised when its epoch moved, which is what
        // keeps a `select` — one click, one arrow key — as cheap in a folder of
        // five thousand photos as in a folder of five.
        let (listing_changed, listing_epoch, listing_json, state, status, busy, revision, language) = {
            let this = self.as_mut().rust_mut().get_mut();
            let epoch = this.core.listing_epoch();
            let changed = epoch != this.listingEpoch;
            (
                changed,
                epoch,
                if changed {
                    this.core.folder_json()
                } else {
                    String::new()
                },
                this.core.meta_json(),
                this.core.status().to_owned(),
                this.core.busy(),
                this.core.revision(),
                this.core.language().to_owned(),
            )
        };

        if listing_changed {
            self.as_mut().set_listingJson(listing_json.into());
            self.as_mut().set_listingEpoch(listing_epoch);
        }
        self.as_mut().set_stateJson(state.into());
        self.as_mut().set_statusMessage(status.into());
        self.as_mut().set_busy(busy);
        self.as_mut().set_revision(revision);
        self.as_mut().set_language(language.into());
    }

    pub fn retranslate(mut self: Pin<&mut Self>) {
        self.as_mut().refresh_properties();
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

pub fn kogaview_cache_dir() -> QString {
    kogaview_core::AppPaths::current()
        .cache_dir
        .to_string_lossy()
        .into_owned()
        .into()
}
