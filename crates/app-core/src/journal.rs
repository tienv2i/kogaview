//! Sequential command journal.
//!
//! This is intentionally smaller than the future IPC-backed journal: every
//! submitted command is appended as one JSON line with its outcome, revision
//! and sanitized paths. The full replayable journal lands with M5.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};

use kogaview_protocol::{Command, ProtocolError};

use crate::paths;
use crate::state::UiText;

/// Record of one command execution.
pub struct JournalEntry<'a> {
    pub command_id: &'a str,
    pub command: &'a Command,
    pub revision: u64,
    pub result: &'a Result<Option<UiText>, ProtocolError>,
}

pub struct Journal {
    path: Option<PathBuf>,
}

impl Journal {
    pub fn new(dir: &Path) -> Self {
        let path = dir.join("commands.jsonl");
        Self {
            path: if dir.is_dir() || std::fs::create_dir_all(dir).is_ok() {
                Some(path)
            } else {
                None
            },
        }
    }

    pub fn disabled() -> Self {
        Self { path: None }
    }

    pub fn record(&self, entry: JournalEntry<'_>) {
        let Some(path) = &self.path else {
            return;
        };

        // The journal is diagnostics: each line keeps the English rendering of
        // the code Core published, never the translated sentence, so one file
        // reads the same whatever language the interface was in.
        let (ok, message, error) = match entry.result {
            Ok(line) => (true, line.as_ref().map(UiText::english), None),
            Err(error) => (false, None, Some(error)),
        };

        let record = serde_json::json!({
            "timestamp": now_rfc3339(),
            "id": entry.command_id,
            "command": entry.command.name(),
            "revision": entry.revision,
            "ok": ok,
            "message": message,
            "error": error,
            "paths": sanitized_paths(entry.command),
        });

        let Ok(line) = serde_json::to_string(&record) else {
            return;
        };

        if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "{line}");
        }
    }
}

fn now_rfc3339() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    // Seconds precision is enough for an append-only command log.
    format!("{}.{:03}Z", duration.as_secs(), duration.subsec_millis())
}

fn sanitized_paths(command: &Command) -> Vec<String> {
    let home = paths::home_dir();
    let home = home.to_string_lossy();
    let sanitize = |path: &str| {
        if !home.is_empty() && path.starts_with(home.as_ref()) {
            format!("~{}", &path[home.len()..])
        } else {
            path.to_owned()
        }
    };

    match command {
        Command::OpenFile { paths }
        | Command::Select { paths }
        | Command::Trash { paths }
        | Command::DeletePermanently { paths } => paths.iter().map(|p| sanitize(p)).collect(),
        Command::OpenFolder { path }
        | Command::Navigate { path }
        | Command::AddFavorite { path }
        | Command::RemoveFavorite { path }
        | Command::MoveFavorite { path, .. } => vec![sanitize(path)],
        Command::NewFolder { parent, .. } => vec![sanitize(parent)],
        Command::EditorOpen { path } => vec![sanitize(path)],
        Command::CopyTo { paths, destination } | Command::MoveTo { paths, destination } => {
            let mut all: Vec<String> = paths.iter().map(|p| sanitize(p)).collect();
            all.push(sanitize(destination));
            all
        }
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use kogaview_protocol::Command;

    #[test]
    fn journal_appends_sanitized_records() {
        let dir = std::env::temp_dir().join(format!(
            "kogaview-journal-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let journal = Journal::new(&dir);
        let command = Command::Select {
            paths: vec!["/tmp/a.jpg".into()],
        };
        let result: Result<Option<UiText>, ProtocolError> = Ok(Some(UiText::new("selected")));
        journal.record(JournalEntry {
            command_id: "test-1",
            command: &command,
            revision: 3,
            result: &result,
        });

        let text = std::fs::read_to_string(dir.join("commands.jsonl")).unwrap();
        let value: serde_json::Value = serde_json::from_str(text.lines().next().unwrap()).unwrap();
        assert_eq!(value["id"], "test-1");
        assert_eq!(value["command"], "select");
        assert_eq!(value["revision"], 3);
        assert_eq!(value["ok"], true);
        // The journal keeps the English rendering of the code, not a translated
        // sentence: the same file must read the same in every language.
        assert_eq!(value["message"], "selected");

        std::fs::remove_dir_all(dir).unwrap();
    }
}
