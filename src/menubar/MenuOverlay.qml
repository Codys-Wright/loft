import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.components
import qs.services
import qs.settings

// The open bar menu on one screen: a transparent layer below the bar (so
// its titles stay hoverable — moving across them switches menus) holding
// the cascade of glass MenuPanels, or the About / Quit cards. It takes
// exclusive keyboard focus while open; clicking outside closes it.
PanelWindow {
    id: root

    // MenuBarTitles of this screen's bar: where each title sits.
    required property var titles
    required property string screenName
    property int barHeight: 44

    readonly property bool shown: MenuState.open && MenuState.screen === screenName
    readonly property bool menuMode: MenuState.mode === "menu"

    visible: shown
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "studio:menu"
    WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    margins.top: barHeight
    color: "transparent"

    BackgroundEffect.blurRegion: Theme.blur && shown ? blur : null
    Region {
        id: blur
        item: root.menuMode ? (panels.count > 0 ? panels.itemAt(0) : null) : card
        radius: root.menuMode ? 12 : card.radius

        Region {
            item: root.menuMode && panels.count > 1 ? panels.itemAt(1) : null
            radius: 12
        }
        Region {
            item: root.menuMode && panels.count > 2 ? panels.itemAt(2) : null
            radius: 12
        }
        Region {
            item: root.menuMode && panels.count > 3 ? panels.itemAt(3) : null
            radius: 12
        }
        Region {
            item: root.menuMode && panels.count > 4 ? panels.itemAt(4) : null
            radius: 12
        }
    }

    // Anywhere else closes.
    MouseArea {
        anchors.fill: parent
        onClicked: MenuState.close()
    }

    FocusScope {
        anchors.fill: parent
        focus: root.shown

        Item {
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                MenuState.key(event);
                event.accepted = true;
            }
        }
    }

    Repeater {
        id: panels
        model: root.shown && root.menuMode ? MenuState.depth : 0

        delegate: MenuPanel {
            id: panel
            required property int index
            readonly property var parentPanel: index > 0 ? panels.itemAt(index - 1) : null

            level: index
            items: MenuState.open ? MenuState.itemsAt(index) : []
            highlighted: MenuState.path[index]

            x: {
                if (!parentPanel)
                    return Math.max(8, Math.min(root.titles.titleX(MenuState.current) - 6, root.width - width - 8));
                const right = parentPanel.x + parentPanel.width - 4;
                return right + width <= root.width - 8 ? right : Math.max(8, parentPanel.x - width + 4);
            }
            y: parentPanel ? Math.max(4, Math.min(parentPanel.y + parentPanel.rowY(MenuState.path[index - 1]) - pad, root.height - height - 8)) : 4

            onHovered: item => MenuState.highlight(index, item, true)
            onClicked: item => {
                if (item.submenu)
                    MenuState.highlight(index, item, true);
                else
                    MenuState.trigger(item);
            }
        }
    }

    // ── About / Quit cards ───────────────────────────────────────────────
    readonly property var w: MenuState.target
    readonly property var entry: w && Apps.own[w.app_id] === undefined ? Apps.entry(w.app_id) : null
    readonly property var details: root.w ? [["Application ID", root.w.app_id ?? ""], ["Desktop entry", root.entry?.id ?? "none"], ["Process", String(root.w.pid ?? "?")], ["Command", root.entry?.execString ?? ""], ["Window", root.w.title ?? ""]].filter(r => r[1] !== "") : []

    GlassSurface {
        id: card
        visible: root.shown && !root.menuMode
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.max(20, (root.height - height) / 3)
        width: 340
        height: cardCol.implicitHeight + 40
        radius: 22
        strength: 2

        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            id: cardCol
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: 20
            }
            spacing: 10

            IconImage {
                visible: root.w !== null
                Layout.alignment: Qt.AlignHCenter
                implicitSize: 64
                source: root.w ? Apps.icon(root.w.app_id) : ""
            }
            Icon {
                visible: root.w === null
                Layout.alignment: Qt.AlignHCenter
                text: "󰽰"
                size: 56
                color: Theme.accent
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: {
                    if (MenuState.mode === "confirm")
                        return `Quit ${Apps.name(root.w?.app_id)}?`;
                    return root.w ? Apps.name(root.w.app_id) : "studio-linux";
                }
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 17
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: {
                    if (MenuState.mode === "confirm")
                        return `${MenuState.pendingQuit?.count ?? 0} windows are open. Unsaved work in them may be lost.`;
                    if (!root.w)
                        return "niri + Quickshell, Liquid Glass";
                    return root.entry?.comment || root.entry?.genericName || root.w.title || "";
                }
                visible: text !== ""
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 12
            }

            // About details.
            GridLayout {
                visible: MenuState.mode === "about" && root.w !== null
                Layout.fillWidth: true
                Layout.topMargin: 4
                columns: 2
                columnSpacing: 12
                rowSpacing: 4

                Repeater {
                    model: root.details

                    delegate: Text {
                        required property var modelData
                        required property int index
                        Layout.row: index
                        Layout.column: 0
                        Layout.alignment: Qt.AlignRight | Qt.AlignTop
                        text: modelData[0]
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                    }
                }
                Repeater {
                    model: root.details

                    delegate: Text {
                        required property var modelData
                        required property int index
                        Layout.row: index
                        Layout.column: 1
                        Layout.fillWidth: true
                        text: modelData[1]
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        elide: Text.ElideMiddle
                    }
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 6
                spacing: 10

                SettingsButton {
                    visible: MenuState.mode === "confirm"
                    text: "Cancel"
                    onClicked: MenuState.close()
                }
                SettingsButton {
                    primary: true
                    text: MenuState.mode === "confirm" ? "Quit" : "OK"
                    onClicked: MenuState.mode === "confirm" ? MenuState.confirmQuit() : MenuState.close()
                }
            }
        }
    }
}
