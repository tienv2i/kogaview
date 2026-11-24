//! KogaView OCR Plugin (`jsonl-stdio`, ADR 0024).
//!
//! Extracts text from an image using system `tesseract` + optional on-demand
//! `.traineddata` packs downloaded into `$XDG_DATA_HOME/kogaview[-dev]/models/`,
//! returning `meta.clipboardText` so KogaView copies the text directly to the
//! desktop clipboard without modifying the image file.

use std::io::{self, BufRead, Write};
use std::path::Path;
use std::process::Command;

use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    #[serde(default)]
    id: String,
    op: String,
    #[serde(default)]
    action: String,
    #[serde(default)]
    model_path: String,
    #[serde(default)]
    input: String,
    #[serde(default)]
    params: Value,
}

fn emit(value: Value) {
    let mut out = io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn emit_progress(id: &str, percent: u8, stage: &str) {
    emit(json!({
        "id": id,
        "event": "progress",
        "percent": percent,
        "stage": stage,
    }));
}

fn emit_error(id: &str, code: &str, message: &str) {
    emit(json!({
        "id": id,
        "event": "error",
        "code": code,
        "message": message,
    }));
}

fn run_ocr(req: &Request) -> Result<Value, (String, String)> {
    let lang = req
        .params
        .get("lang")
        .and_then(Value::as_str)
        .unwrap_or("eng");

    emit_progress(&req.id, 30, &format!("Running OCR ({lang})…"));

    let mut cmd = Command::new("tesseract");
    cmd.arg(&req.input).arg("stdout").arg("-l").arg(lang);

    // If an on-demand `.traineddata` pack was downloaded into `modelsDir`, point
    // tesseract at that directory so non-system languages (`vie`, `jpn`, `chi_sim`)
    // work without requiring root package installs.
    if !req.model_path.is_empty() {
        let model_file = Path::new(&req.model_path);
        if let Some(dir) = model_file.parent() {
            cmd.arg("--tessdata-dir").arg(dir);
        }
    }

    let output = cmd.output().map_err(|e| {
        (
            "tesseract_missing".to_owned(),
            format!("cannot run tesseract (install tesseract package): {e}"),
        )
    })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let detail = stderr.lines().last().unwrap_or("tesseract OCR failed").trim();
        return Err(("ocr_failed".to_owned(), detail.to_owned()));
    }

    let text = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if text.is_empty() {
        return Err((
            "ocr_empty".to_owned(),
            "no text detected in image".to_owned(),
        ));
    }

    Ok(json!({
        "device": "cpu",
        "lang": lang,
        "clipboardText": text,
    }))
}

fn main() {
    let stdin = io::stdin();
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let req: Request = match serde_json::from_str(trimmed) {
            Ok(req) => req,
            Err(err) => {
                emit_error("", "invalid_request", &format!("invalid JSON request: {err}"));
                continue;
            }
        };
        match req.op.as_str() {
            "shutdown" => break,
            "cancel" => {}
            "run" => {
                if req.action != "viewer.ocr_copy" {
                    emit_error(
                        &req.id,
                        "unsupported_action",
                        &format!("unsupported action '{}'", req.action),
                    );
                    continue;
                }
                match run_ocr(&req) {
                    Ok(meta) => emit(json!({
                        "id": req.id,
                        "event": "done",
                        "meta": meta,
                    })),
                    Err((code, msg)) => emit_error(&req.id, &code, &msg),
                }
            }
            other => emit_error(
                &req.id,
                "unsupported_op",
                &format!("unsupported op '{other}'"),
            ),
        }
    }
}
