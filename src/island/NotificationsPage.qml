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
                color: Theme.text
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
                color: mouse.containsMouse ? Theme.withAlpha(Theme.text, 0.12) : Theme.withAlpha(Theme.text, 0.06)

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 10
                        rightMargin: 10
                    }
                    spacing: 10

                    IconImage {
                        implicitSize: 28
                        source: row.modelData.image || Quickshell.iconPath(row.modelData.appIcon || "dialog-information", "dialog-information")
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0

                        Text {
                            Layout.fillWidth: true
                            text: `${row.modelData.appName}  ·  ${row.modelData.summary}`
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }

                        Text {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: row.modelData.body ?? ""
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }
                    }

                    Icon {
                        text: "󰅖"
                        size: 14
                        color: Theme.subtext

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
