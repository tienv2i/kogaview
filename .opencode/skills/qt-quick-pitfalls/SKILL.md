---
name: qt-quick-pitfalls
description: Use before editing QML in this project, or when debugging input handlers, zoom/pan math, popups, menus or text metrics in the Qt Quick UI. Lists the traps this codebase has already hit, what each looks like from the outside, and the check that catches it.
---

# Qt Quick traps this project has already hit

Each entry is grounded in a real defect or measurement here, with the row in
`docs/M1-REPORT.md` where the evidence lives. Read the symptom first: that is
what you will see before you know the cause.

## 1. `popup()` opens at the global cursor, not at the click

**Symptom.** A context menu appears wherever the pointer happened to be, or at
the top-left corner for a synthetic click. Measured (row 51): a click at window
`(640, 366)` produced a menu at `(873, 185)` because the handler called
`canvasMenu.popup()`.

**Cause.** The no-argument overload asks the compositor for the cursor position.
That is only correct for a *physical* click, and Wayland does not always report it.

**Check / fix.** Take the event position and place the popup yourself:

```qml
onSingleTapped: function(point) {
    var local = viewport.mapToItem(view, point.position.x, point.position.y);
    menu.popup(view, local.x, local.y);
}
```

`point.position` is in the handler's **parent** item. Afterwards, `menu.x`/`menu.y`
are relative to the item passed to `popup()` (Qt re-parents the popup and
converts), so do not read them as window coordinates — the picture is what pins
the placement. A test that asserts `menu.x`/`menu.y` at the click point only
distinguishes the two behaviours if the surrounding layout has a non-zero offset
or the assertion is made against the click, so also look at one screenshot.

## 2. `WheelHandler.acceptedDevices` ignores touchpads by default

**Symptom.** Wheel scrolling works with a mouse and does nothing on a laptop
touchpad; the view is otherwise fine. `WheelHandler` defaults to
`PointerDevice.Mouse`, so a Wayland touchpad's virtual pointer is dropped.

**Check / fix.** `acceptedDevices: PointerDevice.AllDevices`. Read the property at
runtime (`KOGAVIEW_DEV_GEOM`) before blaming the compositor — the handler, not
the session, is usually the problem.

## 3. Right click needs its own handler; drag is left-button by default

`TapHandler` and `DragHandler` default to `acceptedButtons: Qt.LeftButton`. A
right-click menu therefore needs a separate `TapHandler` with
`acceptedButtons: Qt.RightButton`, and it will not interfere with the left-button
double-tap handler or the pan drag. Two handlers of the same type on one item are
fine; they grab by button.

**Symptom of getting it wrong.** Left click starts opening menus, or the double
tap stops working because one handler took both buttons.

## 4. `Item.scale` transforms around `Item.Center`

Zoom that also moves the item must not bake `scale` into `x`/`y` bindings: the
transform is applied about the item's centre, so an `x` offset is scaled as well
and the anchor drifts. Compute the anchor in item coordinates (`Viewer.qml` keeps
the canvas at its natural size inside a clipped viewport and moves the viewport's
`contentX`/`contentY`), and let one layer own the math.

**Check.** Assert the *canvas* rect relative to the viewport after a zoom at a
point, not the window pixels.

## 5. A binding that reads what it writes loops every frame

**Symptom.** `Binding loop detected for property "font"` on stderr, repeatedly, and
a menu that jitters or resizes.

**Cause.** `Menu.font` follows `Menu.implicitWidth`, and a `TextMetrics` inside the
menu measured a label with that font — each wrote what the other read.

**Fix.** Measure where nothing feeds back: `PlatformHelper::textWidths` in C++
(`Platform.textWidths`), or an item outside the bound chain. Note that Qt 6.12
will not re-evaluate a binding whose function has side effects, so a
self-healing binding is not a plan.

## 6. Menu width comes from a measured catalogue, and new labels must join it

Menus are sized from `Theme.menuWidth(...)` over `Theme.menuEntryLabels`, measured
in C++ — not from the style's fixed 200 px. Adding a `MenuItem` with a new label
without adding that label to the catalogue leaves the entry clipped.

Two guards, both needed:

- `everyShellMenuLabelIsMeasured` (`tests/qml/tst_browser.cpp`) scans `Main.qml`,
  `BrowserView.qml` and `Viewer.qml` for `MenuItem` labels and fails on any label
  the catalogue does not measure.
- `everyMenuLabelIsMeasured` asserts the rendered width for menus the suite can
  instantiate.

The catalogue is a *list of widths*, so a shorter label changes nothing visible; a
longer one silently widens every menu. Re-check one screenshot after touching it.

## 7. A QML test proves the model, the window proves the pixels

`tests/qml/` loads the real `.qml` sources, so a QML-only edit is covered by
`just test qml` with no rebuild — but those tests argue from properties,
transforms and emitted signals, never from pixels. "The menu is wide enough",
"the label is not elided", "the chooser appeared" are only true on a real window.

And the real window has its own trap: `QT_QPA_PLATFORM=offscreen` loads no icon
theme, so every themed icon is blank there. Icons and anything else from the
platform theme must be judged on a Wayland run.

## 8. Isolate the component before blaming the compositor

When an input handler looks dead, build a minimal runner that loads the single
QML file with a stub state, or inspect the handler's properties at runtime
(`acceptedButtons`, `acceptedDevices`, `enabled`, which item owns it). This
project has lost time to "Wayland drops right clicks" when a handler had the wrong
button, and to "dialogs do not appear" when the portal back end was the cause.

A handler that never fires leaves nothing in the command journal or the log —
that silence is the clue that points at the QML, not at the state.