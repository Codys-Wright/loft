import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.components
import qs.services

// Island page: notification history, newest first. Click one to activate
// it; × dismisses; "Clear" dismisses all.
Item {
    id: root

    readonly property var items: Notifications.history.slice().reverse()

    ColumnLayout {
        anchors {
            fill: parent
            margins: 16
            bottomMargin: 24
        }
        spacing: 8

        RowLayout {
            Layout.fillWidth: true

            Text {
                Layout.fillWidth: true
                text: `Notifications  ·  ${root.items.length}`
                color: Theme.islandText
                font.family: Theme.fontUi
                font.pixelSize: 14
                font.weight: Font.DemiBold
            }

            Text {
                text: "Clear"
                color: Theme.accent
                font.family: Theme.fontUi
                font.pixelSize: 12
                font.weight: Font.Medium

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Notifications.clearHistory()
                }
            }
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 6
            model: root.items
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                id: row
                required property var modelData
                width: ListView.view.width
                height: 52
                radius: 14
                color: mouse.containsMouse ? Theme.withAlpha(Theme.islandText, 0.12) : Theme.withAlpha(Theme.islandText, 0.06)

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 10
                        rightMargin: 10
                    }
                    spacing: 10

                    Item {
                        readonly property string icon: row.modelData.appIcon ?? ""
                        readonly property string themed: icon.startsWith("/") ? "file://" + icon : icon.startsWith("file:") ? icon : icon !== "" ? Quickshell.iconPath(icon, true) : ""
                        readonly property string source: row.modelData.image || themed || Quickshell.iconPath("dialog-information", true)
                        implicitWidth: 28
                        implicitHeight: 28

                        IconImage {
                            anchors.fill: parent
                            visible: parent.source !== ""
                            source: parent.source
                        }
                        // No icon in the theme: a bell, not Qt's "missing" pattern.
                        Icon {
                            anchors.centerIn: parent
                            visible: parent.source === ""
                            text: "󰂚"
                            size: 20
                            color: Theme.islandSubtext
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        Text {
                            Layout.fillWidth: true
                            text: `${row.modelData.appName}  ·  ${row.modelData.summary}`
                            color: Theme.islandText
                            font.family: Theme.fontUi
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: row.modelData.body ?? ""
                            color: Theme.islandSubtext
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                    }

                    Icon {
                        text: "󰅖"
                        size: 14
                        color: Theme.islandSubtext

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            onClicked: row.modelData.dismiss()
                        }
                    }
                }

                MouseArea {
                    id: mouse
                    anchors.fill: parent
                    z: -1
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Notifications.activate(row.modelData)
                }
            }
        }
    }
}
