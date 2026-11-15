import QtQuick

// Drag handle between a sidebar and the centre pane.
//
// The width itself belongs to the view (one property per sidebar), so this
// handle never has to know which panel it belongs to: it reports the width the
// user dragged to through `moved`, and the view feeds the clamped result back
// in through `value`. A double-click restores `defaultValue`.
Item {
    id: splitter

    property Theme theme: Theme {}
    /// Width of the panel this handle resizes.
    property real value: 200
    /// +1 when the panel sits left of the handle, -1 when it sits right of it.
    property int direction: 1
    property real minimum: 180
    property real maximum: 560
    /// Restored on a double-click. Set by the view to its theme default; it must
    /// not be bound to `value`, which the drag writes.
    property real defaultValue: minimum

    signal moved(real value)

    implicitWidth: 7

    function clamp(candidate: real): real {
        return Math.max(minimum, Math.min(maximum, candidate));
    }

    Rectangle {
        anchors.fill: parent
        anchors.leftMargin: 3
        anchors.rightMargin: 3
        color: drag.containsMouse || drag.pressed ? splitter.theme.accent : splitter.theme.border
        opacity: drag.containsMouse || drag.pressed ? 1.0 : 0.5
    }

    MouseArea {
        id: drag
        anchors.fill: parent
        cursorShape: Qt.SplitHCursor

        property real pressSceneX: 0
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

        onPressed: function(mouse) {
            pressSceneX = sceneX(mouse);
            startValue = splitter.value;
        }
        // Resized by the *delta* since the press, so a drag that starts anywhere
        // on the handle keeps following the pointer.
        onPositionChanged: function(mouse) {
            if (!pressed) return;
            splitter.moved(
                splitter.clamp(startValue + splitter.direction * (sceneX(mouse) - pressSceneX)));
        }
        onDoubleClicked: splitter.moved(splitter.clamp(splitter.defaultValue))
    }
}
