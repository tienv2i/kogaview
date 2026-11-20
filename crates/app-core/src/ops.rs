//! Filesystem operations used by Core.
//!
//! Everything here is Qt-independent. Trash uses the freedesktop trash
//! specification through `gio trash` when available.

use std::path::{Component, Path, PathBuf};
use std::time::UNIX_EPOCH;

use crate::state::{Entry, UiText};

pub fn is_image_path(path: &Path) -> bool {
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| {
            kogaview_protocol::IMAGE_EXTENSIONS.contains(&extension.to_ascii_lowercase().as_str())
        })
        .unwrap_or(false)
}

pub fn kind_label(path: &Path) -> String {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some(extension) if !extension.is_empty() => format!(".{}", extension.to_ascii_lowercase()),
        _ => "file".to_owned(),
    }
}

/// Normalise a user-supplied path without resolving symbolic links.
///
/// `canonicalize` follows links, so a folder reached through a symlink would be
/// reported under its target name — the explorer would then navigate away from
/// the row the user clicked, and a symlinked folder would stop looking like an
/// ordinary folder. This keeps the path the user opened (only `.`, `..` and a
/// missing leading `/` are cleaned up) and leaves link resolution to the kernel.
pub fn normalize_path(path: &Path) -> PathBuf {
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(path))
            .unwrap_or_else(|_| path.to_path_buf())
    };

    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::Prefix(prefix) => normalized.push(prefix.as_os_str()),
            Component::RootDir => normalized.push(Component::RootDir.as_os_str()),
            Component::CurDir => {}
            Component::ParentDir => {
                // Never climb above the root.
                if !normalized.pop() {
                    normalized.push(Component::RootDir.as_os_str());
                }
            }
            Component::Normal(part) => normalized.push(part),
        }
    }
    normalized
}

/// Read one directory. Hidden entries are skipped to match a normal file
/// manager's default view.
///
/// Symbols links are followed for the "is this a folder?" decision, so a link
/// to a folder is listed, sorted, expanded and navigated exactly like a real
/// folder. The entry keeps the link's own path: browsing it stays inside the
/// link instead of jumping to the target.
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
        // `DirEntry::metadata` never follows a link, which made every symlinked
        // folder look like a file. Resolve it, and fall back to the link itself
        // for a broken link so the entry still shows up as a file.
        let (is_dir, size, modified) = match std::fs::metadata(&path) {
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
            Err(_) => (false, 0, 0),
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
    // Copy the link, not what it points at: following it would duplicate the
    // target's contents and silently turn one linked folder into a real one.
    if metadata.file_type().is_symlink() {
        return copy_symlink(source, target);
    }
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

#[cfg(unix)]
fn copy_symlink(source: &Path, target: &Path) -> Result<(), String> {
    let link = std::fs::read_link(source)
        .map_err(|error| format!("cannot read link {}: {error}", source.display()))?;
    std::os::unix::fs::symlink(&link, target).map_err(|error| {
        format!(
            "cannot link {} -> {}: {error}",
            target.display(),
            link.display()
        )
    })
}

#[cfg(not(unix))]
fn copy_symlink(source: &Path, target: &Path) -> Result<(), String> {
    // No portable way to recreate a link; copy what it points at instead.
    std::fs::copy(source, target)
        .map(|_| ())
        .map_err(|error| format!("cannot copy {}: {error}", source.display()))
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
/// Reasons a delete is refused, as interface lines.
///
/// The codes read as sentences once their underscores are opened, which is the
/// fallback `UiText::english()` produces for the journal, so a reader of
/// `journal/commands.jsonl` gets `home_folder_cannot_be_deleted` and the window
/// gets its own translation of the same fact.
pub fn safe_for_deletion(path: &Path) -> Result<(), UiText> {
    if !path.is_absolute() {
        return Err(UiText::new("relative_path_cannot_be_deleted"));
    }
    let mut components = path.components();
    if components.next().is_none() || components.next().is_none() {
        return Err(UiText::new("filesystem_root_cannot_be_deleted"));
    }
    if path == crate::paths::home_dir() {
        return Err(UiText::new("home_folder_cannot_be_deleted"));
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

    /// The list is shared with every front end, so the formats it advertises
    /// are the ones the editor really decodes — checked against the decoder
    /// rather than restated by hand. HEIC/HEIF are the documented exception:
    /// listed so a phone photo is not invisible, and rejected with a message
    /// when opened.
    #[test]
    fn every_advertised_extension_has_a_decoder() {
        for extension in kogaview_protocol::IMAGE_EXTENSIONS {
            if matches!(*extension, "heic" | "heif") {
                continue;
            }
            assert!(
                image::ImageFormat::from_extension(extension).is_some(),
                "the browser lists .{extension} but `image` cannot decode it"
            );
        }
    }

    #[cfg(unix)]
    fn symlink(link: &Path, target: &Path) {
        std::os::unix::fs::symlink(target, link).unwrap();
    }

    /// A link to a folder must be listed, sorted and opened exactly like a real
    /// folder; `DirEntry::metadata` used to report it as a file.
    #[cfg(unix)]
    #[test]
    fn symlinked_folders_are_listed_as_folders() {
        let dir = temp_dir();
        std::fs::create_dir(dir.join("target")).unwrap();
        std::fs::create_dir(dir.join("aaa")).unwrap();
        std::fs::write(dir.join("target/inside.txt"), b"x").unwrap();
        std::fs::write(dir.join("picture.png"), b"x").unwrap();
        symlink(&dir.join("link"), &dir.join("target"));
        symlink(&dir.join("image-link.png"), &dir.join("picture.png"));
        symlink(&dir.join("broken"), &dir.join("nowhere"));

        let folders = list_folders(&dir).unwrap();
        let names = folders
            .iter()
            .map(|entry| entry.name.as_str())
            .collect::<Vec<_>>();
        // Sorted with the real folders, not pushed to the file section.
        assert_eq!(names, vec!["aaa", "link", "target"]);

        let entries = read_entries(&dir).unwrap();
        let link = entries.iter().find(|entry| entry.name == "link").unwrap();
        assert!(link.is_dir, "a symlinked folder is not a folder");
        assert!(!link.is_image);
        assert_eq!(link.path, dir.join("link").to_string_lossy());

        // A link to an image keeps behaving as an image, and a broken link is a
        // plain (unopenable) file rather than a hidden entry.
        let image = entries
            .iter()
            .find(|entry| entry.name == "image-link.png")
            .unwrap();
        assert!(!image.is_dir);
        assert!(image.is_image);
        let broken = entries.iter().find(|entry| entry.name == "broken");
        assert!(
            broken.is_some(),
            "a broken link disappeared from the listing"
        );
        assert!(!broken.unwrap().is_dir);

        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Copying a link copies the link: following it would duplicate the whole
    /// target and turn one linked folder into a real second copy.
    #[cfg(unix)]
    #[test]
    fn copying_a_symlink_copies_the_link_only() {
        let dir = temp_dir();
        let target = dir.join("target");
        std::fs::create_dir(&target).unwrap();
        std::fs::write(target.join("inside.txt"), b"payload").unwrap();
        let link = dir.join("link");
        symlink(&link, &target);
        let destination = dir.join("dest");
        std::fs::create_dir(&destination).unwrap();

        let copy = copy_path(&link, &destination).unwrap();
        assert!(copy.file_name().unwrap() == "link");
        let metadata = std::fs::symlink_metadata(&copy).unwrap();
        assert!(metadata.file_type().is_symlink(), "the copy is not a link");
        assert!(!metadata.is_dir());
        assert_eq!(std::fs::read_link(&copy).unwrap(), target);
        // Nothing was duplicated: the only `inside.txt` is the original one.
        let copies = read_entries(&destination).unwrap();
        assert_eq!(copies.len(), 1);
        assert!(copies[0].name == "link");

        // Moving the link moves the link, and leaves the target alone.
        let moved = move_path(&link, &destination).unwrap();
        assert!(std::fs::symlink_metadata(&moved)
            .unwrap()
            .file_type()
            .is_symlink());
        assert!(!link.exists());
        assert!(target.join("inside.txt").is_file());

        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Deleting a link removes the link, never what it points at.
    #[cfg(unix)]
    #[test]
    fn deleting_a_symlinked_folder_keeps_its_target() {
        let dir = temp_dir();
        let target = dir.join("target");
        std::fs::create_dir(&target).unwrap();
        std::fs::write(target.join("inside.txt"), b"payload").unwrap();
        let link = dir.join("link");
        symlink(&link, &target);

        remove_path(&link).unwrap();
        assert!(!link.exists());
        assert!(target.join("inside.txt").is_file());

        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn normalize_path_cleans_segments_but_keeps_links() {
        assert_eq!(
            normalize_path(Path::new("/a/./b/../c")),
            PathBuf::from("/a/c")
        );
        assert_eq!(normalize_path(Path::new("/../..")), PathBuf::from("/"));
        assert_eq!(
            normalize_path(Path::new("/a//b/")).to_string_lossy(),
            "/a/b"
        );
    }

    #[cfg(unix)]
    #[test]
    fn normalize_path_does_not_resolve_a_symlink() {
        let dir = temp_dir();
        std::fs::create_dir(dir.join("real")).unwrap();
        let link = dir.join("link");
        symlink(&link, &dir.join("real"));

        // `canonicalize` would answer ".../real"; the explorer keeps the link.
        assert_eq!(normalize_path(&link), link);
        assert_eq!(normalize_path(&link), normalize_path(&link.join(".")));

        std::fs::remove_dir_all(dir).unwrap();
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
