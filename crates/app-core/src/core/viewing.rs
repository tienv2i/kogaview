//! The Viewer's commands: which picture is shown, and what the Info page says
//! about it.
//!
//! The Viewer owns no pixels here; it owns a path, a selection and a step, and
//! the shell draws them.
use super::*;

impl Core {
    pub(super) fn sync_viewer(&mut self) {
        let images = self
            .state
            .entries
            .iter()
            .filter(|entry| entry.is_image)
            .map(|entry| entry.path.clone())
            .collect::<Vec<_>>();
        self.state.viewer_images = images.clone();

        let candidate = self
            .pending_viewer
            .take()
            .or_else(|| self.state.viewer_path.clone())
            .filter(|path| images.contains(path));

        if let Some(path) = candidate {
            let index = images.iter().position(|image| image == &path);
            self.state.viewer_index = index;
            let resolved = index.map(|index| images[index].clone());
            self.set_viewer_path(resolved);
        } else if self.state.workspace == Workspace::Viewer && !images.is_empty() {
            self.state.viewer_index = Some(0);
            self.set_viewer_path(Some(images[0].clone()));
        } else {
            self.state.viewer_index = None;
            self.set_viewer_path(None);
        }
    }

    /// Point the Viewer at `path` and remember which bytes it will read.
    ///
    /// The stamp is the point: `viewer_path` alone is the same string when a
    /// file is reopened or rewritten underneath the window, and a QML `Image`
    /// whose `source` did not change never re-reads the file. Publishing the
    /// mtime and size lets the window key its `source` on them, so "open the
    /// same picture again" reloads exactly when the bytes are different.
    pub(super) fn set_viewer_path(&mut self, path: Option<String>) {
        let identity = path
            .as_deref()
            .map(|path| file_identity(Path::new(path)))
            .unwrap_or((0, 0));
        self.state.viewer_path = path;
        self.state.viewer_modified = identity.0;
        self.state.viewer_size = identity.1;
    }

    pub(super) fn ensure_viewer_selection(&mut self) {
        if self.state.viewer_images.is_empty() {
            return;
        }
        let selected = self
            .state
            .selection
            .iter()
            .find(|path| self.state.viewer_images.contains(path))
            .cloned();
        if let Some(path) = selected {
            if let Some(index) = self
                .state
                .viewer_images
                .iter()
                .position(|image| image == &path)
            {
                self.state.viewer_index = Some(index);
                self.set_viewer_path(Some(path));
            }
        } else if self.state.viewer_path.is_none() {
            self.state.viewer_index = Some(0);
            self.set_viewer_path(Some(self.state.viewer_images[0].clone()));
        }
    }

    pub(super) fn open_viewer_image(
        &mut self,
        path: &str,
    ) -> Result<Option<UiText>, ProtocolError> {
        let index = self
            .state
            .viewer_images
            .iter()
            .position(|image| image == path)
            .ok_or_else(|| ProtocolError::line("not_found", UiText::new("not_in_this_folder")))?;
        self.state.viewer_index = Some(index);
        self.set_viewer_path(Some(path.to_owned()));
        self.state.workspace = Workspace::Viewer;
        self.set_selection(vec![path.to_owned()]);
        Ok(None)
    }

    pub(super) fn step_viewer(&mut self, delta: isize) -> Result<Option<UiText>, ProtocolError> {
        if self.state.viewer_images.is_empty() {
            return Err(ProtocolError::line(
                "no_images",
                UiText::new("no_images_here"),
            ));
        }
        let length = self.state.viewer_images.len() as isize;
        let current = self.state.viewer_index.unwrap_or(0) as isize;
        let next = (current + delta).rem_euclid(length) as usize;
        let path = self.state.viewer_images[next].clone();
        self.state.viewer_index = Some(next);
        self.set_viewer_path(Some(path.clone()));
        self.state.workspace = Workspace::Viewer;
        self.set_selection(vec![path]);
        Ok(None)
    }
}
