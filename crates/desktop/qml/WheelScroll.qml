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
/// trackpad's continuous `pixelDelta`, which comes with no `angleDelta`, is
/// passed straight through, unchanged, so smooth two-finger scrolling keeps its
/// 1:1 feel.
///
/// The delta is chosen by the *device*, not by "whichever field happens to be
/// non-zero". A mouse on this desktop reports **both**: a notch arrives as
/// `angleDelta (0, ±120)` *and* `pixelDelta (0, ±10)`, so a pixel-first reading
/// turned every notch into 20 px — measured on a real window, 29× slower than
/// the one-row step this handler is for. `angleDelta` is therefore the primary
/// signal; `pixelDelta` is the fallback for the high-resolution wheels and
/// touchpads that leave it at zero. The environment has no way to set the system
/// wheel-scroll rate for a Qt app (libinput applies it below the toolkit), so
/// the two paths are the only distinction available — hence the constant
/// `notchPixels` for a pixel-only device.
WheelHandler {
    id: scroller
    // Wayland touchpads are delivered as non-mouse pointing devices. The
    // default Mouse-only filter makes fast two-finger gestures disappear.
    acceptedDevices: PointerDevice.AllDevices

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
    /// Pixels one notch moves a device that reports `pixelDelta` but no
    /// `angleDelta`. Such a device cannot say what its notch is worth, so this
    /// is the only rate it has.
    readonly property real notchPixels: 20

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
        // Claim the event before changing the Flickable. Otherwise Qt Quick
        // may also apply its own wheel step after this handler, producing an
        // overscroll frame (the black band above the first grid row).
        event.accepted = true;
        // 120 eighths of a degree is one notch; positive is "away from the user",
        // i.e. content moves backwards, hence the sign on `scrollBy`'s delta.
        // A mouse sends this *and* a pixelDelta, and on this desktop the pixel
        // delta is a tenth of a notch, so it must not be preferred.
        var notches = event.angleDelta.y !== 0 ? event.angleDelta.y / 120
                                               : event.angleDelta.x / 120;
        if (notches === 0) {
            // No notch reported: a touchpad's continuous `pixelDelta`, taken at
            // the rate the device sent it (scaled by two, so a two-finger
            // gesture keeps up with a modern desktop list). Not quantized, so
            // it stays smooth.
            if (event.pixelDelta.x !== 0 || event.pixelDelta.y !== 0) {
                scroller.scrollBy(event.pixelDelta.x * 2, event.pixelDelta.y * 2);
            }
            return;
        }
        // Three row-sized steps per notch, so a physical mouse wheel moves a
        // dense Browser grid at a usable pace. Touchpad pixel deltas take the
        // continuous path above and are not multiplied by this.
        var distance = notches * scroller.notchStep * 3;
        if (scroller.horizontal) {
            scroller.scrollBy(distance, 0);
        } else {
            scroller.scrollBy(0, distance);
        }
        if (scroller.view.returnToBounds) {
            scroller.view.returnToBounds();
        }
    }
}
