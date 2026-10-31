import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import qs.components
import qs.services

// One notification in the island: image or app icon, app name, summary and
// body, and its action buttons (up to two, on the right). Click activates it
// (default action) and moves to the next banner. A banner about a file
// (`file`: the Downloaded banner) drags that file out from its icon.
Item {
    id: root

    property var notification: null

    readonly property string imageSource: notification?.image ? notification.image : ""
    // A themed icon only when the icon theme has it (or the generic one):
    // otherwise "" and a bell glyph, never Qt's magenta "missing" pattern.
    readonly property string iconSource: {
        const icon = notification?.appIcon ?? "";
        if (icon.startsWith("/") || icon.startsWith("file:"))
            return icon.startsWith("/") ? "file://" + icon : icon;
        return (icon !== "" ? Apps.themed(icon) : "") || Apps.themed("dialog-information");
    }
    readonly property string file: notification?.file ?? ""
    // From the iPhone (tetherd, or Loft's own message banners): tagged, and a
    // handset instead of the bell when the phone app has no icon here.
    readonly property bool phone: Notifications.isPhone(notification)
    readonly property bool themedIcon: {
        const icon = notification?.appIcon ?? "";
        return icon !== "" && (icon.startsWith("/") || icon.startsWith("file:") || Apps.themed(icon) !== "");
    }
    readonly property string glyph: notification?.glyph ?? (phone && !themedIcon && imageSource === "" ? "󰄜" : "")
    // Named actions; an internal banner may list its default action too.
    readonly property var buttons: {
        const acts = notification?.actions ?? [];
        const list = [];
        for (let i = 0; i < acts.length; i++) {
            const a = acts[i];
            if (a && a.text && (a.identifier !== "default" || file !== ""))
                list.push(a);
        }
        return list.slice(0, 2);
    }

    function uri(path) {
        return "file://" + path.split("/").map(encodeURIComponent).join("/");
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: if (root.notification)
            Notifications.activate(root.notification)
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 4
        spacing: 12

        Rectangle {
            id: iconBox
            Layout.preferredWidth: 52
            Layout.preferredHeight: 52
            radius: 14
            clip: true
            color: Theme.withAlpha(Theme.islandText, 0.1)

            Image {
                anchors.fill: parent
                visible: root.imageSource !== ""
                source: root.imageSource
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }

            IconImage {
                anchors.centerIn: parent
                visible: root.imageSource === "" && root.glyph === "" && root.iconSource !== ""
                implicitSize: 36
                source: root.iconSource
                asynchronous: true
            }

            // Loft's own banners can bring a glyph (no icon theme needed);
            // a missing icon falls back to a bell.
            Icon {
                anchors.centerIn: parent
                visible: root.imageSource === "" && (root.glyph !== "" || root.iconSource === "")
                text: root.glyph !== "" ? root.glyph : "󰂚"
                size: 26
                color: root.glyph !== "" ? (root.notification?.glyphColor ?? Theme.accent) : Theme.islandSubtext
            }

            // Drag the file out (text/uri-list), like the dock's stacks.
            Item {
                id: proxy
                width: 52
                height: 52
                Drag.active: dragArea.drag.active
                Drag.dragType: Drag.Automatic
                Drag.supportedActions: Qt.CopyAction | Qt.MoveAction | Qt.LinkAction
                Drag.proposedAction: Qt.CopyAction
                Drag.mimeData: ({
                        "text/uri-list": root.uri(root.file) + "\r\n",
                        "text/plain": root.file
                    })
                Drag.keys: ["text/uri-list"]
                Drag.imageSource: root.iconSource
                Drag.imageSourceSize: Qt.size(48, 48)
                Drag.hotSpot.x: 24
                Drag.hotSpot.y: 24
            }

            MouseArea {
                id: dragArea
                anchors.fill: parent
                enabled: root.file !== ""
                drag.target: proxy
                cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                onReleased: {
                    proxy.x = 0;
                    proxy.y = 0;
                }
                onClicked: if (root.notification)
                    Notifications.activate(root.notification)
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1

            Text {
                Layout.fillWidth: true
                text: Notifications.appLabel(root.notification)
                color: Theme.islandSubtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                text: root.notification?.summary ?? ""
                color: Theme.islandText
                font.family: Theme.fontUi
                font.pixelSize: 14
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: root.notification?.body ?? ""
                color: Theme.islandText
                opacity: 0.85
                font.family: Theme.fontUi
                font.pixelSize: 12
                // A file's name keeps its end (the extension, the size).
                elide: root.file !== "" ? Text.ElideMiddle : Text.ElideRight
                maximumLineCount: 1
            }
        }

        ColumnLayout {
            visible: root.buttons.length > 0
            Layout.alignment: Qt.AlignVCenter
            Layout.fillWidth: false
            Layout.preferredWidth: 104
            Layout.maximumWidth: 104
            spacing: 6

            Repeater {
                model: root.buttons

                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    Layout.fillWidth: true
                    Layout.minimumWidth: 74
                    implicitWidth: actLabel.implicitWidth + 22
                    implicitHeight: 26
                    radius: 13
                    color: actMouse.containsMouse ? Theme.withAlpha(Theme.islandText, 0.26) : Theme.withAlpha(Theme.islandText, index === 0 ? 0.18 : 0.1)

                    Text {
                        id: actLabel
                        anchors.centerIn: parent
                        text: modelData.text
                        color: Theme.islandText
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                    }

                    MouseArea {
                        id: actMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            modelData.invoke();
                            Notifications.next(root.notification);
                        }
                    }
                }
            }
        }
    }
}
