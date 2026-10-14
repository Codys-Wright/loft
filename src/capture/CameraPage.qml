import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Island page while the camera mirror is on: what it shows and its
// controls (shape, flip, size, off).
Item {
    id: root

    readonly property var cfg: Capture.cfg

    component Round: Rectangle {
        id: btn
        property string icon
        property string label
        property color tint: Theme.islandText
        property bool on: false
        signal clicked

        Layout.preferredWidth: 60
        Layout.preferredHeight: 62
        radius: 18
        color: on ? Theme.withAlpha(Theme.accent, 0.3) : mouse.containsMouse ? Theme.withAlpha(tint, 0.24) : Theme.withAlpha(tint, 0.14)

        Column {
            anchors.centerIn: parent
            spacing: 3
            Icon {
                anchors.horizontalCenter: parent.horizontalCenter
                text: btn.icon
                size: 20
                color: btn.on ? Theme.accent : btn.tint
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: btn.label
                color: Theme.islandSubtext
                font.family: Theme.fontUi
                font.pixelSize: 10
            }
        }
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }

    ColumnLayout {
        anchors {
            fill: parent
            margins: 22
            bottomMargin: 30
        }
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Rectangle {
                Layout.preferredWidth: 10
                Layout.preferredHeight: 10
                radius: 5
                color: Capture.cameraState === "live" ? Theme.ok : Capture.cameraState === "starting" ? Theme.warn : Theme.islandSubtext
            }
            Text {
                text: "Camera"
                color: Theme.islandText
                font.family: Theme.fontUi
                font.pixelSize: 16
                font.weight: Font.DemiBold
            }
            Text {
                Layout.fillWidth: true
                text: {
                    switch (Capture.cameraState) {
                    case "live":
                        return Capture.cameraName;
                    case "none":
                        return "No camera";
                    case "unavailable":
                        return "Preview unavailable";
                    case "error":
                        return Capture.cameraError || "Error";
                    default:
                        return "Starting…";
                    }
                }
                color: Theme.islandSubtext
                font.family: Theme.fontUi
                font.pixelSize: 13
                elide: Text.ElideRight
            }
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 10

            Round {
                icon: "󰄰"
                label: "Circle"
                on: root.cfg.cameraShape === "circle"
                onClicked: root.cfg.cameraShape = "circle"
            }
            Round {
                icon: "󰆟"
                label: "Rounded"
                on: root.cfg.cameraShape !== "circle"
                onClicked: root.cfg.cameraShape = "rounded"
            }
            Round {
                icon: "󰓡"
                label: "Mirror"
                on: root.cfg.cameraMirror
                onClicked: root.cfg.cameraMirror = !root.cfg.cameraMirror
            }
            Round {
                icon: "󰐕"
                label: "Bigger"
                onClicked: root.cfg.cameraSize = Math.min(520, root.cfg.cameraSize + 40)
            }
            Round {
                icon: "󰍴"
                label: "Smaller"
                onClicked: root.cfg.cameraSize = Math.max(120, root.cfg.cameraSize - 40)
            }
            Round {
                icon: "󰗟"
                label: "Off"
                tint: Theme.urgent
                onClicked: Capture.cameraOn = false
            }
        }
    }
}
