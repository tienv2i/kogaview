//! Filesystem operations used by Core.
//!
//! Everything here is Qt-independent. Trash uses the freedesktop trash
//! specification through `gio trash` when available.

use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

use crate::state::Entry;

const IMAGE_EXTENSIONS: &[&str] = &[
    "jpg", "jpeg", "png", "webp", "gif", "bmp", "tif", "tiff", "avif", "heic", "heif",
];

pub fn is_image_path(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| IMAGE_EXTENSIONS.contains(&extension.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

pub fn kind_label(path: &Path) -> String {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some(extension) if !extension.is_empty() => format!(".{}", extension.to_ascii_lowercase()),
        _ => "file".to_owned(),
    }
}

/// Read one directory. Hidden entries are skipped to match a normal file
/// manager's default view.
pub fn read_entries(dir: &Path) -> Result<Vec<Entry>, String> {
    let read_dir = std::fs::read_dir(dir)
        .map_err(|error| format!("cannot read directory {}: {error}", dir.display()))?;

    let mut entries = Vec::new();
    for item in read_dir {
        let item = match item {
            Ok(item) => item,
            Err(error) => {
                tracing::warn!(target: "kogaview::scan", %error, "skipping unreadable entry");
                continue;
            }
        };
        let name = item.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        let path = item.path();
        let metadata = item.metadata();
        let (is_dir, size, modified) = match &metadata {
            Ok(metadata) => (
                metadata.is_dir(),
                metadata.len(),
                metadata
                    .modified()
                    .ok()
                    .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
                    .map(|duration| duration.as_secs())
                    .unwrap_or_default(),
            ),
            Err(_) => (path.is_dir(), 0, 0),
        };
        let is_image = !is_dir && is_image_path(&path);
        entries.push(Entry {
            name,
            path: path.to_string_lossy().into_owned(),
            is_dir,
            is_image,
            size,
            modified,
        });
    }

    entries.sort_by(|left, right| {
        right
            .is_dir
            .cmp(&left.is_dir)
            .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
            .then_with(|| left.name.cmp(&right.name))
    });
    Ok(entries)
}

pub fn list_folders(dir: &Path) -> Result<Vec<Entry>, String> {
    let mut entries = read_entries(dir)?
        .into_iter()
        .filter(|entry| entry.is_dir)
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| left.name.to_lowercase().cmp(&right.name.to_lowercase()));
    Ok(entries)
}

pub fn image_dimensions(path: &Path) -> Option<(u32, u32)> {
    image::ImageReader::open(path)
        .ok()?
        .with_guessed_format()
        .ok()?
        .into_dimensions()
        .ok()
}

/// Validate a user-provided folder name.
pub fn valid_folder_name(name: &str) -> bool {
    let name = name.trim();
    !name.is_empty()
        && name != "."
        && name != ".."
        && !name.contains('/')
        && !name.contains('\\')
        && !name.contains('\0')
}

pub fn create_folder(parent: &Path, name: &str) -> Result<PathBuf, String> {
    let name = name.trim();
    if !valid_folder_name(name) {
        return Err("folder name is empty or contains a path separator".to_owned());
    }
    let target = parent.join(name);
    if target.exists() {
        return Err(format!("{} already exists", target.display()));
    }
    std::fs::create_dir(&target)
        .map_err(|error| format!("cannot create {}: {error}", target.display()))?;
    Ok(target)
}

fn unique_target(destination: &Path, name: &std::ffi::OsStr) -> PathBuf {
    let mut target = destination.join(name);
    if !target.exists() {
        return target;
    }
    let stem = Path::new(name)
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| "item".to_owned());
    let extension = Path::new(name)
        .extension()
        .map(|extension| format!(".{}", extension.to_string_lossy()))
        .unwrap_or_default();
    let mut index = 1;
    loop {
        target = destination.join(format!("{stem} ({index}){extension}"));
        if !target.exists() {
            return target;
        }
        index += 1;
    }
}

pub fn copy_path(source: &Path, destination: &Path) -> Result<PathBuf, String> {
    if !destination.is_dir() {
        return Err(format!("{} is not a directory", destination.display()));
    }
    let name = source
        .file_name()
        .ok_or_else(|| format!("{} has no file name", source.display()))?;
    let target = unique_target(destination, name);
    copy_recursive(source, &target)?;
    Ok(target)
}

fn copy_recursive(source: &Path, target: &Path) -> Result<(), String> {
    let metadata = std::fs::symlink_metadata(source)
        .map_err(|error| format!("cannot read {}: {error}", source.display()))?;
    if metadata.is_dir() {
        std::fs::create_dir(target)
            .map_err(|error| format!("cannot create {}: {error}", target.display()))?;
        let read_dir = std::fs::read_dir(source)
            .map_err(|error| format!("cannot read {}: {error}", source.display()))?;
        for item in read_dir {
            let item = item.map_err(|error| format!("cannot read entry: {error}"))?;
            copy_recursive(&item.path(), &target.join(item.file_name()))?;
        }
        Ok(())
    } else {
        std::fs::copy(source, target)
            .map(|_| ())
            .map_err(|error| format!("cannot copy {}: {error}", source.display()))
    }
}

pub fn move_path(source: &Path, destination: &Path) -> Result<PathBuf, String> {
    if !destination.is_dir() {
        return Err(format!("{} is not a directory", destination.display()));
    }
    let name = source
        .file_name()
        .ok_or_else(|| format!("{} has no file name", source.display()))?;
    let target = unique_target(destination, name);
    match std::fs::rename(source, &target) {
        Ok(()) => Ok(target),
        Err(_) => {
            copy_recursive(source, &target)?;
            remove_path(source)?;
            Ok(target)
        }
    }
}

pub fn remove_path(path: &Path) -> Result<(), String> {
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
    if metadata.is_dir() {
        std::fs::remove_dir_all(path)
            .map_err(|error| format!("cannot delete {}: {error}", path.display()))
    } else {
        std::fs::remove_file(path)
            .map_err(|error| format!("cannot delete {}: {error}", path.display()))
    }
}

/// Move paths to the desktop trash. Returns an error if the trash helper is
/// unavailable; callers must not fall back to permanent deletion silently.
pub fn trash_paths(paths: &[PathBuf]) -> Result<(), String> {
    if paths.is_empty() {
        return Ok(());
    }

    #[cfg(target_os = "linux")]
    {
        let mut command = std::process::Command::new("gio");
        command.arg("trash").arg("--");
        for path in paths {
            command.arg(path);
        }
        match command.output() {
            Ok(output) if output.status.success() => return Ok(()),
            Ok(output) => {
                let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
                return Err(if stderr.is_empty() {
                    "gio trash failed".to_owned()
                } else {
                    format!("gio trash failed: {stderr}")
                });
            }
            Err(error) => {
                return Err(format!(
                    "cannot run gio trash ({error}); install glib2 or use permanent delete"
                ));
            }
        }
    }

    #[cfg(not(target_os = "linux"))]
    {
        let _ = paths;
        Err("move to trash is not implemented on this platform yet".to_owned())
    }
}

/// Refuse paths that must never be deleted through the UI.
pub fn safe_for_deletion(path: &Path) -> Result<(), String> {
    if !path.is_absolute() {
        return Err("refusing to delete a relative path".to_owned());
    }
    let mut components = path.components();
    if components.next().is_none() || components.next().is_none() {
        return Err("refusing to delete a filesystem root".to_owned());
    }
    if path == crate::paths::home_dir() {
        return Err("refusing to delete the home directory".to_owned());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "kogaview-ops-test-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn image_extensions_are_case_insensitive() {
        assert!(is_image_path(Path::new("/tmp/a.JPG")));
        assert!(is_image_path(Path::new("/tmp/a.png")));
        assert!(!is_image_path(Path::new("/tmp/a.txt")));
        assert!(!is_image_path(Path::new("/tmp/folder")));
    }

    #[test]
    fn folder_names_reject_separators_and_empty_values() {
        assert!(valid_folder_name("Holiday 2026"));
        assert!(!valid_folder_name(""));
        assert!(!valid_folder_name("   "));
        assert!(!valid_folder_name("a/b"));
        assert!(!valid_folder_name(".."));
    }

    #[test]
    fn copy_avoids_overwriting_and_preserves_contents() {
        let dir = temp_dir();
        let source_dir = dir.join("source");
        let destination = dir.join("destination");
        std::fs::create_dir_all(&source_dir).unwrap();
        std::fs::create_dir_all(&destination).unwrap();
        std::fs::write(source_dir.join("a.txt"), "one").unwrap();
        std::fs::write(destination.join("a.txt"), "existing").unwrap();

        let target = copy_path(&source_dir.join("a.txt"), &destination).unwrap();
        assert_eq!(target.file_name().unwrap(), "a (1).txt");
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "one");
        assert_eq!(
            std::fs::read_to_string(destination.join("a.txt")).unwrap(),
            "existing"
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn folders_are_copied_recursively() {
        let dir = temp_dir();
        let source = dir.join("album");
        std::fs::create_dir_all(source.join("nested")).unwrap();
        std::fs::write(source.join("nested/photo.txt"), "data").unwrap();
        let destination = dir.join("out");
        std::fs::create_dir_all(&destination).unwrap();

        let target = copy_path(&source, &destination).unwrap();
        assert!(target.join("nested/photo.txt").is_file());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn roots_and_home_cannot_be_deleted() {
        assert!(safe_for_deletion(Path::new("/")).is_err());
        assert!(safe_for_deletion(Path::new("/tmp")).is_ok());
        assert!(safe_for_deletion(&crate::paths::home_dir()).is_err());
    }
}
