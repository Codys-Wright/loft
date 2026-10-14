import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Widgets
import qs.components
import qs.controls
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
    property int barHeight: 30

    readonly property bool shown: MenuState.open && MenuState.screen === screenName
    readonly property bool menuMode: MenuState.mode === "menu"
    readonly property bool extraMode: MenuState.mode === "extra"
    readonly property bool cardMode: MenuState.mode === "about" || MenuState.mode === "confirm"

    visible: shown
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:menu"
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
        item: root.menuMode ? (panels.count > 0 ? panels.itemAt(0) : null) : root.extraMode ? extraPanel : card
        radius: root.cardMode ? card.radius : root.extraMode ? extraPanel.radius : 12

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
            id: keys
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                // A panel's text field keeps Enter/Space (and letters).
                if (Nav.typing && root.extraMode && ![Qt.Key_Up, Qt.Key_Down, Qt.Key_Escape].includes(event.key))
                    return;
                MenuState.key(event);
                event.accepted = true;
            }
            Keys.onReleased: event => MenuState.keyReleased(event)

            // ── A status item's panel (Wi-Fi, Sound, …) ─────────────────
            GlassSurface {
                id: extraPanel
                visible: root.shown && root.extraMode
                width: MenuState.extra === "wifi" || MenuState.extra === "nowPlaying" ? 320 : MenuState.extra === "clock" ? 290 : 300
                height: host.implicitHeight + 12
                radius: Theme.panelRadius - 6
                strength: 1.9
                x: {
                    void root.titles.stamp;
                    const a = MenuState.anchor;
                    const ax = a ? a.mapToItem(null, 0, 0).x : root.width;
                    return Math.max(8, Math.min(ax - 6, root.width - width - 8));
                }
                y: 2
                opacity: visible ? 1 : 0
                Behavior on opacity {
                    NumberAnimation {
                        duration: 110
                    }
                }

                // Swallow clicks on the panel.
                MouseArea {
                    anchors.fill: parent
                }

                PanelHost {
                    id: host
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        margins: 6
                    }
                    panel: root.extraMode ? MenuState.extra : ""
                    details: MenuState.details
                    shown: extraPanel.visible
                    screenName: root.screenName
                    window: root
                    onDismiss: MenuState.close()
                    onOpenSettings: section => {
                        MenuState.close();
                        Panels.settingsSection = section;
                        Panels.settingsOpen = true;
                    }
                    onOpenControl: id => {
                        if (Controls.control(id)?.kind === "panel")
                            MenuState.openExtra(root.screenName, id, MenuState.anchorOf(root.screenName, "overflow"), false);
                        else {
                            MenuState.close();
                            ControlActions.trigger(id);
                        }
                    }
                }
            }
        }
    }

    Binding {
        target: Nav
        property: "root"
        value: host
        when: root.shown && root.extraMode
    }

    // A text field let go of the keyboard: back to menu keys.
    Connections {
        target: Nav
        function onTypingChanged() {
            if (!Nav.typing && root.shown)
                keys.forceActiveFocus();
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

            // A context menu (the dock) opens away from its screen edge.
            readonly property var ctx: MenuState.context
            x: {
                void root.titles.stamp; // re-evaluate after the titles move
                if (!parentPanel && ctx) {
                    const want = ctx.edge === "left" ? ctx.x + 8 : ctx.edge === "right" ? ctx.x - width - 8 : ctx.x - width / 2;
                    return Math.max(8, Math.min(want, root.width - width - 8));
                }
                if (!parentPanel)
                    return Math.max(8, Math.min(root.titles.titleX(MenuState.current) - 6, root.width - width - 8));
                const right = parentPanel.x + parentPanel.width - 4;
                return right + width <= root.width - 8 ? right : Math.max(8, parentPanel.x - width + 4);
            }
            y: parentPanel ? Math.max(2, Math.min(parentPanel.y + parentPanel.rowY(MenuState.path[index - 1]) - pad, root.height - height - 8)) : ctx ? Math.max(2, Math.min(ctx.edge === "bottom" ? ctx.y - root.barHeight - height - 8 : ctx.y - root.barHeight - height / 2, root.height - height - 8)) : 2

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
        visible: root.shown && root.cardMode
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
                text: MenuState.pendingAsk?.icon ?? "󰽰"
                size: 56
                color: Theme.accent
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: {
                    if (MenuState.pendingAsk)
                        return MenuState.pendingAsk.title;
                    if (MenuState.mode === "confirm")
                        return `Quit ${Apps.name(root.w?.app_id)}?`;
                    return root.w ? Apps.name(root.w.app_id) : "Loft";
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
                    if (MenuState.pendingAsk)
                        return MenuState.pendingAsk.text ?? "";
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
                    text: MenuState.pendingAsk ? (MenuState.pendingAsk.button ?? "OK") : MenuState.mode === "confirm" ? "Quit" : "OK"
                    onClicked: MenuState.mode === "confirm" ? MenuState.confirmQuit() : MenuState.close()
                }
            }
        }
    }
}
