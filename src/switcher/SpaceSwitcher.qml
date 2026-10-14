import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// The space switcher (Mod+Ctrl+S, or click the bar's space pill;
// docs/SPACES.md §6.2): a Liquid Glass HUD listing the spaces in order with
// their Mod+N keys and where each puts its workspaces. Type to filter,
// ↑↓ (or ⌃N/⌃P, Tab) to choose, Enter activates, Esc closes; ⌘1…9 jump
// straight to a space. Activation is loft-niri's (Spaces.focus).
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property bool open: Spaces.switcherOutput === modelData.name

    visible: open || fade.running
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:spaces"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    // Blur only while the HUD is fully there: a Region doesn't follow
    // opacity or scale (GlassSurface.qml).
    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur && root.open && !fade.running ? panel : null
        radius: panel.radius
    }

    property string query: ""
    property int current: 0

    readonly property var rows: {
        const q = query.trim().toLowerCase();
        if (!q)
            return Spaces.spaces;
        return Spaces.spaces.filter(s => s.name.toLowerCase().includes(q) || s.id.toLowerCase().includes(q) || Object.values(s.displays ?? {}).some(w => w !== "keep" && w.toLowerCase().includes(q)));
    }
    readonly property var row: rows[Math.min(current, rows.length - 1)] ?? null

    onRowsChanged: if (current >= rows.length)
        current = Math.max(0, rows.length - 1)

    onOpenChanged: {
        if (open) {
            query = "";
            search.text = "";
            // Start on the active space, like macOS's switchers.
            current = Math.max(0, Spaces.spaces.findIndex(s => s.id === Spaces.activeId));
            search.forceActiveFocus();
            pointerOrigin = null;
        }
    }

    // The pointer the HUD appears under isn't a choice: hover selects only
    // once the pointer has actually moved.
    property var pointerOrigin: null

    function hovered(area, x, y, index) {
        const p = area.mapToItem(null, x, y);
        if (pointerOrigin === null) {
            pointerOrigin = p;
            return;
        }
        if (Math.abs(p.x - pointerOrigin.x) + Math.abs(p.y - pointerOrigin.y) > 3)
            current = index;
    }

    function close() {
        Spaces.switcherOutput = "";
    }

    function activate(space) {
        close();
        if (space)
            Spaces.focus(space.id);
    }

    // "music · music/right" — the workspaces a space switches, main first.
    function summary(s) {
        const d = s.displays ?? {};
        const roles = Object.keys(d).filter(r => d[r] !== "keep" && r !== "*");
        roles.sort((a, b) => (a === "main" ? -1 : b === "main" ? 1 : a.localeCompare(b)));
        const parts = roles.map(r => r === "main" ? d[r] : `${r}: ${d[r]}`);
        return parts.join("  ·  ") || "no displays";
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.close()
    }

    GlassSurface {
        id: panel
        width: Math.min(520, parent.width - 64)
        height: Math.min(header.implicitHeight + list.contentHeight + footer.implicitHeight + 64, parent.height - 160)
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(parent.height * 0.38 - height / 2)
        radius: Theme.panelRadius + 8
        strength: 1.6

        opacity: root.open ? 1 : 0
        scale: root.open ? 1 : 0.96
        Behavior on opacity {
            NumberAnimation {
                id: fade
                duration: 160
                easing.type: Easing.OutCubic
            }
        }
        Behavior on scale {
            NumberAnimation {
                duration: 220
                easing.type: Easing.OutQuint
            }
        }

        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            anchors {
                fill: parent
                margins: 14
            }
            spacing: 10

            RowLayout {
                id: header
                Layout.fillWidth: true
                Layout.leftMargin: 6
                spacing: 10

                Icon {
                    text: "󰕰"
                    size: 20
                    color: Theme.accent
                }

                TextInput {
                    id: search
                    Layout.fillWidth: true
                    color: Theme.text
                    selectionColor: Theme.withAlpha(Theme.accent, 0.5)
                    font.family: Theme.fontUi
                    font.pixelSize: 20
                    clip: true
                    onTextEdited: {
                        root.query = text;
                        root.current = 0;
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: search.text === ""
                        text: "Switch to a space"
                        color: Theme.withAlpha(Theme.subtext, 0.7)
                        font: search.font
                    }

                    Keys.onPressed: event => {
                        const ctrl = event.modifiers & Qt.ControlModifier;
                        const meta = event.modifiers & Qt.MetaModifier;
                        const n = event.key - Qt.Key_1;
                        if (event.key === Qt.Key_Escape)
                            root.close();
                        else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab || (ctrl && event.key === Qt.Key_N))
                            root.current = (root.current + 1) % Math.max(1, root.rows.length);
                        else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || (ctrl && event.key === Qt.Key_P))
                            root.current = (root.current - 1 + root.rows.length) % Math.max(1, root.rows.length);
                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                            root.activate(root.row);
                        else if ((meta || ctrl) && n >= 0 && n <= 8)
                            root.activate(Spaces.find(String(n + 1)));
                        else
                            return;
                        event.accepted = true;
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.glassBorder
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 52

                Text {
                    anchors.centerIn: parent
                    visible: root.rows.length === 0
                    text: Spaces.spaces.length === 0 ? "No spaces" : "No matches"
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                }

                ListView {
                    id: list
                    anchors.fill: parent
                    clip: true
                    model: root.rows
                    currentIndex: root.current
                    highlightMoveDuration: 0
                    boundsBehavior: Flickable.StopAtBounds
                    spacing: 2

                    delegate: Rectangle {
                        id: item
                        required property var modelData
                        required property int index
                        readonly property bool selected: index === root.current
                        readonly property bool isActive: modelData.id === Spaces.activeId
                        readonly property int windows: Spaces.windowCount(modelData.id)

                        width: ListView.view.width
                        height: 54
                        radius: 12
                        color: selected ? Theme.withAlpha(Theme.accent, 0.28) : mouse.containsMouse ? Theme.withAlpha(Theme.text, 0.07) : "transparent"

                        MouseArea {
                            id: mouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPositionChanged: mouse => root.hovered(this, mouse.x, mouse.y, item.index)
                            onClicked: root.activate(item.modelData)
                        }

                        RowLayout {
                            anchors {
                                fill: parent
                                leftMargin: 10
                                rightMargin: 12
                            }
                            spacing: 12

                            IconBadge {
                                icon: item.modelData.icon || "󰕰"
                                badge: Spaces.badgeFor(item.modelData)
                                size: 32
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8

                                    Text {
                                        text: item.modelData.name
                                        color: Theme.text
                                        font.family: Theme.fontUi
                                        font.pixelSize: 14
                                        font.weight: Font.DemiBold
                                        elide: Text.ElideRight
                                        Layout.maximumWidth: 260
                                    }

                                    // The active space: a small accent dot, as macOS marks the current item.
                                    Rectangle {
                                        visible: item.isActive
                                        Layout.preferredWidth: 6
                                        Layout.preferredHeight: 6
                                        radius: 3
                                        color: Theme.accent
                                    }

                                    Item {
                                        Layout.fillWidth: true
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: root.summary(item.modelData) + (item.windows > 0 ? `  —  ${item.windows} window${item.windows === 1 ? "" : "s"}` : "")
                                    color: Theme.subtext
                                    font.family: Theme.fontUi
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                }
                            }

                            // The Mod+N key (positions 1…9).
                            Rectangle {
                                visible: item.modelData.position !== null && item.modelData.position !== undefined
                                Layout.preferredWidth: Math.max(30, key.implicitWidth + 14)
                                Layout.preferredHeight: 22
                                radius: 6
                                color: Theme.withAlpha(Theme.text, item.selected ? 0.16 : 0.08)
                                border.width: 1
                                border.color: Theme.glassBorder

                                Text {
                                    id: key
                                    anchors.centerIn: parent
                                    text: `⌘${item.modelData.position}`
                                    color: Theme.subtext
                                    font.family: Theme.fontUi
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                    font.features: { "tnum": 1 }
                                }
                            }
                        }
                    }
                }
            }

            Text {
                id: footer
                Layout.fillWidth: true
                Layout.leftMargin: 6
                text: "↵ switch   ↑↓ choose   ⌃⌘← → previous / next space"
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }
    }
}
