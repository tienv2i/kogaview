import QtQuick

// Drag handle between a sidebar and the centre pane.
//
// The width itself belongs to the view (one property per sidebar), so this
// handle never has to know which panel it belongs to: it reports the width the
// user dragged to through `moved`, and the view feeds the clamped result back
// in through `value`. A double-click restores `defaultValue`.
//
// `orientation` says which way the panel grows. The default is the familiar
// column handle beside the Browser's tree; the Editor's dock uses the vertical
// one between its tool options and its reference pages, where the value is a
// height rather than a width.
Item {
    id: splitter

    property Theme theme: Theme {}
    /// Width of the panel this handle resizes.
    property real value: 200
    /// +1 when the panel sits left of (or above) the handle, -1 when it sits
    /// right of (or below) it.
    property int direction: 1
    property real minimum: 180
    property real maximum: 560
    /// Restored on a double-click. Set by the view to its theme default; it must
    /// not be bound to `value`, which the drag writes.
    property real defaultValue: minimum
    /// `Qt.Horizontal` for a handle that resizes a width, `Qt.Vertical` for one
    /// that resizes a height.
    property int orientation: Qt.Horizontal

    signal moved(real value)
    /// The drag ended (or a double-click restored the default). A view that
    /// saves the number waits for this instead of writing one every frame.
    signal released(real value)

    readonly property bool horizontal: splitter.orientation === Qt.Horizontal

    implicitWidth: splitter.horizontal ? 7 : 0
    implicitHeight: splitter.horizontal ? 0 : 7

    function clamp(candidate: real): real {
        return Math.max(minimum, Math.min(maximum, candidate));
    }

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: splitter.horizontal ? 3 : 8
        anchors.rightMargin: splitter.horizontal ? 3 : 8
        anchors.topMargin: splitter.horizontal ? 0 : 3
        anchors.bottomMargin: splitter.horizontal ? 0 : 3
        color: drag.containsMouse || drag.pressed ? splitter.theme.accent : splitter.theme.border
        opacity: drag.containsMouse || drag.pressed ? 1.0 : 0.5
    }

    MouseArea {
        id: drag
        anchors.fill: parent
        cursorShape: splitter.horizontal ? Qt.SplitHCursor : Qt.SplitVCursor

        property real pressSceneX: 0
        property real pressSceneY: 0
        property real startValue: 0

        /// The pointer in scene coordinates.
        ///
        /// This handle *moves* as the panel grows, so `mouse.x` — measured
        /// inside the handle — shifts back by exactly the amount the drag just
        /// added. Feeding that back into the next move made the panel advance by
        /// half the pointer's travel and alternate between two widths as frames
        /// went by: the sidebar lagged behind the cursor and its highlight line
        /// flickered between two positions. Scene coordinates belong to the
        /// window, not to the handle, so the drag is simply "where is the
        /// pointer now, compared to where it grabbed".
        function sceneX(mouse) {
            return splitter.mapToItem(null, mouse.x, mouse.y).x;
        }
        function sceneY(mouse) {
            return splitter.mapToItem(null, mouse.x, mouse.y).y;
        }

        onPressed: function(mouse) {
            pressSceneX = sceneX(mouse);
            pressSceneY = sceneY(mouse);
            startValue = splitter.value;
        }
        // Resized by the *delta* since the press, so a drag that starts anywhere
        // on the handle keeps following the pointer.
        onPositionChanged: function(mouse) {
            if (!pressed) return;
            if (splitter.horizontal) {
                splitter.moved(splitter.clamp(
                    startValue + splitter.direction * (sceneX(mouse) - pressSceneX)));
            } else {
                splitter.moved(splitter.clamp(
                    startValue + splitter.direction * (sceneY(mouse) - pressSceneY)));
            }
        }
        onReleased: splitter.released(splitter.value)
        onDoubleClicked: {
            var value = splitter.clamp(splitter.defaultValue)
            splitter.moved(value)
            splitter.released(value)
        }
    }
}
