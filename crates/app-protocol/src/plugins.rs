//! AI settings, plugin manifest, capability, translation, and task state types.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// Execution device preference for local AI plugins.
///
/// Defaults to `Cpu` so every desktop works out of the box without GPU driver
/// setup; `Auto` and `Gpu` attempt hardware acceleration and fall back to CPU
/// when unavailable or out of VRAM.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AiDevice {
    #[default]
    Cpu,
    Auto,
    Gpu,
}

impl AiDevice {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Cpu => "cpu",
            Self::Auto => "auto",
            Self::Gpu => "gpu",
        }
    }
}

/// Persisted AI plugin preferences stored in `config.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct AiSettings {
    pub device: AiDevice,
    /// Seconds of idle time before `PluginHost` shuts down a spawned worker to
    /// release RAM/VRAM (`10..=600`).
    pub auto_unload_secs: u32,
    /// Optional user-supplied local `.onnx` path overrides keyed by `model_id`.
    pub custom_model_paths: BTreeMap<String, String>,
}

impl Default for AiSettings {
    fn default() -> Self {
        Self {
            device: AiDevice::Cpu,
            auto_unload_secs: 60,
            custom_model_paths: BTreeMap::new(),
        }
    }
}

impl AiSettings {
    pub fn sanitized(mut self) -> Self {
        self.auto_unload_secs = self.auto_unload_secs.clamp(10, 600);
        self.custom_model_paths
            .retain(|k, v| !k.trim().is_empty() && !v.trim().is_empty());
        self
    }
}

/// Static plugin entry declaration inside `manifest.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginEntry {
    pub command: String,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default = "default_plugin_protocol")]
    pub protocol: String,
}

pub(crate) fn default_plugin_protocol() -> String {
    "jsonl-stdio".to_owned()
}

/// Declared plugin permissions in `manifest.json`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct PluginPermissions {
    pub network: bool,
    pub gpu: bool,
}

/// One downloadable/selectable AI model entry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginModelSpec {
    pub id: String,
    pub name: String,
    pub tier: String,
    pub file: String,
    pub size_bytes: u64,
    #[serde(default)]
    pub sha256: String,
    pub url: String,
}

/// One UI-configurable parameter declared by a plugin capability.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginParamSpec {
    pub key: String,
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub min: i32,
    #[serde(default)]
    pub max: i32,
    #[serde(default)]
    pub default: i32,
}

/// One capability exposed by a plugin.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginCapability {
    pub action: String,
    pub workspace: String,
    pub label: String,
    pub output: String,
    #[serde(default)]
    pub params: Vec<PluginParamSpec>,
}

/// One context-menu quick action contributed by a plugin's `manifest.json`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginQuickAction {
    pub id: String,
    pub label: String,
    pub action: String,
    /// Workspaces whose context menus should list this quick action
    /// (e.g. `["browser", "viewer"]`).
    #[serde(default)]
    pub workspaces: Vec<String>,
    /// Default parameters forwarded to the plugin when invoked (e.g. `{"modelId":"isnet-anime"}`).
    #[serde(default)]
    pub params: serde_json::Value,
}

/// Declarative `manifest.json` read by Core without spawning any process.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginManifest {
    pub api_version: u32,
    pub id: String,
    pub name: String,
    pub version: String,
    pub entry: PluginEntry,
    #[serde(default)]
    pub permissions: PluginPermissions,
    #[serde(default)]
    pub models: Vec<PluginModelSpec>,
    #[serde(default)]
    pub capabilities: Vec<PluginCapability>,
    #[serde(default)]
    pub quick_actions: Vec<PluginQuickAction>,
}

/// Live quick action published in `UiState` for shared Browser/Viewer context menus.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AiQuickAction {
    pub plugin_id: String,
    pub id: String,
    pub label: String,
    pub action: String,
    pub workspaces: Vec<String>,
    pub params: serde_json::Value,
    pub available: bool,
}

/// Live status of one AI model published in `UiState` for `Settings → AI` and Editor.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AiModelStatus {
    pub id: String,
    pub name: String,
    pub tier: String,
    pub size_bytes: u64,
    pub installed: bool,
    pub custom_path: Option<String>,
    pub effective_path: Option<String>,
}

/// Live status of one discovered plugin published in `UiState`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AiPluginStatus {
    pub id: String,
    pub name: String,
    pub version: String,
    pub available: bool,
    pub actions: Vec<String>,
    pub quick_actions: Vec<String>,
}

/// One translated text block in document pixel coordinates.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranslationBlock {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub original: String,
    pub translated: String,
}

/// Structured result returned by a Read & Translate plugin.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranslationResult {
    pub path: String,
    pub source_lang: String,
    pub target_lang: String,
    pub original_text: String,
    pub translated_text: String,
    #[serde(default)]
    pub blocks: Vec<TranslationBlock>,
}

/// Persisted translation overlay loaded from `<dir>/.kogaview/translation/<file>.json`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedTranslation {
    pub path: String,
    #[serde(default)]
    pub blocks: Vec<TranslationBlock>,
}

/// Active or most-recent AI background job (model download or inference).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AiTaskState {
    /// `"download"` | `"inference"` | `"translate"` | `""`
    pub kind: String,
    pub target: String,
    pub running: bool,
    pub percent: u8,
    pub stage: String,
    pub error: Option<String>,
    /// Optional text produced by a text-output plugin (e.g. OCR) for the shell
    /// to copy to the system clipboard.
    #[serde(default)]
    pub clipboard_text: Option<String>,
    /// Structured translation result produced by a Read & Translate plugin.
    #[serde(default)]
    pub translation: Option<TranslationResult>,
    /// Generated caption text returned by `editor.caption` / `caption.generate_save`.
    #[serde(default)]
    pub caption_text: Option<String>,
}

pub(crate) fn default_true() -> bool {
    true
}

pub(crate) fn default_crop_unit() -> String {
    "percent".to_owned()
}

pub(crate) fn default_canvas_anchor() -> String {
    "center".to_owned()
}
