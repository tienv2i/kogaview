import QtQuick

/// Smooth, accelerated wheel scrolling for `Flickable`, `ListView`, and `GridView`.
///
/// - Mouse wheel notches (`angleDelta`) use a gentle base step (~1.1x row) that
///   accelerates smoothly up to 2.4x when spun rapidly in the same direction,
///   gliding with a fast 130 ms OutCubic deceleration curve.
/// - Touchpad two-finger gestures (`pixelDelta` without `angleDelta`) bypass
///   the glide animation so scrolling stays 1:1 locked to the user's fingers.
WheelHandler {
    id: scroller
    acceptedDevices: PointerDevice.AllDevices

    property var view: null
    property real step: 0
    property bool horizontal: false
    readonly property real notchPixels: 20

    readonly property real notchStep: scroller.step > 0
                                      ? scroller.step
                                      : (scroller.horizontal ? scroller.view.width * 0.9
                                                             : scroller.view.height * 0.9)

    // Acceleration state for consecutive same-direction mouse wheel notches.
    property real _lastWheelMs: 0
    property int _lastDir: 0
    property real _accel: 1.0
    property real _targetPos: 0

    property NumberAnimation _glideAnim: NumberAnimation {
        id: glideAnim
        target: scroller.view
        property: scroller.horizontal ? "contentX" : "contentY"
        duration: 130
        easing.type: Easing.OutCubic
        onFinished: {
            if (scroller.view && scroller.view.returnToBounds) {
                scroller.view.returnToBounds();
            }
        }
    }

    function _maxPos(): real {
        var target = scroller.view;
        if (!target) return 0;
        return scroller.horizontal
               ? Math.max(0, target.contentWidth - target.width)
               : Math.max(0, target.contentHeight - target.height);
    }

    /// Immediate scroll (used by touchpad continuous pixel deltas).
    function scrollBy(dx: real, dy: real): void {
        var target = scroller.view;
        if (!target) return;
        glideAnim.stop();
        var maxX = Math.max(0, target.contentWidth - target.width);
        var maxY = Math.max(0, target.contentHeight - target.height);
        target.contentX = Math.max(0, Math.min(maxX, target.contentX - dx));
        target.contentY = Math.max(0, Math.min(maxY, target.contentY - dy));
    }

    /// Smoothly glide by `delta` pixels along the active axis.
    function glideBy(delta: real): void {
        var target = scroller.view;
        if (!target) return;
        var current = scroller.horizontal ? target.contentX : target.contentY;
        var base = glideAnim.running ? scroller._targetPos : current;
        var next = Math.max(0, Math.min(scroller._maxPos(), base - delta));
        scroller._targetPos = next;
        glideAnim.stop();
        glideAnim.from = current;
        glideAnim.to = next;
        glideAnim.start();
    }

    onWheel: function(event) {
        if (!scroller.view) return;
        event.accepted = true;
        var notches = event.angleDelta.y !== 0 ? event.angleDelta.y / 120
                                               : event.angleDelta.x / 120;
        if (notches === 0) {
            if (event.pixelDelta.x !== 0 || event.pixelDelta.y !== 0) {
                scroller.scrollBy(event.pixelDelta.x * 1.2, event.pixelDelta.y * 1.2);
            }
            return;
        }

        // Compute spin acceleration: rapid consecutive notches in the same
        // direction ramp smoothly from 1.0x up to 2.4x; pausing or reversing
        // resets back to gentle 1.0x precision.
        var now = Date.now();
        var dir = notches > 0 ? 1 : -1;
        var dt = now - scroller._lastWheelMs;
        if (dir === scroller._lastDir && dt > 0 && dt < 180) {
            scroller._accel = Math.min(2.4, scroller._accel + 0.35);
        } else if (dir !== scroller._lastDir || dt >= 240) {
            scroller._accel = 1.0;
        }
        scroller._lastWheelMs = now;
        scroller._lastDir = dir;

        var distance = notches * scroller.notchStep * 1.1 * scroller._accel;
        scroller.glideBy(distance);
    }
}
