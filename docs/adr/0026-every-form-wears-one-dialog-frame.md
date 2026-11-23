# ADR 0026 — Every form wears one dialog frame

- Status: accepted
- Date: 2026-11-23
- Related: ADR 0012 (sizing is a dialog), ADR 0020 (a content-sized tool zone),
  ADR 0022 (a layout owned by Core), ADR 0025 (one colour pair per Editor)

## Context

The window has six modal forms, written in three sittings: Settings, Resize, the
Editor's Export, the Batch form (with Resize/Crop/Convert pages), the Browser's
New folder, and the two yes/no questions in `Main.qml` (Delete, Unsaved). Each
one was copied from the one before it, and the copies drifted:

1. **The title bar was 52 px in all of them, and nothing else about it matched.**
   The × sat 10 px from the edge in one form and 6 px in another, at two font
   sizes, and each form carried its own `DragHandler` with its own clamp — two
   of them clamped the dialog inside the window, one clamped against a stale
   `parent.height` and could park the form half outside.
2. **Padding was remembered per form.** Two bodies kept 20 px, the batch body
   kept 20 px on three sides and 0 on the top because its first row was a
   section heading, and the Export form had its own mix. The label column was a
   fixed 96 px in some rows and natural width in others, so a form had two left
   edges to read at once, one for each row shape.
3. **The verb row had three shapes.** Settings and Batch drew a 60 px bar of
   `PanelAction`s; the Export form drew a stock `Button` row and `Main.qml` used
   `MessageDialog` with a stock `DialogButtonBox`. Those two drew a near-white
   slab on the dark theme, and their words — `OK`, `Cancel`, `Delete` — came from
   the platform's `qtbase_<locale>.qm`. On a machine without that file a
   Vietnamese window showed an English "Delete" in the middle of a Vietnamese
   sentence.
4. **A tall form ran under its verbs.** Nothing stopped a body from taking the
   height its column asked for, so on a short window the last rows were painted
   underneath the footer, half a row visible at the fold and no scroll bar to
   reach the rest.
5. **Controls inside a `Popup` resolve the platform palette.** A stock
   `CheckBox`/`RadioButton` in the Batch form drew near-black text on the dark
   form (`#26292e` on `#181b21`, measured), and each form had grown its own
   `contentItem` copy to fix it — three copies, and the Export form had not been
   visited yet, so its checkbox had no colour at all.

The owner asked for the dialogs to be brought to one standard: alignment,
padding and margins complete and tidy. Copying is what made them differ, so the
answer is one place for the chrome, not six corrected copies.

## Decision

Four components in `crates/desktop/qml/`, and two leaf controls:

**`DialogFrame.qml` — the chrome.** A `Dialog` with `padding: 0` that owns the
title bar, the body and the verb row, and lets a form supply only its fields:

- a 52 px header (`headerHeight`): the title (17 px bold), a × at 32 × 32, and
  one `DragHandler` whose clamp is written once, so no form can clamp wrongly;
- a body that keeps `bodyPadding` (20 px) on all four sides, scrolls
  (`Flickable` + `ScrollBar.AsNeeded`), and reports the overflow instead of
  clipping it;
- a 60 px footer (`footerHeight`) drawn by `DialogFooter.qml`;
- one centring rule, `centreInParent()`, called from `onAboutToShow` and from
  every size change until the user drags the form (`moved`), never from
  `opened` — centring after the style's enter fade made the form jump.

Height is computed, not guessed: `min(limit, headerHeight + footerHeight +
2 * bodyPadding + stripHeight() + bodyColumn.implicitHeight)` for a form that
fits, `min(limit, preferredHeight)` for a tabbed one, with
`limit = max(240, parent.height - 48)`; width is `min(preferredWidth, parent.width
- 48)`. The body's own `implicitHeight` is clamped by `bodyRoom()` — the height
left once the chrome has had its share — which is what stops a tall form from
running under the verb row.

**`DialogFooter.qml` — the verb row.** One 60 px surface, 12 px side margins,
8 px gap. Verbs are the app's `PanelAction` (an `AbstractButton` the theme
draws); the default action is `primary` — the one verb painted with the accent.
A form declares its verbs as children, and a value-restoring verb apart on the
left (Defaults, Reset) is separated by an unnamed
`Item { Layout.fillWidth: true }`, the spacer every dialog already wrote by
hand.

**`FormRow.qml` — one row.** The label sits in a fixed column (`labelWidth`,
96 px) and the control starts at one x in every row of every form, unless the
row asks for `labelFill: true` (a checkbox row, or Settings' right-aligned
dropdown), where the label takes the leftover instead. The label is
`textMuted`; the value the control shows is the row's ink.

**`FormSection.qml` — one group.** A 12 px bold heading in `theme.text`, one
1 px hairline, then the rows at `rowSpacing: 8`. Settings grouped in accent-bold
headings with the rule under, the batch form in plain bold headings with the
rule above; one shape now.

**`FormCheck.qml` / `FormRadio.qml` — words the app owns.** The indicator stays
the style's (it already draws the theme's accent); the sentence beside it is
drawn here, in the theme's ink and muted while disabled. Every per-form copy of
that `contentItem` is gone, and the forms that had none get the same colour.

Three naming and lifecycle rules keep tests and hooks honest:

- **Object names are rooted by `namePrefix`** — `<prefix>Header`, `Content`,
  `Column`, `Footer`, `Title`, `Close` (`resizeHeader`, `settingsClose`,
  `batchDialogClose`, `newFolderClose`). A test that must name a part keeps
  naming it, through the one frame.
- **A form does not write `onAboutToShow`; it implements `prepare()`.** The
  frame owns that handler, and `prepare()` runs from it *after* the centred
  position is written: Batch clears its form, Resize fills from the document and
  focuses Width, Settings snapshots its values, New folder clears and focuses
  its field.
- **Nothing is closed by the frame.** The × emits `closeRequested` and the form
  decides: Settings' × is Cancel, which reverts before it closes.

Shapes: Settings stays tabbed and non-fitted (`fitToContent: false`, 620 × 520,
its tabs in `headerStrip`); Resize, Batch, Export, New folder, Delete and Unsaved
fit to content. Both yes/no questions are now `DialogFrame` + `DialogFooter`, so
no word in them comes from `qtbase_<locale>.qm`.

## Consequences

- **One title bar, one inset, one verb row** in all six forms, asserted rather
  than eyeballed: `tests/qml/tst_dialogs.cpp` (ten cases) measures the 52 px
  bar and its margins, the 20 px body inset and the scroll range, one 60 px
  `PanelAction` footer with exactly one trailing `primary`, the label column at
  96 + 8 in Resize and Batch, a tall form scrolling on a 300 px window, a form
  narrowing with a narrow window, and × acting as Cancel (no `resizeRequested`,
  one `revertRequested`). The tenth case is a source guard, because the four
  dialogs inside `Main.qml`, `EditorView.qml` and `BrowserView.qml` need the real
  bridge to load: no `.qml` file may declare a bare `Dialog`, name a
  `DialogButtonBox` or a `MessageDialog`, or write `onAboutToShow` (a form's
  opening work is `prepare()`). Comment lines are skipped — several files name
  those types while explaining why they are gone.
- **The first case found a real bug in the frame itself**: a 320 px body inside
  a 252 px frame on a 300 px window — the body kept its column's height and ran
  under the footer. `bodyRoom()` is the fix, and the scroll-bar assertion is what
  keeps it honest (dropping the clamp fails the case). Four mutations were run
  on the suite and restored: `bodyPadding` 20 → 12 and `headerHeight` 52 → 56
  each fail the inset and the title-bar cases; `SettingsDialog.qml` declaring a
  `Dialog` fails at load; `Main.qml` declaring a `Dialog`, and a form writing
  `onAboutToShow`, each fail the source guard alone.
- **Two colours are no longer the platform's problem.** The × and the tick-box
  sentences are drawn here because a stock item inside a `Popup` resolves the
  platform palette; measured on the real window, the × was an invisible smudge
  and the batch form's checkboxes were near-black on a dark form.
- **Two words left the platform's catalogue**: `Close` and `Delete` are the
  app's, along with `×`, `Fitting`, `Resampling`, `Dimensions` and the resampling
  hint — hand-added to `i18n/kogaview_vi.ts` and then verified against an
  `lupdate6` extraction (a raw run rewrites the file's ~2,800 lines with
  absolute paths and a DOCTYPE).
- **Resize's sections were renamed while they were being grouped**: `Size` →
  `Dimensions` (the catalogue's `Size` is `Dung lượng`, a file's size, and one
  English string owns one translation), and the filter row became its own
  `Resampling` section rather than a third row under `Dimensions`.
- **The Export size dropdown stopped writing its own `contentItem`.** The theme's
  near-white ink on the style's white field was invisible on the real window; the
  list is now a string model so the closed field and its rows are the style's
  own pair.
- **Not changed:** no protocol, Core rule, journal line or layout value moved —
  this is presentation only. No form gained a page, a resize grip, or a
  remembered position; nothing persists `x`/`y`, and a written position still
  wins over the centring rule because the rule does not anchor.
- **Not built:** no dialog-level scroll keyboard handling beyond the form's
  fields, no form-level validation display beyond what each form already had, and
  the two yes/no questions still have no icon.

## Revision — a form's controls wear the theme too (2026-11-23)

The frame unified the chrome and left the *controls* to the platform, and the
light theme found it: the owner reported that text and dialog colours do not
match ("có lỗi chế độ light mode, màu text, màu dialog không cân xứng"). Two
faults and one knock-on, all measured on the real window in light mode.

- **A dialog is a popup, so its palette is nobody's.** A popup's content is
  parented to the window's overlay, not to the window's item tree, so it
  inherits neither the palette `Main.qml` writes from `appTheme` nor the app's
  ink. Every stock control a form still needs — a `ComboBox`, a field, a slider —
  was painted by the desktop's palette: near-black text on white boxes inside the
  dark form, and in light mode a dark form around the desktop's light boxes.
  `DialogFrame` writes the palette from its theme now (window, windowText, base,
  alternateBase, text, button, buttonText, highlight, highlightedText,
  placeholderText, toolTip*, mid/dark/light/shadow).
- **`palette` is a grouped property, so the palette is a function, not a
  binding.** A binding on `palette.*` is evaluated once and never again when the
  theme under it changes — measured: with the binding in place the form stayed
  dark while the theme turned light. `applyPalette()` runs from
  `Component.onCompleted`, from `Theme.onDarkChanged` (Settings switches the
  theme while its own form is open) and again from `onAboutToShow`, so a theme
  changed while the form was shut is not worn by the next open.
- **A form's `theme` is the frame's single property.** `SettingsDialog.qml` and
  `BatchJobDialog.qml` declared a second `property Theme theme: Theme {}` on top
  of the frame's, so the form resolved its own `Theme {}` (dark, by default)
  while the shell's `theme: appTheme` binding went to the other one. The
  duplicate is deleted; a form that needs the theme reads `dialog.theme`.
- **A translated label is not a value.** Settings' theme picker was
  `model: [qsTr("Dark"), qsTr("Light")]`, which makes the words the entries:
  the interface language lands after boot, the model is rebuilt, and a `ComboBox`
  answers a rebuilt model by going back to its first row. The picker then claimed
  Dark while the stored theme was Light, `themeCode()` answered `dark`, and
  simply opening Settings threw the whole window into the dark theme around a
  dark form. The model is `["dark", "light"]` with a translated `displayText` and
  delegate; `prepare()` also writes the form from `initialTheme` so the opening
  state is the stored one, whatever the controls were left holding.
- **A prose line keeps a line box that fits its language.** The hint under the
  form was 11 px, and at that size the box was shorter than the Vietnamese marks:
  every accented word had its top and its bottom bitten off — `Thay đổi được xem
  trước…` lost the hook of `ổ` and the dot of `ụ`, measured on the real window.
  12 px is the smallest size in this window that leaves them whole.
- **Consequences.** The frame now owns the ink of everything inside it, so a new
  form gets readable controls by not doing anything. A stock control's own
  metrics (a `ComboBox`'s popup height, a slider's groove) still come from the
  platform style — only the colours are ours. `tst_dialogs` asserts the palette
  in both themes for every form, `tst_settings` asserts the picker opens on the
  stored theme and that the hint line is at least 12 px.
