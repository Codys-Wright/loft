import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.menubar
import qs.services

// The open desktop menu on one screen: a transparent overlay over the whole
// display (bar included) holding the cascade of glass MenuPanels — the same
// panels as the bar's menus. It takes the keyboard while open; a click
// outside closes it, a right-click elsewhere on the desktop moves it there.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property bool shown: DesktopMenu.open && DesktopMenu.screen === modelData.name

    visible: shown
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:desktopmenu"
    WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    BackgroundEffect.blurRegion: Theme.blur && shown ? blur : null
    Region {
        id: blur
        item: panels.count > 0 && panels.itemAt(0)?.visible ? panels.itemAt(0) : null
        radius: 12

        Region {
            item: panels.count > 1 && panels.itemAt(1)?.visible ? panels.itemAt(1) : null
            radius: 12
        }
        Region {
            item: panels.count > 2 && panels.itemAt(2)?.visible ? panels.itemAt(2) : null
            radius: 12
        }
        Region {
            item: panels.count > 3 && panels.itemAt(3)?.visible ? panels.itemAt(3) : null
            radius: 12
        }
    }

    // Anywhere else closes; a right-click reopens the menu there (macOS).
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPressed: mouse => {
            DesktopMenu.close();
            if (mouse.button === Qt.RightButton)
                DesktopMenu.openAt(root.modelData.name, mouse.x, mouse.y);
        }
    }

    FocusScope {
        anchors.fill: parent
        focus: root.shown

        Item {
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                DesktopMenu.key(event);
                event.accepted = true;
            }
        }
    }

    // Four fixed panels (top level + three submenu levels), so opening a
    // submenu never rebuilds the ones before it.
    Repeater {
        id: panels
        model: root.shown ? 4 : 0

        delegate: MenuPanel {
            id: panel
            required property int index
            readonly property var parentPanel: index > 0 ? panels.itemAt(index - 1) : null

            visible: index < DesktopMenu.depth
            level: index
            items: index === 0 ? DesktopMenu.items0 : index === 1 ? DesktopMenu.items1 : index === 2 ? DesktopMenu.items2 : DesktopMenu.items3
            highlighted: DesktopMenu.path[index]
            maxHeight: root.height - 16

            // The top level opens at the pointer (flipped left / up when it
            // wouldn't fit); submenus to the right of their row, or left.
            x: {
                if (!parentPanel)
                    return DesktopMenu.atX + width + 8 <= root.width ? Math.max(8, DesktopMenu.atX) : Math.max(8, DesktopMenu.atX - width);
                const right = parentPanel.x + parentPanel.width - 4;
                return right + width <= root.width - 8 ? right : Math.max(8, parentPanel.x - width + 4);
            }
            y: {
                if (!parentPanel)
                    return Math.max(8, Math.min(DesktopMenu.atY, root.height - height - 8));
                return Math.max(8, Math.min(parentPanel.y + parentPanel.rowY(DesktopMenu.path[index - 1]) - pad, root.height - height - 8));
            }

            onHovered: item => DesktopMenu.highlight(index, item, true)
            onClicked: item => {
                if (item.submenu)
                    DesktopMenu.highlight(index, item, true);
                else
                    DesktopMenu.trigger(item);
            }
        }
    }
}
