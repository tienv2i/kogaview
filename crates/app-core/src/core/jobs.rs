//! Long jobs that are Core's own rather than one document's: the batch worker
//! and the input set it runs over.
//!
//! The job is typed (`BatchRun`) and rendered by the Editor crate's
//! `render_operation`, so a batch result and a single edit cannot disagree.
use super::*;

impl Core {
    /// Start one batch job on a worker.
    ///
    /// The gateway resolves the input list and validates the whole policy
    /// before a thread exists, so a rejected job never publishes a `batch`
    /// slot. The job then owns its own cancel flag; `cancel_operation` sets it
    /// beside any file operation's, and `poll()` publishes progress and the
    /// final line.
    pub(super) fn batch_run(
        &mut self,
        operation: BatchOperation,
        source: BatchSource,
        output: BatchOutput,
    ) -> Result<Option<UiText>, ProtocolError> {
        if self.batch_rx.is_some() {
            return Err(ProtocolError::line(
                "busy",
                UiText::new("batch_already_running"),
            ));
        }
        let inputs = self.batch_inputs(source)?;
        let plan = batch::BatchPlan::build(operation, inputs, output)?;
        let total = plan.total();
        let name = operation.name();

        let (sender, receiver) = mpsc::channel();
        let cancel = Arc::new(AtomicBool::new(false));
        self.batch_cancel = Some(cancel.clone());
        self.batch_rx = Some(receiver);
        self.state.batch = Some(BatchState {
            operation: name.to_owned(),
            total,
            running: true,
            ..BatchState::default()
        });
        self.state.busy = true;
        let line = UiText::with("batch_started", [total.to_string()]);
        self.state.status = line.clone();
        plan.spawn(cancel, sender);
        Ok(Some(line))
    }

    /// Resolve the command's input source to the files this build can decode.
    ///
    /// A folder is read here, not in QML: the listing rule (one folder, images
    /// only, the same `is_image` the grid draws) belongs to Core, and a batch
    /// must touch exactly what the Browser would show.
    pub(super) fn batch_inputs(&self, source: BatchSource) -> Result<Vec<PathBuf>, ProtocolError> {
        let mut paths: Vec<PathBuf> = Vec::new();
        match source {
            BatchSource::Selection { paths: raw } => {
                for raw in raw {
                    let path = ops::normalize_path(&PathBuf::from(raw));
                    if batch::is_batchable(&path) {
                        paths.push(path);
                    }
                }
            }
            BatchSource::Folder { path } => {
                let folder = ops::normalize_path(&PathBuf::from(path));
                if !folder.is_dir() {
                    return Err(ProtocolError::line(
                        "not_a_directory",
                        UiText::with("not_a_folder", [folder.display().to_string()]),
                    ));
                }
                let entries = ops::read_entries(&folder).map_err(|error| {
                    ProtocolError::with_line(
                        "folder_error",
                        error,
                        UiText::with("folder_error", [folder.display().to_string()]),
                    )
                })?;
                for entry in entries {
                    if entry.is_image {
                        let path = PathBuf::from(&entry.path);
                        if batch::is_batchable(&path) {
                            paths.push(path);
                        }
                    }
                }
            }
        }
        // A selection can name the same file twice; the same output would then
        // be written twice. Keep the first occurrence and the order the user
        // selected, so the progress count matches the panel's.
        let mut unique = Vec::with_capacity(paths.len());
        for path in paths {
            if !unique.contains(&path) {
                unique.push(path);
            }
        }
        if unique.is_empty() {
            return Err(ProtocolError::line(
                "no_images",
                UiText::new("batch_no_images"),
            ));
        }
        Ok(unique)
    }
}
