import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import io.github.huynhat.KogaView 1.0

ApplicationWindow {
    id: root

    width: 1100
    height: 720
    visible: true
    title: bridge.appName
    color: systemPalette.window

    SystemPalette {
        id: systemPalette
    }

    KogaViewBridge {
        id: bridge
    }

    header: ToolBar {
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 12

            Label {
                text: bridge.appName
                font.bold: true
            }

            Label {
                text: "v" + bridge.appVersion + " · " + bridge.gitSha
                opacity: 0.7
            }

            Item {
                Layout.fillWidth: true
            }

            Label {
                text: "profile: " + bridge.profile
                opacity: 0.8
            }
        }
    }

    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 96, 720)
        spacing: 14

        Label {
            text: "Browser workspace"
            font.pixelSize: 30
            font.bold: true
            Layout.alignment: Qt.AlignHCenter
        }

        Label {
            text: bridge.statusMessage
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
            opacity: 0.8
        }

        Label {
            text: "App ID: " + bridge.appId
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WrapAnywhere
            Layout.fillWidth: true
            opacity: 0.6
        }

        Button {
            text: "Run M0 bridge probe"
            Layout.alignment: Qt.AlignHCenter
            Accessible.name: text
            onClicked: bridge.devProbe("probe from QML")
        }

        Label {
            visible: bridge.probeCount > 0
            text: "probe count: " + bridge.probeCount + " (see structured log)"
            Layout.alignment: Qt.AlignHCenter
            opacity: 0.6
        }
    }

    footer: ToolBar {
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 16

            Label {
                text: "workspace: " + bridge.workspace
            }

            Label {
                text: "state revision: " + bridge.stateRevision
            }

            Item {
                Layout.fillWidth: true
            }

            Label {
                text: "protocol v" + bridge.protocolVersion
                opacity: 0.7
            }
        }
    }
}
