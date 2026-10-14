import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import qs.components
import qs.services

// StatusNotifier tray icons, drawn as monochrome templates in the bar's
// text color (macOS menu bar icons) unless set to "show in color" in
// Settings → Menu Bar. Left click activates, right click opens the menu.
Row {
    id: root

    // The window the menus anchor to.
    required property var window
    // The items to show (the pinned ones; tucked ones live behind »).
    property var items: SystemTray.items.values
    property color fg: Controls.barText

    spacing: 8

    Repeater {
        model: root.items

        delegate: Item {
            id: item

            required property SystemTrayItem modelData

            width: 20
            height: 24

            TemplateIcon {
                anchors.centerIn: parent
                size: 16
                source: item.modelData.icon
                color: root.fg
                template: !Controls.trayColor.includes(item.modelData.id)
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
