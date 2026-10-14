import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.components
import qs.services

// One notification in the island: image or app icon, app name, summary and
// body. Click activates it (default action) and moves to the next banner.
Item {
    id: root

    property var notification: null

    readonly property string imageSource: notification?.image ? notification.image : ""
    readonly property string iconSource: {
        const icon = notification?.appIcon ?? "";
        if (icon.startsWith("/") || icon.startsWith("file:"))
            return icon.startsWith("/") ? "file://" + icon : icon;
        return Quickshell.iconPath(icon || "dialog-information", "dialog-information");
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 4
        spacing: 12

        Rectangle {
            Layout.preferredWidth: 52
            Layout.preferredHeight: 52
            radius: 14
            clip: true
            color: Theme.withAlpha(Theme.text, 0.1)

            Image {
                anchors.fill: parent
                visible: root.imageSource !== ""
                source: root.imageSource
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }

            IconImage {
                anchors.centerIn: parent
                visible: root.imageSource === ""
                implicitSize: 36
                source: root.iconSource
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1

            Text {
                Layout.fillWidth: true
                text: root.notification?.appName ?? ""
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                text: root.notification?.summary ?? ""
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 14
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: root.notification?.body ?? ""
                color: Theme.text
                opacity: 0.85
                font.family: Theme.fontUi
                font.pixelSize: 12
                elide: Text.ElideRight
                maximumLineCount: 1
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.notification)
            Notifications.activate(root.notification)
    }
}
