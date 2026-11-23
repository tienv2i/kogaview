import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

/// The chrome every modal form in this window wears.
///
/// The forms were built in three sittings and their chrome drifted: the title
/// bar was 52 px in all of them, but the × sat at a different distance from the
/// edge and the drag clamp was copy-pasted; two bodies kept 20 px and the batch
/// form kept it too but with its own scroll range; two footers were 60 px and
/// the third was a stock button row, so Settings' verbs were a different shape
/// from the Batch form's. Copying is what made them differ, so the chrome lives
/// here once and a form supplies only its body:
///
/// - a 52 px title bar (`headerHeight`): the title, a ×, and a drag handler that
///   moves the dialog and clamps it inside the window;
/// - a body that keeps `bodyPadding` (20 px) on all four sides and scrolls, so a
///   form taller than the window says so with a scroll bar instead of clipping
///   under the footer;
/// - a 60 px action row (`footerHeight`) drawn by `DialogFooter.qml`;
/// - one centring rule (`centreInParent`) that runs before the first visible
///   frame, because centring in `opened` made the form jump after the style's
///   fade.
///
/// A form declares its fields as children — they land in the body's column — and
/// its verbs by overriding `footer`, which keeps the declaration order on
/// screen. `namePrefix` roots the chrome's own object names (`resizeHeader`,
/// `resizeContent`, `resizeColumn`), so a test and a dev hook can still name the
/// part they mean. `prepare()` is the form's own opening work (its values, its
/// focused field): the frame calls it from `onAboutToShow`, because that
/// handler is the frame's and a form cannot also write it.
Dialog {
    id: frame

    property Theme theme: Theme {}

    /// Root of this frame's object names: `namePrefix + "Header"`, `"Content"`,
    /// `"Column"`, `"Footer"`.
    property string namePrefix: ""

    /// The width the form asks for. The window may force it narrower.
    property int preferredWidth: 520
    /// `true`: as tall as the form needs, up to the window — the shape a form of
    /// fields has, because a short form should not leave a blank page under its
    /// verbs. `false`: at least `preferredHeight`, growing to fit the current
    /// page when the window has room so unnecessary scrollbars disappear.
    property bool fitToContent: true
    property int preferredHeight: 520

    /// Interactive resizing inside the parent window bounds.
    property bool resizable: true
    property int minWidth: 360
    property int minHeight: 240
    property bool userResized: false
    property real customWidth: 0
    property real customHeight: 0

    readonly property real maxDialogWidth:
        parent ? Math.max(frame.minWidth, parent.width - 48) : 960
    readonly property real maxDialogHeight:
        parent ? Math.max(frame.minHeight, parent.height - 48) : 800

    /// A strip between the title bar and the scrolling body, for a form with
    /// pages: `Component { PanelTabs { … } }`. It takes the height it needs and
    /// does not scroll with the body. `null` for a plain form.
    property Component headerStrip: null

    readonly property int headerHeight: 52
    readonly property int footerHeight: 60
    /// Space the body keeps around its column, on all four sides.
    readonly property int bodyPadding: 20
    /// The width of a row's label column. A form passes this to every `FormRow`,
    /// which is what makes two rows line up.
    readonly property int labelWidth: 96
    /// The gap between two rows of a body.
    readonly property int rowSpacing: 10

    /// The × was pressed. The frame does not close itself: Settings' × is
    /// Cancel, which reverts before it closes, and only the form knows that.
    signal closeRequested()

    /// The form's fields. They are added to the body's `ColumnLayout`, so a form
    /// writes them exactly as it would write a column.
    default property alias content: bodyColumn.data

    /// Whether the user has moved the dialog by its title bar, which is what
    /// stops the centring rule from snapping it back on the next size change.
    property bool moved: false

    /// Centre the dialog in its parent. Called from `aboutToShow` — before the
    /// first frame — and from every size change until the user drags it.
    function centreInParent() {
        if (!parent) return
        x = Math.round((parent.width - width) / 2)
        y = Math.round((parent.height - height) / 2)
    }

    /// The form's own opening work, in the form's own file. The frame calls it
    /// from `aboutToShow`, after the centred position is written.
    function prepare() {}

    title: ""
    modal: true
    dim: true
    padding: 0
    // Escape is Cancel; a click outside does not dismiss, because a form should
    // be left on purpose.
    closePolicy: Popup.CloseOnEscape
    width: {
        var wanted = frame.userResized && frame.customWidth > 0
                     ? frame.customWidth : frame.preferredWidth
        var limit = parent ? Math.max(240, parent.width - 48) : wanted
        return Math.min(limit, Math.max(Math.min(frame.minWidth, limit), wanted))
    }
    // Auto-fit content height without overflowing the parent window: both plain
    // and tabbed forms expand to avoid unnecessary scrollbars when the window
    // has room, while still clamping inside `parent.height - 48`.
    height: {
        var limit = parent ? Math.max(240, parent.height - 48) : 800
        if (frame.userResized && frame.customHeight > 0) {
            return Math.min(limit, Math.max(Math.min(frame.minHeight, limit), frame.customHeight))
        }
        var chrome = frame.headerHeight + frame.footerHeight
                     + 2 * frame.bodyPadding + frame.stripHeight() + 4
        var natural = chrome + bodyColumn.implicitHeight
        if (!frame.fitToContent) return Math.min(limit, Math.max(frame.preferredHeight, natural))
        return Math.min(limit, natural)
    }

    /// The strip's height, or zero when the form has no strip.
    function stripHeight() {
        if (!stripLoader.item) return 0
        var item = stripLoader.item
        return item.implicitHeight > 0 ? item.implicitHeight : item.height
    }

    /// Everything the body does not own: the two bars, and the strip between
    /// them when the form has pages.
    function chromeHeight() {
        return frame.headerHeight + frame.footerHeight + frame.stripHeight()
    }

    /// The height the body may take inside the frame. A form that fits asks for
    /// its column's height — but never for more than is left once the chrome has
    /// had its share. Without this the body kept the height its column wanted
    /// and ran underneath the footer on a window too short for it: measured on a
    /// 300 px window, a 320 px body inside a 252 px frame.
    function bodyRoom() {
        return Math.max(0, frame.height - frame.chromeHeight())
    }

    onWidthChanged: if (!moved) centreInParent()
    onHeightChanged: if (!moved) centreInParent()
    onAboutToShow: {
        moved = false
        userResized = false
        customWidth = 0
        customHeight = 0
        centreInParent()
        // The palette is written again on every opening: a theme switched while
        // the form was shut must not be worn by the next open.
        frame.applyPalette()
        frame.prepare()
    }

    // A dialog is a popup, and a popup's content is parented to the window's
    // overlay instead of to the window's own item tree, so it inherits neither
    // the shell's palette (`Main.qml` writes one from `appTheme`) nor the app's
    // ink. Without this the stock controls a form still needs — a `ComboBox`, a
    // field, a slider — were painted by the desktop's palette: white boxes with
    // near-black text on the dark form, and in light mode a dark form under
    // light boxes, which is what "the dialog and its text do not match" looked
    // like on the real window. Measured in both themes.
    //
    // It is a function rather than a binding on purpose. `palette` is a grouped
    // property, and a grouped binding here is evaluated once and never again
    // when the theme under it changes — measured: with the binding in place the
    // palette stayed dark while the theme turned light, and Settings switches
    // the theme *while this form is open*.
    function applyPalette() {
        palette.window = frame.theme.surface
        palette.windowText = frame.theme.text
        palette.base = frame.theme.thumb
        palette.alternateBase = frame.theme.surfaceAlt
        palette.text = frame.theme.text
        palette.button = frame.theme.surfaceAlt
        palette.buttonText = frame.theme.text
        palette.highlight = frame.theme.accent
        palette.highlightedText = frame.theme.accentText
        palette.placeholderText = frame.theme.textMuted
        palette.toolTipBase = frame.theme.surfaceAlt
        palette.toolTipText = frame.theme.text
        palette.mid = frame.theme.border
        palette.dark = frame.theme.border
        palette.light = frame.theme.surface
        palette.shadow = frame.theme.border
    }

    /// The theme's own switch: `Theme.dark` is the one value every colour is
    /// derived from, and it is the one a live preview flips first.
    Connections {
        target: frame.theme
        function onDarkChanged() { frame.applyPalette() }
    }
    Component.onCompleted: frame.applyPalette()

    background: Rectangle {
        color: frame.theme.surface
        border.color: frame.theme.border
        border.width: 1
        radius: frame.theme.radius

        // Right-edge resize handle.
        MouseArea {
            objectName: frame.namePrefix + "ResizeRight"
            visible: frame.resizable
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: parent.right
            anchors.topMargin: frame.headerHeight
            anchors.bottomMargin: 12
            width: 6
            cursorShape: Qt.SizeHorCursor
            property real startX: 0
            property real startW: 0
            onPressed: function(mouse) {
                startX = mapToItem(frame.parent, mouse.x, mouse.y).x
                startW = frame.width
                frame.userResized = true
                frame.moved = true
            }
            onPositionChanged: function(mouse) {
                if (!pressed) return
                var nowX = mapToItem(frame.parent, mouse.x, mouse.y).x
                var maxW = frame.parent ? Math.max(frame.minWidth, frame.parent.width - frame.x - 8) : 1200
                frame.customWidth = Math.max(frame.minWidth, Math.min(maxW, startW + (nowX - startX)))
            }
        }

        // Bottom-edge resize handle.
        MouseArea {
            objectName: frame.namePrefix + "ResizeBottom"
            visible: frame.resizable
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: 12
            height: 6
            cursorShape: Qt.SizeVerCursor
            property real startY: 0
            property real startH: 0
            onPressed: function(mouse) {
                startY = mapToItem(frame.parent, mouse.x, mouse.y).y
                startH = frame.height
                frame.userResized = true
                frame.moved = true
            }
            onPositionChanged: function(mouse) {
                if (!pressed) return
                var nowY = mapToItem(frame.parent, mouse.x, mouse.y).y
                var maxH = frame.parent ? Math.max(frame.minHeight, frame.parent.height - frame.y - 8) : 1000
                frame.customHeight = Math.max(frame.minHeight, Math.min(maxH, startH + (nowY - startY)))
            }
        }

        // Bottom-right corner resize grip.
        Item {
            objectName: frame.namePrefix + "ResizeCorner"
            visible: frame.resizable
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            width: 14
            height: 14
            z: 20

            Canvas {
                anchors.fill: parent
                onPaint: {
                    var ctx = getContext("2d")
                    ctx.reset()
                    ctx.strokeStyle = frame.theme.textMuted
                    ctx.globalAlpha = 0.55
                    ctx.lineWidth = 1.2
                    ctx.beginPath()
                    ctx.moveTo(4, 12); ctx.lineTo(12, 4)
                    ctx.moveTo(8, 12); ctx.lineTo(12, 8)
                    ctx.stroke()
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.SizeFDiagCursor
                property real startX: 0
                property real startY: 0
                property real startW: 0
                property real startH: 0
                onPressed: function(mouse) {
                    var pt = mapToItem(frame.parent, mouse.x, mouse.y)
                    startX = pt.x
                    startY = pt.y
                    startW = frame.width
                    startH = frame.height
                    frame.userResized = true
                    frame.moved = true
                }
                onPositionChanged: function(mouse) {
                    if (!pressed) return
                    var pt = mapToItem(frame.parent, mouse.x, mouse.y)
                    var maxW = frame.parent ? Math.max(frame.minWidth, frame.parent.width - frame.x - 8) : 1200
                    var maxH = frame.parent ? Math.max(frame.minHeight, frame.parent.height - frame.y - 8) : 1000
                    frame.customWidth = Math.max(frame.minWidth, Math.min(maxW, startW + (pt.x - startX)))
                    frame.customHeight = Math.max(frame.minHeight, Math.min(maxH, startH + (pt.y - startY)))
                }
            }
        }
    }

    header: Rectangle {
        objectName: frame.namePrefix + "Header"
        implicitHeight: frame.headerHeight
        color: frame.theme.surfaceAlt
        border.color: frame.theme.border
        border.width: 1

        // The title bar moves the dialog. `target: null` keeps the handler off
        // the header's own coordinates and moves the dialog instead; the clamp
        // stops a drag from parking it outside the window.
        DragHandler {
            target: null
            property real originX: 0
            property real originY: 0
            onActiveChanged: if (active) {
                originX = frame.x
                originY = frame.y
                frame.moved = true
            }
            onActiveTranslationChanged: {
                if (!active) return
                var maxX = frame.parent ? Math.max(0, frame.parent.width - frame.width) : frame.x
                var maxY = frame.parent ? Math.max(0, frame.parent.height - frame.height) : frame.y
                frame.x = Math.max(0, Math.min(maxX, originX + activeTranslation.x))
                frame.y = Math.max(0, Math.min(maxY, originY + activeTranslation.y))
            }
        }

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 18
            anchors.rightMargin: 10
            spacing: 8

            Label {
                objectName: frame.namePrefix + "Title"
                text: frame.title
                color: frame.theme.text
                font.pixelSize: 17
                font.bold: true
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            ToolButton {
                objectName: frame.namePrefix + "Close"
                implicitWidth: 32
                implicitHeight: 32
                focusPolicy: Qt.NoFocus
                activeFocusOnTab: false
                Accessible.name: qsTr("Close")
                onClicked: frame.closeRequested()

                // The glyph and its ink are the app's own. A stock `ToolButton`
                // draws its label with the platform palette's button text, which
                // on this window is black on a near-black bar: measured on the
                // real window, the × was an invisible smudge until it was drawn
                // here.
                contentItem: Text {
                    text: qsTr("×")
                    color: closeHover.hovered ? frame.theme.text : frame.theme.textMuted
                    font.pixelSize: 22
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    radius: frame.theme.radius
                    color: closeHover.hovered ? frame.theme.hover : "transparent"
                }
                HoverHandler { id: closeHover }
            }
        }
    }

    contentItem: ColumnLayout {
        spacing: 0

        Loader {
            id: stripLoader
            Layout.fillWidth: true
            active: frame.headerStrip !== null
            sourceComponent: frame.headerStrip
        }

        Flickable {
            id: body
            objectName: frame.namePrefix + "Content"
            Layout.fillWidth: true
            // A form that fits takes only the height its column needs, so the
            // dialog is exactly as tall as its content; a tabbed form claims the
            // rest of the height it asked for.
            Layout.fillHeight: !frame.fitToContent
            implicitHeight: frame.fitToContent
                            ? Math.min(bodyColumn.implicitHeight + 2 * frame.bodyPadding,
                                       frame.bodyRoom()) : 0
            contentHeight: bodyColumn.implicitHeight + 2 * frame.bodyPadding
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            // The bar is drawn here, not left to the style: the platform
            // scrollbar paints its own greys, which on this dialog's surface are
            // the same grey as the surface itself — measured on the real window,
            // a form that overflows said nothing.
            ScrollBar.vertical: ScrollBar {
                id: bodyBar
                // Only show the scrollbar when content genuinely overflows the
                // body (a 1–2 px border/rounding delta never triggers a bar).
                policy: body.contentHeight > body.height + 2
                        ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
                contentItem: Rectangle {
                    implicitWidth: 6
                    radius: 3
                    color: frame.theme.textMuted
                    opacity: bodyBar.active ? 0.9 : 0.45
                }
            }

            ColumnLayout {
                id: bodyColumn
                objectName: frame.namePrefix + "Column"
                x: frame.bodyPadding
                y: frame.bodyPadding
                width: body.width - 2 * frame.bodyPadding
                spacing: frame.rowSpacing
            }
        }
    }

    footer: DialogFooter {
        namePrefix: frame.namePrefix
        theme: frame.theme
        height: frame.footerHeight
    }
}
