import QtQuick

/// Wheel scrolling that keeps up, for a `Flickable`, `ListView` or `GridView`.
///
/// Qt's own handling does two things that read as "the wheel is broken":
///
/// - It moves a view by a fixed ~72 px per notch whatever the item size, so a
///   grid whose cells are ~194 px advances by a third of a row and a tree crawls.
/// - It only moves the axis the wheel reports. A mouse wheel reports a *vertical*
///   delta, so a horizontal view — the Viewer's filmstrip — does not move at all.
///
/// This handler takes the event before the view does (`event.accepted = true`
/// stops the view's own wheel handling) and maps it deliberately: one notch is
/// `step` pixels, and a horizontal view scrolls from a vertical wheel. A
/// trackpad's continuous `pixelDelta` is passed straight through, unchanged, so
/// smooth two-finger scrolling keeps its 1:1 feel.
WheelHandler {
    id: scroller

    /// The view to scroll. Set it explicitly — a handler cannot infer it, and a
    /// silent default would be a scroll wheel that does nothing.
    property var view: null
    /// Pixels per wheel notch. Every view wires an explicit value — one grid row,
    /// a few tree rows, three filmstrip tiles — because the notch is the unit the
    /// user feels. 0 falls back to "most of the viewport", which is only a
    /// sensible last resort.
    property real step: 0
    /// True for a horizontally scrolling view, such as the filmstrip.
    property bool horizontal: false

    readonly property real notchStep: scroller.step > 0
                                      ? scroller.step
                                      : (scroller.horizontal ? scroller.view.width * 0.9
                                                             : scroller.view.height * 0.9)

    /// Move `view` by a scroll delta, clamped to what it can actually scroll.
    function scrollBy(dx: real, dy: real): void {
        var target = scroller.view;
        if (!target) return;
        var maxX = Math.max(0, target.contentWidth - target.width);
        var maxY = Math.max(0, target.contentHeight - target.height);
        target.contentX = Math.max(0, Math.min(maxX, target.contentX - dx));
        target.contentY = Math.max(0, Math.min(maxY, target.contentY - dy));
    }

    onWheel: function(event) {
        if (!scroller.view) return;
        if (event.pixelDelta.x !== 0 || event.pixelDelta.y !== 0) {
            // Continuous device: use the pixels the touchpad reported.
            scroller.scrollBy(event.pixelDelta.x, event.pixelDelta.y);
            event.accepted = true;
            return;
        }
        // 120 eighths of a degree is one notch; positive is "away from the user",
        // i.e. content moves backwards, hence the sign on `scrollBy`'s delta.
        var notches = event.angleDelta.y !== 0 ? event.angleDelta.y / 120
                                               : event.angleDelta.x / 120;
        if (notches === 0) {
            return;
        }
        var distance = notches * scroller.notchStep;
        if (scroller.horizontal) {
            scroller.scrollBy(distance, 0);
        } else {
            scroller.scrollBy(0, distance);
        }
        event.accepted = true;
    }
}
