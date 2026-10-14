import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import Quickshell.Widgets

// StatusNotifier tray: left click activates, right click opens the item's menu.
Row {
    id: root

    // The window the menus anchor to.
    required property var window

    spacing: 10

    Repeater {
        model: SystemTray.items

        delegate: Item {
            id: item

            required property SystemTrayItem modelData

            width: 18
            height: 24

            IconImage {
                anchors.centerIn: parent
                implicitSize: 16
                source: item.modelData.icon
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => {
                    if (mouse.button === Qt.RightButton || item.modelData.onlyMenu) {
                        if (item.modelData.hasMenu) {
                            const p = item.mapToItem(null, 0, item.height + 6);
                            item.modelData.display(root.window, p.x, p.y);
                        }
                    } else {
                        item.modelData.activate();
                    }
                }
            }
        }
    }
}
