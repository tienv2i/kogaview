#[cfg(test)]
mod tests {
    use crate::*;

    #[test]
    fn workspace_names_are_stable() {
        assert_eq!(Workspace::default(), Workspace::Browser);
        assert_eq!(Workspace::Browser.as_str(), "browser");
        assert_eq!(Workspace::Viewer.as_str(), "viewer");
        assert_eq!(Workspace::Editor.as_str(), "editor");
    }

    #[test]
    fn command_wire_names_are_stable() {
        let env: Envelope =
            serde_json::from_str(r#"{"id":"a","command":{"type":"toggle_theme"}}"#).unwrap();
        assert_eq!(env.protocol, PROTOCOL_VERSION);
        assert_eq!(env.command.name(), "toggle_theme");

        let command = Command::CopyTo {
            paths: vec!["/a.jpg".into()],
            destination: "/tmp".into(),
        };
        let json = serde_json::to_string(&command).unwrap();
        assert!(json.contains("\"copy_to\""));
        assert!(json.contains("\"destination\""));
    }

    #[test]
    fn a_batch_job_round_trips_with_its_operation_and_policy() {
        // The shape the QML sends: one command, one operation, one policy.
        let env: Envelope = serde_json::from_str(
            r#"{"id":"b","command":{"type":"batch_run",
                "operation":{"operation":"crop","x":10,"y":10,"width":80,"height":80},
                "source":{"source":"selection","paths":["/pics/a.png"]},
                "output":{"suffix":"_cropped"}}}"#,
        )
        .unwrap();
        assert_eq!(env.command.name(), "batch_run");
        match env.command {
            Command::BatchRun {
                operation,
                source,
                output,
            } => {
                assert_eq!(
                    operation,
                    BatchOperation::Crop {
                        x: 10.0,
                        y: 10.0,
                        width: 80.0,
                        height: 80.0,
                        unit: "percent".to_owned(),
                        anchor: None,
                        ratio: None,
                    }
                );
                assert_eq!(
                    source,
                    BatchSource::Selection {
                        paths: vec!["/pics/a.png".into()]
                    }
                );
                // An older payload carries no folder or overwrite: the safe
                // default is a suffixed copy beside the source.
                assert_eq!(output.folder, None);
                assert_eq!(output.suffix, "_cropped");
                assert!(!output.overwrite);
            }
            other => panic!("parsed as {}", other.name()),
        }

        let command = Command::BatchRun {
            operation: BatchOperation::Resize {
                width: 800,
                height: 600,
                mode: ResizeMode::Cover,
                filter: ResizeFilter::Lanczos3,
                fill: None,
                fill_alpha: 255,
            },
            source: BatchSource::Folder {
                path: "/pics".into(),
            },
            output: BatchOutput {
                folder: Some("/out".into()),
                suffix: "_small".into(),
                overwrite: false,
            },
        };
        let json = serde_json::to_string(&command).unwrap();
        assert!(json.contains("\"operation\":\"resize\""), "{json}");
        assert!(json.contains("\"mode\":\"cover\""), "{json}");
        let round: Command = serde_json::from_str(&json).unwrap();
        assert_eq!(round.name(), "batch_run");
        match round {
            Command::BatchRun { operation, .. } => {
                assert_eq!(operation.name(), "resize");
                assert!(matches!(operation, BatchOperation::Resize { .. }));
            }
            other => panic!("round trip changed the command to {}", other.name()),
        }
    }

    #[test]
    fn theme_toggles_both_ways() {
        assert_eq!(Theme::Dark.toggled(), Theme::Light);
        assert_eq!(Theme::Light.toggled(), Theme::Dark);
    }

    #[test]
    fn a_right_panel_toggle_names_its_workspace_or_means_the_open_one() {
        // The toolbar button sends no workspace: whatever is on screen is what
        // the user is looking at.
        let env: Envelope =
            serde_json::from_str(r#"{"id":"p","command":{"type":"toggle_right_panel"}}"#).unwrap();
        match env.command {
            Command::ToggleRightPanel { workspace } => assert_eq!(workspace, None),
            other => panic!("parsed as {}", other.name()),
        }

        // A replay or a CLI can name the workspace it means.
        let command = Command::ToggleRightPanel {
            workspace: Some(Workspace::Viewer),
        };
        let json = serde_json::to_string(&command).unwrap();
        assert!(json.contains("\"workspace\":\"viewer\""), "{json}");
        let round: Command = serde_json::from_str(&json).unwrap();
        match round {
            Command::ToggleRightPanel { workspace } => {
                assert_eq!(workspace, Some(Workspace::Viewer))
            }
            other => panic!("round trip changed the command to {}", other.name()),
        }
        assert_eq!(round.name(), "toggle_right_panel");
    }

    #[test]
    fn a_layout_round_trips_and_sanitizes() {
        let command = Command::SetLayout {
            layout: LayoutState::default()
                .with_panel("editor.history", false)
                .with_panel("made.up", false),
        };
        let json = serde_json::to_string(&command).unwrap();
        assert!(json.contains("\"set_layout\""), "{json}");
        let round: Command = serde_json::from_str(&json).unwrap();
        assert_eq!(round.name(), "set_layout");
        match round {
            Command::SetLayout { layout } => {
                assert!(!layout.panel("editor.history"));
                // The payload carries what the view sent; Core drops a key it
                // does not know when it sanitizes the layout.
                assert!(!layout.panel("made.up"));
            }
            other => panic!("round trip changed the command to {}", other.name()),
        }

        // Out-of-range numbers are clamped instead of trusted, and a tab that
        // is not a reference tab reads as `info`.
        let wild = LayoutState {
            left_width: 5,
            right_width: 9999,
            editor_tool_columns: 7,
            editor_reference_height: 9999,
            editor_reference_tab: "elsewhere".into(),
            browser_view: "gallery".into(),
            viewer_ui_mode: "zen".into(),
            viewer_display_mode: "carousel".into(),
            manga_page_gap: 999,
            ..LayoutState::default()
        }
        .sanitized();
        assert_eq!(wild.left_width, 180);
        assert_eq!(wild.right_width, 640);
        assert_eq!(wild.editor_tool_columns, 2);
        assert_eq!(wild.editor_reference_height, 900);
        assert_eq!(wild.editor_reference_tab, "info");
        // The Browser's view mode is one of the three the window draws; a value
        // from a newer build reads as the default rather than as a blank grid.
        assert_eq!(wild.browser_view, "thumbnails");
        assert_eq!(wild.viewer_ui_mode, "simple");
        assert_eq!(wild.viewer_display_mode, "single");
        assert_eq!(wild.manga_page_gap, 64);
        // It travels in camelCase like every other layout field, so the window
        // and the CLI name the same thing.
        let json = serde_json::to_string(&Command::SetLayout {
            layout: LayoutState {
                browser_view: "details".into(),
                viewer_ui_mode: "compact".into(),
                viewer_display_mode: "dual".into(),
                manga_rtl: true,
                ..LayoutState::default()
            },
        })
        .unwrap();
        assert!(json.contains("\"browserView\":\"details\""), "{json}");
        assert!(json.contains("\"viewerUiMode\":\"compact\""), "{json}");
        assert!(json.contains("\"viewerDisplayMode\":\"dual\""), "{json}");
        assert!(json.contains("\"mangaRtl\":true"), "{json}");

        // An older config's booleans hide the dock they described.
        let legacy = LayoutState::from_legacy(Some(false), Some(true), Some(false), Some(false));
        assert!(!legacy.panel("browser.quickAccess"));
        assert!(!legacy.panel("editor.explorer"));
        assert!(legacy.panel("browser.preview"));
        assert!(!legacy.panel("viewer.info"));
        assert!(!legacy.panel("editor.history"));
        assert!(
            legacy.panel("editor.tools"),
            "the rail was never a config flag"
        );
    }

    #[test]
    fn editor_commands_round_trip_and_name() {
        let commands = vec![
            (
                Command::EditorOpen {
                    path: "/a.jpg".into(),
                },
                "editor_open",
            ),
            (
                Command::EditorResize {
                    width: 800,
                    height: 600,
                    fill: None,
                    fill_alpha: 255,
                    mode: Some(ResizeMode::Stretch),
                    filter: ResizeFilter::Auto,
                },
                "editor_resize",
            ),
            (
                Command::EditorResizePreview {
                    width: 800,
                    height: 600,
                    fill: Some([1, 2, 3]),
                    fill_alpha: 0,
                    mode: Some(ResizeMode::Pad),
                    filter: ResizeFilter::Bicubic,
                },
                "editor_resize_preview",
            ),
            (
                Command::EditorCrop {
                    x: 10,
                    y: 20,
                    width: 300,
                    height: 400,
                    fill: None,
                    fill_alpha: 255,
                },
                "editor_crop",
            ),
            (
                Command::EditorCropPreview {
                    x: -10,
                    y: -20,
                    width: 300,
                    height: 400,
                    fill: Some([9, 8, 7]),
                    fill_alpha: 0,
                },
                "editor_crop_preview",
            ),
            (
                Command::EditorTransform {
                    corners: [[4.0, 2.0], [40.0, 0.0], [40.0, 20.0], [0.0, 20.0]],
                },
                "editor_transform",
            ),
            (
                Command::EditorFreeTransform {
                    x: 10,
                    y: 20,
                    width: 200,
                    height: 150,
                    rotation: 0.0,
                    fill: Some([12, 34, 56]),
                    fill_alpha: 255,
                    target: ApplyTarget::ActiveLayer,
                },
                "editor_free_transform",
            ),
            (
                Command::EditorTransformPreview {
                    corners: [[4.0, 2.0], [40.0, 0.0], [40.0, 20.0], [0.0, 20.0]],
                },
                "editor_transform_preview",
            ),
            (
                Command::EditorRotate {
                    degrees: 90,
                    target: ApplyTarget::WholeImage,
                },
                "editor_rotate",
            ),
            (
                Command::EditorFlip {
                    axis: FlipAxis::Vertical,
                    target: ApplyTarget::ActiveLayer,
                },
                "editor_flip",
            ),
            (
                Command::EditorPaintStroke {
                    points: vec![[10.0, 12.0], [40.0, 18.0]],
                    color: [255, 0, 0],
                    radius: 8.0,
                    opacity: 0.75,
                    erase: false,
                brush: Default::default(),
                },
                "editor_paint_stroke",
            ),
            (Command::EditorUndo, "editor_undo"),
            (Command::EditorRedo, "editor_redo"),
            (Command::EditorReset, "editor_reset"),
            (
                Command::EditorExport {
                    path: "/a.jpg".into(),
                    quality: Some(80),
                    metadata: true,
                    max_edge: Some(1920),
                },
                "editor_export",
            ),
            (Command::EditorClose, "editor_close"),
        ];
        for (command, expected_name) in commands {
            let json = serde_json::to_string(&command).unwrap();
            assert!(json.contains(&format!("\"{expected_name}\"")), "{json}");
            let round: Command = serde_json::from_str(&json).unwrap();
            assert_eq!(serde_json::to_string(&round).unwrap(), json);
            assert_eq!(round.name(), expected_name);
        }
        // FlipAxis & ApplyTarget wire values are snake_case and stable.
        let json = serde_json::to_string(&Command::EditorFlip {
            axis: FlipAxis::Horizontal,
            target: ApplyTarget::ActiveLayer,
        })
        .unwrap();
        assert!(json.contains("\"horizontal\""));
        assert!(json.contains("\"active_layer\""));
        let env: Envelope =
            serde_json::from_str(r#"{"id":"e","command":{"type":"editor_rotate","degrees":-90}}"#)
                .unwrap();
        assert_eq!(env.command.name(), "editor_rotate");
        assert!(matches!(
            env.command,
            Command::EditorRotate {
                degrees: -90,
                target: ApplyTarget::WholeImage
            }
        ));

        // An older client that knows only the path still exports: quality
        // falls back to the encoder's default, metadata is off and the copy
        // keeps its own size, which is the safe answer (nothing is copied or
        // shrunk that the caller did not ask for).
        let env: Envelope = serde_json::from_str(
            r#"{"id":"x","command":{"type":"editor_export","path":"/a.jpg"}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorExport {
                path,
                quality,
                metadata,
                max_edge,
            } => {
                assert_eq!(path, "/a.jpg");
                assert_eq!(quality, None);
                assert!(!metadata);
                assert_eq!(max_edge, None);
            }
            other => panic!("unexpected command {other:?}"),
        }

        // Older resize commands carry no fill; the field defaults to no
        // padding. An `anchor` from the short-lived anchored design is simply
        // ignored, because Resize no longer has one.
        let env: Envelope = serde_json::from_str(
            r#"{"id":"r","command":{"type":"editor_resize","width":64,"height":32}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorResize {
                fill,
                fill_alpha,
                mode,
                filter,
                width,
                height,
            } => {
                assert_eq!((width, height), (64, 32));
                assert_eq!(fill, None);
                assert_eq!(fill_alpha, 255, "an old payload pads opaquely");
                // No mode and no fill is the old `cover` payload. The protocol
                // keeps the field absent and lets Core read it, so a client
                // that knows only the old shape is still understood.
                assert_eq!(mode, None);
                assert_eq!(
                    ResizeMode::for_payload(mode, fill),
                    ResizeMode::Stretch,
                    "a payload with no mode and no fill now stretches"
                );
                assert_eq!(filter, ResizeFilter::Auto);
            }
            other => panic!("unexpected command {other:?}"),
        }
        let env: Envelope = serde_json::from_str(
            r#"{"id":"r","command":{"type":"editor_resize","width":64,"height":32,"anchor":"bottom_right","fill":[1,2,3],"fill_alpha":0,"filter":"bspline"}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorResize {
                fill,
                fill_alpha,
                mode,
                filter,
                ..
            } => {
                assert_eq!(fill, Some([1, 2, 3]));
                assert_eq!(fill_alpha, 0);
                assert_eq!(mode, None);
                assert_eq!(
                    ResizeMode::for_payload(mode, fill),
                    ResizeMode::Pad,
                    "an old payload that carries a fill keeps its pad"
                );
                assert_eq!(filter, ResizeFilter::Bspline);
            }
            other => panic!("unexpected command {other:?}"),
        }
        // A payload that names its mode keeps it, including `cover` with no
        // fill: the explicit answer is what the form sends.
        let env: Envelope = serde_json::from_str(
            r#"{"id":"r","command":{"type":"editor_resize","width":64,"height":32,"mode":"cover"}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorResize { mode, fill, .. } => {
                assert_eq!(mode, Some(ResizeMode::Cover));
                assert_eq!(ResizeMode::for_payload(mode, fill), ResizeMode::Cover);
            }
            other => panic!("unexpected command {other:?}"),
        }
        // The draft preview is the same shape and is journalled under its own
        // name, so a preview never looks like an applied resize.
        let env: Envelope = serde_json::from_str(
            r#"{"id":"r","command":{"type":"editor_resize_preview","width":1024,"height":1024}}"#,
        )
        .unwrap();
        assert_eq!(env.command.name(), "editor_resize_preview");

        // A stroke written by an older client that does not know `erase` is a
        // brush stroke, not an eraser one.
        let env: Envelope = serde_json::from_str(
            r#"{"id":"p","command":{"type":"editor_paint_stroke","points":[[1,2]],"color":[0,0,0],"radius":4,"opacity":1}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorPaintStroke { erase, points, .. } => {
                assert!(!erase);
                assert_eq!(points, vec![[1.0, 2.0]]);
            }
            other => panic!("unexpected command {other:?}"),
        }

        // A crop preview is the same rectangle as the applied crop and has its
        // own name, so a journal line can never read as a cut. A payload from
        // before the grow mode is an inside crop with no fill.
        let env: Envelope = serde_json::from_str(
            r#"{"id":"r","command":{"type":"editor_crop_preview","x":4,"y":2,"width":10,"height":8}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorCropPreview {
                x,
                y,
                width,
                height,
                fill,
                fill_alpha,
            } => {
                assert_eq!((x, y, width, height), (4, 2, 10, 8));
                assert_eq!(fill, None);
                assert_eq!(fill_alpha, 255);
            }
            other => panic!("unexpected command {other:?}"),
        }

        // A grow crop can start outside the picture; the negative origin is
        // part of the typed command, not a view-only number.
        let env: Envelope = serde_json::from_str(
            r#"{"id":"g","command":{"type":"editor_crop","x":-12,"y":-8,"width":120,"height":90,"fill":[255,255,255],"fill_alpha":0}}"#,
        )
        .unwrap();
        match env.command {
            Command::EditorCrop {
                x,
                y,
                fill,
                fill_alpha,
                ..
            } => {
                assert_eq!((x, y), (-12, -8));
                assert_eq!(fill, Some([255, 255, 255]));
                assert_eq!(fill_alpha, 0);
            }
            other => panic!("unexpected command {other:?}"),
        }
    }
}
