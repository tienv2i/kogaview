//! Out-of-process AI Plugin Host & On-Demand Model Manager (ADR 0024).
//!
//! Design invariants:
//! - **Zero startup cost**: `discover_plugins()` only reads small static
//!   `manifest.json` files. No AI runtime or model is loaded until the user
//!   explicitly invokes an AI command.
//! - **Language-agnostic `jsonl-stdio` contract**: plugins can be written in
//!   Rust (`ort` / ONNX Runtime), Python, C++, or any executable that reads
//!   JSON Lines on `stdin` and writes JSON Lines on `stdout`.
//! - **Non-destructive**: plugins read a temporary input PNG and write a
//!   temporary output PNG; Core validates and applies the result onto
//!   `EditorDocument` as an undoable `EditOperation::AiResult`.

use std::collections::HashSet;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command as ProcessCommand, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Sender;
use std::sync::Arc;
use std::time::{Duration, Instant};

use kogaview_protocol::{
    AiDevice, AiModelStatus, AiPluginStatus, AiQuickAction, AiSettings, PluginCapability,
    PluginEntry, PluginManifest, PluginModelSpec, PluginParamSpec, PluginPermissions,
    PluginQuickAction, TranslationResult,
};
use serde_json::{json, Value};

/// Stable ID of the official Rust ONNX Remove Background plugin.
pub const REMBG_PLUGIN_ID: &str = "kogaview.rmbg.onnx";
pub const REMBG_ACTION: &str = "editor.remove_background";

/// Built-in on-demand catalog for `rembg`-compatible ONNX models.
/// None of these files are bundled with KogaView; users download only what
/// they want into `$XDG_DATA_HOME/kogaview[-dev]/models/` (or point to a local
/// `.onnx` file).
pub fn builtin_rembg_models() -> Vec<PluginModelSpec> {
    vec![
        PluginModelSpec {
            id: "u2netp".to_owned(),
            name: "U²-Net Lite (Fast)".to_owned(),
            tier: "fast".to_owned(),
            file: "u2netp.onnx".to_owned(),
            size_bytes: 4_716_000,
            sha256: String::new(),
            url: "https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2netp.onnx"
                .to_owned(),
        },
        PluginModelSpec {
            id: "silueta".to_owned(),
            name: "Silueta (Fast)".to_owned(),
            tier: "fast".to_owned(),
            file: "silueta.onnx".to_owned(),
            size_bytes: 44_200_000,
            sha256: String::new(),
            url: "https://github.com/danielgatis/rembg/releases/download/v0.0.0/silueta.onnx"
                .to_owned(),
        },
        PluginModelSpec {
            id: "rmbg-1.4".to_owned(),
            name: "BRIA RMBG-1.4 (Balanced)".to_owned(),
            tier: "balanced".to_owned(),
            file: "rmbg-1.4.onnx".to_owned(),
            size_bytes: 44_500_000,
            sha256: String::new(),
            url: "https://huggingface.co/briaai/RMBG-1.4/resolve/main/onnx/model_quantized.onnx"
                .to_owned(),
        },
        PluginModelSpec {
            id: "isnet-general-use".to_owned(),
            name: "IS-Net General (High)".to_owned(),
            tier: "high".to_owned(),
            file: "isnet-general-use.onnx".to_owned(),
            size_bytes: 176_000_000,
            sha256: String::new(),
            url: "https://github.com/danielgatis/rembg/releases/download/v0.0.0/isnet-general-use.onnx"
                .to_owned(),
        },
        PluginModelSpec {
            id: "isnet-anime".to_owned(),
            name: "IS-Net Anime (Anime)".to_owned(),
            tier: "anime".to_owned(),
            file: "isnet-anime.onnx".to_owned(),
            size_bytes: 176_000_000,
            sha256: String::new(),
            url: "https://github.com/danielgatis/rembg/releases/download/v0.0.0/isnet-anime.onnx"
                .to_owned(),
        },
        PluginModelSpec {
            id: "birefnet-general-lite".to_owned(),
            name: "BiRefNet Lite (High)".to_owned(),
            tier: "high".to_owned(),
            file: "birefnet-general-lite.onnx".to_owned(),
            size_bytes: 214_000_000,
            sha256: String::new(),
            url: "https://github.com/danielgatis/rembg/releases/download/v0.0.0/BiRefNet-general-bb_swin_v1_tiny-epoch_232.onnx"
                .to_owned(),
        },
        PluginModelSpec {
            id: "u2net_human_seg".to_owned(),
            name: "U²-Net Human (Portrait)".to_owned(),
            tier: "portrait".to_owned(),
            file: "u2net_human_seg.onnx".to_owned(),
            size_bytes: 176_000_000,
            sha256: String::new(),
            url: "https://github.com/danielgatis/rembg/releases/download/v0.0.0/u2net_human_seg.onnx"
                .to_owned(),
        },
        PluginModelSpec {
            id: "birefnet-portrait".to_owned(),
            name: "BiRefNet Portrait (Portrait)".to_owned(),
            tier: "portrait".to_owned(),
            file: "birefnet-portrait.onnx".to_owned(),
            size_bytes: 973_000_000,
            sha256: String::new(),
            url: "https://github.com/danielgatis/rembg/releases/download/v0.0.0/BiRefNet-portrait-epoch_150.onnx"
                .to_owned(),
        },
    ]
}

pub fn builtin_rembg_quick_actions() -> Vec<PluginQuickAction> {
    vec![
        PluginQuickAction {
            id: "rembg-general".to_owned(),
            label: "Remove background (General)".to_owned(),
            action: REMBG_ACTION.to_owned(),
            workspaces: vec!["browser".to_owned(), "viewer".to_owned()],
            params: json!({ "modelId": "rmbg-1.4", "feather": 0 }),
        },
        PluginQuickAction {
            id: "rembg-anime".to_owned(),
            label: "Remove background (Anime)".to_owned(),
            action: REMBG_ACTION.to_owned(),
            workspaces: vec!["browser".to_owned(), "viewer".to_owned()],
            params: json!({ "modelId": "isnet-anime", "feather": 0 }),
        },
    ]
}

/// A plugin discovered on disk (or as a sibling worker binary next to `kogaview`).
#[derive(Debug, Clone)]
pub struct DiscoveredPlugin {
    pub manifest: PluginManifest,
    pub root_dir: PathBuf,
    pub executable: PathBuf,
    pub available: bool,
}

/// Progress/completion events emitted by a background AI task (download or inference).
#[derive(Debug, Clone)]
pub enum AiWorkerEvent {
    Progress {
        percent: u8,
        stage: String,
    },
    DownloadDone {
        model_id: String,
        path: PathBuf,
    },
    InferenceDone {
        model_id: String,
        output_path: PathBuf,
        device_used: String,
        clipboard_text: Option<String>,
        translation: Option<TranslationResult>,
    },
    Failed {
        message: String,
    },
    Cancelled,
}

/// Scan `plugins_dir/*/manifest.json` without spawning any process.
/// Also checks for a sibling `kogaview-plugin-rembg` executable next to the
/// running binary so dev/installed setups work automatically without manual
/// copying.
pub fn discover_plugins(plugins_dir: &Path) -> Vec<DiscoveredPlugin> {
    let mut found = Vec::new();
    let mut seen_ids = HashSet::new();

    if let Ok(entries) = fs::read_dir(plugins_dir) {
        let mut dirs: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.is_dir())
            .collect();
        dirs.sort();

        for dir in dirs {
            let manifest_path = dir.join("manifest.json");
            let Ok(text) = fs::read_to_string(&manifest_path) else {
                continue;
            };
            let Ok(manifest) = serde_json::from_str::<PluginManifest>(&text) else {
                tracing::warn!(
                    target: "kogaview::plugins",
                    path = %manifest_path.display(),
                    "skipping invalid plugin manifest"
                );
                continue;
            };
            if manifest.api_version != 1 {
                tracing::warn!(
                    target: "kogaview::plugins",
                    id = %manifest.id,
                    api_version = manifest.api_version,
                    "skipping plugin with unsupported apiVersion"
                );
                continue;
            }
            let cmd = PathBuf::from(&manifest.entry.command);
            let executable = if cmd.is_absolute() {
                cmd
            } else {
                dir.join(cmd)
            };
            let available = executable.is_file();
            seen_ids.insert(manifest.id.clone());
            found.push(DiscoveredPlugin {
                manifest,
                root_dir: dir,
                executable,
                available,
            });
        }
    }

    // Fallback discovery: look for the official `kogaview-plugin-rembg` binary
    // installed beside the `kogaview` executable or in `/usr/local/libexec`.
    if !seen_ids.contains(REMBG_PLUGIN_ID) {
        let exe_name = if cfg!(windows) {
            "kogaview-plugin-rembg.exe"
        } else {
            "kogaview-plugin-rembg"
        };
        let mut candidates = Vec::new();
        if let Ok(current) = std::env::current_exe() {
            if let Some(parent) = current.parent() {
                candidates.push(parent.join(exe_name));
            }
        }
        candidates.push(PathBuf::from("/usr/local/libexec").join(exe_name));
        candidates.push(PathBuf::from("/usr/libexec").join(exe_name));

        let found_exe = candidates.into_iter().find(|p| p.is_file());
        let (root_dir, executable, available) = match found_exe {
            Some(path) => (
                path.parent().unwrap_or(plugins_dir).to_path_buf(),
                path,
                true,
            ),
            None => (
                plugins_dir.join("kogaview-rmbg-onnx"),
                plugins_dir
                    .join("kogaview-rmbg-onnx")
                    .join("bin")
                    .join(exe_name),
                false,
            ),
        };
        found.push(DiscoveredPlugin {
            manifest: PluginManifest {
                api_version: 1,
                id: REMBG_PLUGIN_ID.to_owned(),
                name: "Remove Background (ONNX)".to_owned(),
                version: env!("CARGO_PKG_VERSION").to_owned(),
                entry: PluginEntry {
                    command: executable.display().to_string(),
                    args: vec!["--device".to_owned(), "${device}".to_owned()],
                    protocol: "jsonl-stdio".to_owned(),
                },
                permissions: PluginPermissions {
                    network: false,
                    gpu: true,
                },
                models: builtin_rembg_models(),
                capabilities: vec![PluginCapability {
                    action: REMBG_ACTION.to_owned(),
                    workspace: "editor".to_owned(),
                    label: "Remove background".to_owned(),
                    output: "rgba_image".to_owned(),
                    params: vec![PluginParamSpec {
                        key: "feather".to_owned(),
                        kind: "int".to_owned(),
                        min: 0,
                        max: 20,
                        default: 0,
                    }],
                }],
                quick_actions: builtin_rembg_quick_actions(),
            },
            root_dir,
            executable,
            available,
        });
    }

    found
}

/// Collect all known models (built-in catalog + any models declared in plugin
/// manifests) and resolve whether each is installed on disk or overridden by a
/// user-provided `.onnx` path.
pub fn catalog_models(plugins: &[DiscoveredPlugin]) -> Vec<PluginModelSpec> {
    let mut specs = builtin_rembg_models();
    let mut seen: HashSet<String> = specs.iter().map(|m| m.id.clone()).collect();
    for plugin in plugins {
        for model in &plugin.manifest.models {
            if seen.insert(model.id.clone()) {
                specs.push(model.clone());
            }
        }
    }
    specs
}

pub fn model_statuses(
    models_dir: &Path,
    settings: &AiSettings,
    plugins: &[DiscoveredPlugin],
) -> Vec<AiModelStatus> {
    catalog_models(plugins)
        .into_iter()
        .map(|spec| {
            let custom_path = settings
                .custom_model_paths
                .get(&spec.id)
                .filter(|p| !p.trim().is_empty())
                .cloned();
            let effective = if let Some(custom) = &custom_path {
                let p = PathBuf::from(custom);
                p.is_file().then_some(p)
            } else {
                let p = models_dir.join(&spec.file);
                p.is_file().then_some(p)
            };
            AiModelStatus {
                id: spec.id,
                name: spec.name,
                tier: spec.tier,
                size_bytes: spec.size_bytes,
                installed: effective.is_some(),
                custom_path,
                effective_path: effective.map(|p| p.display().to_string()),
            }
        })
        .collect()
}

pub fn plugin_statuses(plugins: &[DiscoveredPlugin]) -> Vec<AiPluginStatus> {
    plugins
        .iter()
        .map(|p| AiPluginStatus {
            id: p.manifest.id.clone(),
            name: p.manifest.name.clone(),
            version: p.manifest.version.clone(),
            available: p.available,
            actions: p
                .manifest
                .capabilities
                .iter()
                .map(|c| c.action.clone())
                .collect(),
            quick_actions: p
                .manifest
                .quick_actions
                .iter()
                .map(|q| q.label.clone())
                .collect(),
        })
        .collect()
}

pub fn quick_actions(plugins: &[DiscoveredPlugin]) -> Vec<AiQuickAction> {
    let mut list = Vec::new();
    for plugin in plugins {
        for qa in &plugin.manifest.quick_actions {
            list.push(AiQuickAction {
                plugin_id: plugin.manifest.id.clone(),
                id: qa.id.clone(),
                label: qa.label.clone(),
                action: qa.action.clone(),
                workspaces: qa.workspaces.clone(),
                params: qa.params.clone(),
                available: plugin.available,
            });
        }
    }
    list
}

/// Download a model on demand into `models_dir/<spec.file>` with progress and
/// cancellation support. Uses atomic `.part` rename so a cancelled or failed
/// download never leaves a corrupt `.onnx` file behind.
pub fn download_model(
    spec: &PluginModelSpec,
    models_dir: &Path,
    cancel: Arc<AtomicBool>,
    tx: &Sender<AiWorkerEvent>,
) {
    if let Err(error) = fs::create_dir_all(models_dir) {
        let _ = tx.send(AiWorkerEvent::Failed {
            message: format!("cannot create models directory: {error}"),
        });
        return;
    }

    let final_path = models_dir.join(&spec.file);
    let part_path = models_dir.join(format!("{}.part", spec.file));
    let _ = fs::remove_file(&part_path);

    let _ = tx.send(AiWorkerEvent::Progress {
        percent: 0,
        stage: format!("Downloading {}…", spec.name),
    });

    let mut child = match ProcessCommand::new("curl")
        .arg("-fSL")
        .arg("--connect-timeout")
        .arg("15")
        .arg("--output")
        .arg(&part_path)
        .arg(&spec.url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(error) => {
            let _ = tx.send(AiWorkerEvent::Failed {
                message: format!("cannot start curl to download model: {error}"),
            });
            return;
        }
    };

    let mut last_percent = 0u8;
    loop {
        if cancel.load(Ordering::SeqCst) {
            let _ = child.kill();
            let _ = child.wait();
            let _ = fs::remove_file(&part_path);
            let _ = tx.send(AiWorkerEvent::Cancelled);
            return;
        }

        if spec.size_bytes > 0 {
            if let Ok(meta) = fs::metadata(&part_path) {
                let pct =
                    ((meta.len() as f64 / spec.size_bytes as f64) * 99.0).clamp(0.0, 99.0) as u8;
                if pct > last_percent {
                    last_percent = pct;
                    let _ = tx.send(AiWorkerEvent::Progress {
                        percent: pct,
                        stage: format!("Downloading {} ({pct}%)…", spec.name),
                    });
                }
            }
        }

        match child.try_wait() {
            Ok(Some(status)) => {
                if !status.success() {
                    let mut err_text = String::new();
                    if let Some(mut stderr) = child.stderr.take() {
                        let _ = std::io::Read::read_to_string(&mut stderr, &mut err_text);
                    }
                    let _ = fs::remove_file(&part_path);
                    let detail = err_text.lines().last().unwrap_or("download failed").trim();
                    let _ = tx.send(AiWorkerEvent::Failed {
                        message: format!("model download failed: {detail}"),
                    });
                    return;
                }
                break;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(120)),
            Err(error) => {
                let _ = child.kill();
                let _ = fs::remove_file(&part_path);
                let _ = tx.send(AiWorkerEvent::Failed {
                    message: format!("download wait failed: {error}"),
                });
                return;
            }
        }
    }

    if !spec.sha256.is_empty() {
        let _ = tx.send(AiWorkerEvent::Progress {
            percent: 99,
            stage: "Verifying SHA-256…".to_owned(),
        });
        if let Err(error) = verify_sha256(&part_path, &spec.sha256) {
            let _ = fs::remove_file(&part_path);
            let _ = tx.send(AiWorkerEvent::Failed { message: error });
            return;
        }
    }

    if let Err(error) = fs::rename(&part_path, &final_path) {
        let _ = fs::remove_file(&part_path);
        let _ = tx.send(AiWorkerEvent::Failed {
            message: format!("cannot finalize model file: {error}"),
        });
        return;
    }

    let _ = tx.send(AiWorkerEvent::DownloadDone {
        model_id: spec.id.clone(),
        path: final_path,
    });
}

fn verify_sha256(path: &Path, expected_hex: &str) -> Result<(), String> {
    let output = ProcessCommand::new("sha256sum")
        .arg(path)
        .output()
        .map_err(|e| format!("cannot run sha256sum: {e}"))?;
    if !output.status.success() {
        return Err("sha256sum returned non-zero status".to_owned());
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let actual = stdout.split_whitespace().next().unwrap_or("");
    if actual.eq_ignore_ascii_case(expected_hex.trim()) {
        Ok(())
    } else {
        Err(format!(
            "checksum mismatch (expected {}, got {actual})",
            expected_hex.trim()
        ))
    }
}

/// Spawn a `jsonl-stdio` plugin for one inference request, stream progress,
/// honor cancellation, and shut down cleanly so RAM/VRAM is released.
#[allow(clippy::too_many_arguments)]
pub fn run_plugin_inference(
    plugin: &DiscoveredPlugin,
    action: &str,
    model_id: &str,
    model_path: &Path,
    device: AiDevice,
    input_path: &Path,
    output_path: &Path,
    params: Value,
    cancel: Arc<AtomicBool>,
    tx: &Sender<AiWorkerEvent>,
) {
    if !plugin.available || !plugin.executable.is_file() {
        let _ = tx.send(AiWorkerEvent::Failed {
            message: format!(
                "plugin '{}' binary not found at {}",
                plugin.manifest.id,
                plugin.executable.display()
            ),
        });
        return;
    }

    let expanded_args: Vec<String> = plugin
        .manifest
        .entry
        .args
        .iter()
        .map(|arg| arg.replace("${device}", device.as_str()))
        .collect();

    let mut cmd = ProcessCommand::new(&plugin.executable);
    cmd.args(&expanded_args)
        .current_dir(&plugin.root_dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(unix)]
    if let Some(bin_dir) = plugin.executable.parent() {
        let existing = std::env::var("LD_LIBRARY_PATH").unwrap_or_default();
        let combined = if existing.is_empty() {
            bin_dir.display().to_string()
        } else {
            format!("{}:{existing}", bin_dir.display())
        };
        cmd.env("LD_LIBRARY_PATH", combined);
    }
    let mut child = match cmd.spawn() {
        Ok(child) => child,
        Err(error) => {
            let _ = tx.send(AiWorkerEvent::Failed {
                message: format!("failed to launch plugin '{}': {error}", plugin.manifest.id),
            });
            return;
        }
    };

    let Some(mut stdin) = child.stdin.take() else {
        let _ = child.kill();
        let _ = tx.send(AiWorkerEvent::Failed {
            message: "plugin stdin unavailable".to_owned(),
        });
        return;
    };
    let Some(stdout) = child.stdout.take() else {
        let _ = child.kill();
        let _ = tx.send(AiWorkerEvent::Failed {
            message: "plugin stdout unavailable".to_owned(),
        });
        return;
    };

    let req = json!({
        "id": "req-1",
        "op": "run",
        "action": action,
        "modelId": model_id,
        "modelPath": model_path.display().to_string(),
        "device": device.as_str(),
        "input": input_path.display().to_string(),
        "output": output_path.display().to_string(),
        "params": params,
    });
    if let Err(error) = writeln!(stdin, "{req}") {
        let _ = child.kill();
        let _ = tx.send(AiWorkerEvent::Failed {
            message: format!("failed to send request to plugin: {error}"),
        });
        return;
    }
    let _ = stdin.flush();

    // Background watcher kills the child if the user cancels while the plugin
    // is blocked inside inference.
    let child_pid = child.id();
    let cancel_watch = Arc::clone(&cancel);
    let done_flag = Arc::new(AtomicBool::new(false));
    let done_watch = Arc::clone(&done_flag);
    std::thread::spawn(move || {
        while !done_watch.load(Ordering::SeqCst) {
            if cancel_watch.load(Ordering::SeqCst) {
                #[cfg(unix)]
                {
                    let _ = ProcessCommand::new("kill")
                        .arg("-TERM")
                        .arg(child_pid.to_string())
                        .status();
                }
                break;
            }
            std::thread::sleep(Duration::from_millis(80));
        }
    });

    let started = Instant::now();
    let reader = BufReader::new(stdout);
    let mut completed = false;
    let mut failed_msg: Option<String> = None;
    let mut device_used = device.as_str().to_owned();
    let mut clipboard_text: Option<String> = None;
    let mut translation: Option<TranslationResult> = None;

    for line in reader.lines() {
        if cancel.load(Ordering::SeqCst) {
            break;
        }
        let Ok(line) = line else {
            break;
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(msg) = serde_json::from_str::<Value>(trimmed) else {
            continue;
        };
        match msg.get("event").and_then(Value::as_str).unwrap_or("") {
            "progress" => {
                let percent = msg.get("percent").and_then(Value::as_u64).unwrap_or(0) as u8;
                let stage = msg
                    .get("stage")
                    .and_then(Value::as_str)
                    .unwrap_or("Processing…")
                    .to_owned();
                let _ = tx.send(AiWorkerEvent::Progress {
                    percent: percent.min(99),
                    stage,
                });
            }
            "done" => {
                if let Some(meta) = msg.get("meta") {
                    if let Some(dev) = meta.get("device").and_then(Value::as_str) {
                        device_used = dev.to_owned();
                    }
                    if let Some(text) = meta.get("clipboardText").and_then(Value::as_str) {
                        clipboard_text = Some(text.to_owned());
                    }
                    if let Some(tr_val) = meta.get("translation") {
                        if let Ok(parsed) =
                            serde_json::from_value::<TranslationResult>(tr_val.clone())
                        {
                            translation = Some(parsed);
                        }
                    }
                }
                completed = true;
                break;
            }
            "error" => {
                let message = msg
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("plugin reported an error")
                    .to_owned();
                failed_msg = Some(message);
                break;
            }
            _ => {}
        }
    }

    // Politely shut down worker so RAM/VRAM is released immediately.
    let _ = writeln!(stdin, "{{\"op\":\"shutdown\"}}");
    drop(stdin);
    done_flag.store(true, Ordering::SeqCst);

    if cancel.load(Ordering::SeqCst) {
        let _ = child.kill();
        let _ = child.wait();
        let _ = tx.send(AiWorkerEvent::Cancelled);
        return;
    }

    let _ = child.wait();

    if let Some(message) = failed_msg {
        let _ = tx.send(AiWorkerEvent::Failed { message });
    } else if completed
        && (output_path.is_file() || clipboard_text.is_some() || translation.is_some())
    {
        tracing::info!(
            target: "kogaview::plugins",
            plugin = %plugin.manifest.id,
            model = %model_id,
            device = %device_used,
            ms = started.elapsed().as_millis() as u64,
            "AI plugin inference completed"
        );
        let _ = tx.send(AiWorkerEvent::InferenceDone {
            model_id: model_id.to_owned(),
            output_path: output_path.to_path_buf(),
            device_used,
            clipboard_text,
            translation,
        });
    } else {
        let mut stderr_text = String::new();
        if let Some(mut stderr) = child.stderr.take() {
            let _ = std::io::Read::read_to_string(&mut stderr, &mut stderr_text);
        }
        let detail = stderr_text
            .lines()
            .last()
            .unwrap_or("plugin exited without producing an output image")
            .trim()
            .to_owned();
        let _ = tx.send(AiWorkerEvent::Failed { message: detail });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "kogaview-plugin-test-{name}-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn discovers_valid_manifest_and_resolves_custom_model_path() {
        let root = temp_dir("discover");
        let plugins_dir = root.join("plugins");
        let models_dir = root.join("models");
        let p_dir = plugins_dir.join("mock-plugin");
        fs::create_dir_all(&p_dir).unwrap();
        fs::create_dir_all(&models_dir).unwrap();

        let script = p_dir.join("worker.sh");
        fs::write(&script, "#!/bin/sh\nexit 0\n").unwrap();
        fs::write(
            p_dir.join("manifest.json"),
            r#"{
                "apiVersion": 1,
                "id": "test.mock",
                "name": "Mock Plugin",
                "version": "0.1.0",
                "entry": { "command": "worker.sh" },
                "capabilities": [{
                    "action": "editor.remove_background",
                    "workspace": "editor",
                    "label": "Mock",
                    "output": "rgba_image"
                }]
            }"#,
        )
        .unwrap();

        let plugins = discover_plugins(&plugins_dir);
        let mock = plugins
            .iter()
            .find(|p| p.manifest.id == "test.mock")
            .unwrap();
        assert!(mock.available);

        let custom_onnx = root.join("my-custom.onnx");
        fs::write(&custom_onnx, b"fake-onnx").unwrap();
        let mut settings = AiSettings::default();
        settings
            .custom_model_paths
            .insert("rmbg-1.4".to_owned(), custom_onnx.display().to_string());

        let statuses = model_statuses(&models_dir, &settings, &plugins);
        let rmbg = statuses.iter().find(|m| m.id == "rmbg-1.4").unwrap();
        assert!(rmbg.installed);
        assert_eq!(
            rmbg.effective_path.as_deref(),
            Some(custom_onnx.to_str().unwrap())
        );

        let _ = fs::remove_dir_all(&root);
    }

    #[cfg(unix)]
    #[test]
    fn runs_out_of_process_jsonl_plugin_and_streams_progress() {
        use std::os::unix::fs::PermissionsExt;

        let root = temp_dir("run-jsonl");
        let worker = root.join("mock-worker.py");
        fs::write(
            &worker,
            r#"#!/usr/bin/env python3
import json, shutil, sys
for line in sys.stdin:
    req = json.loads(line)
    if req.get("op") == "shutdown":
        break
    if req.get("op") == "run":
        print(json.dumps({"id": req["id"], "event": "progress", "percent": 40, "stage": "Running mock"}), flush=True)
        shutil.copyfile(req["input"], req["output"])
        print(json.dumps({"id": req["id"], "event": "done", "output": req["output"], "meta": {"device": "cpu"}}), flush=True)
"#,
        )
        .unwrap();
        fs::set_permissions(&worker, fs::Permissions::from_mode(0o755)).unwrap();

        let input = root.join("in.png");
        let output = root.join("out.png");
        let model = root.join("model.onnx");
        fs::write(&input, b"png-bytes").unwrap();
        fs::write(&model, b"onnx-bytes").unwrap();

        let plugin = DiscoveredPlugin {
            manifest: PluginManifest {
                api_version: 1,
                id: "test.mock".to_owned(),
                name: "Mock".to_owned(),
                version: "1.0.0".to_owned(),
                entry: PluginEntry {
                    command: worker.display().to_string(),
                    args: vec![],
                    protocol: "jsonl-stdio".to_owned(),
                },
                permissions: PluginPermissions::default(),
                models: vec![],
                capabilities: vec![],
                quick_actions: vec![],
            },
            root_dir: root.clone(),
            executable: worker,
            available: true,
        };

        let (tx, rx) = mpsc::channel();
        run_plugin_inference(
            &plugin,
            REMBG_ACTION,
            "rmbg-1.4",
            &model,
            AiDevice::Cpu,
            &input,
            &output,
            json!({ "feather": 2 }),
            Arc::new(AtomicBool::new(false)),
            &tx,
        );

        let events: Vec<AiWorkerEvent> = rx.try_iter().collect();
        assert!(events
            .iter()
            .any(|e| matches!(e, AiWorkerEvent::Progress { percent: 40, .. })));
        assert!(events
            .iter()
            .any(|e| matches!(e, AiWorkerEvent::InferenceDone { device_used, .. } if device_used == "cpu")));
        assert_eq!(fs::read(&output).unwrap(), b"png-bytes");

        let _ = fs::remove_dir_all(&root);
    }
}
