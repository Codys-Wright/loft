import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// Launchpad (macOS): every installed app in a grid over the blurred
// desktop, A–Z, a dot under the running ones. Type to filter (name,
// generic name, keywords, id); arrows move, Enter or a click launches,
// Esc or a click on the background closes. Opened from the dock's second
// icon, ⌘⇧A or the Launchpad key (services/Launchpad.qml).
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property bool open: Launchpad.output === modelData.name

    visible: open || fade.running
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:launchpad"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    // The whole screen blurs, as macOS's Launchpad does; only while it is
    // fully there (a Region doesn't follow opacity).
    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur && root.open && !fade.running ? backdrop : null
    }

    property string query: ""
    property int current: 0

    // Installed apps shown in menus, one per id, A–Z. Plain copies: a
    // rescan replaces DesktopEntry objects, and a delegate still holding
    // one crashed the shell (QQmlDelegateModel, required modelData).
    readonly property var apps: {
        const seen = {};
        const out = [];
        for (const e of Apps.entries) {
            if (!e || !e.id || e.noDisplay || seen[e.id])
                continue;
            seen[e.id] = true;
            out.push({ id: e.id, name: e.name || Apps.prettify(e.id), genericName: e.genericName ?? "", keywords: Array.from(e.keywords ?? []) });
        }
        out.sort((a, b) => a.name.localeCompare(b.name));
        return out;
    }
    readonly property var shown: {
        const q = query.trim().toLowerCase();
        if (!q)
            return apps;
        const hit = s => (s ?? "").toLowerCase().includes(q);
        // Names that start with the query first.
        const m = apps.filter(e => hit(e.name) || hit(e.genericName) || hit(e.id) || (e.keywords ?? []).some(hit));
        return m.filter(e => e.name.toLowerCase().startsWith(q)).concat(m.filter(e => !e.name.toLowerCase().startsWith(q)));
    }
    onShownChanged: current = 0

    onOpenChanged: if (open) {
        query = "";
        search.text = "";
        current = 0;
        grid.positionViewAtBeginning();
        search.forceActiveFocus();
        pointerOrigin = null;
    }

    // The app under the pointer when the grid appears isn't a choice: hover
    // selects only once the pointer has actually moved (SpaceSwitcher).
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

    function isRunning(app) {
        return Niri.windows.some(w => w.app_id && DockData.sameApp(app.id, w.app_id));
    }

    function launch(app) {
        Launchpad.close();
        if (app)
            Apps.launch(app.id);
    }

    function move(delta) {
        if (shown.length === 0)
            return;
        current = Math.max(0, Math.min(shown.length - 1, current + delta));
        grid.positionViewAtIndex(current, GridView.Contain);
    }

    Item {
        id: backdrop
        anchors.fill: parent

        opacity: root.open ? 1 : 0
        Behavior on opacity {
            NumberAnimation {
                id: fade
                duration: 180
                easing.type: Easing.OutCubic
            }
        }

        Rectangle {
            anchors.fill: parent
            color: Theme.withAlpha(Theme.bg, Theme.blur ? 0.35 : 0.85)
        }

        // A click on the background closes.
        MouseArea {
            anchors.fill: parent
            onClicked: Launchpad.close()
        }

        ColumnLayout {
            anchors {
                fill: parent
                topMargin: Math.round(parent.height * 0.06)
                bottomMargin: Math.round(parent.height * 0.08)
            }
            spacing: 36

            scale: root.open ? 1 : 1.04
            Behavior on scale {
                NumberAnimation {
                    duration: 240
                    easing.type: Easing.OutQuint
                }
            }

            // Search field.
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 280
                Layout.preferredHeight: 34
                radius: 17
                color: Theme.withAlpha(Theme.text, 0.12)
                border.width: 1
                border.color: Theme.glassBorder

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 12
                        rightMargin: 12
                    }
                    spacing: 8

                    Icon {
                        text: "󰍉"
                        size: 15
                        color: Theme.subtext
                    }

                    TextInput {
                        id: search
                        Layout.fillWidth: true
                        color: Theme.text
                        selectionColor: Theme.withAlpha(Theme.accent, 0.5)
                        font.family: Theme.fontUi
                        font.pixelSize: 14
                        clip: true
                        onTextEdited: root.query = text

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: search.text === ""
                            text: "Search"
                            color: Theme.withAlpha(Theme.subtext, 0.8)
                            font: search.font
                        }

                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Escape) {
                                if (search.text !== "") {
                                    search.text = "";
                                    root.query = "";
                                } else
                                    Launchpad.close();
                            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab)
                                root.move(1);
                            else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab)
                                root.move(-1);
                            else if (event.key === Qt.Key_Down)
                                root.move(grid.columns);
                            else if (event.key === Qt.Key_Up)
                                root.move(-grid.columns);
                            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                                root.launch(root.shown[root.current]);
                            else
                                return;
                            event.accepted = true;
                        }
                    }
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                Text {
                    anchors.centerIn: parent
                    visible: root.shown.length === 0
                    text: root.apps.length === 0 ? "No apps" : "No Results"
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 18
                }

                GridView {
                    id: grid
                    readonly property int cell: 150
                    readonly property int columns: Math.max(1, Math.min(8, Math.floor((parent.width - 160) / cell)))
                    width: columns * cell
                    height: parent.height
                    anchors.horizontalCenter: parent.horizontalCenter
                    cellWidth: cell
                    cellHeight: cell
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: root.shown

                    delegate: Item {
                        id: tile
                        required property var modelData
                        required property int index
                        readonly property bool selected: index === root.current
                        width: grid.cellWidth
                        height: grid.cellHeight

                        Rectangle {
                            anchors.centerIn: parent
                            width: grid.cell - 16
                            height: grid.cell - 8
                            radius: 18
                            color: tile.selected ? Theme.withAlpha(Theme.text, 0.14) : "transparent"
                        }

                        ColumnLayout {
                            anchors.centerIn: parent
                            spacing: 8

                            AppIcon {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredWidth: 80
                                Layout.preferredHeight: 80
                                appId: tile.modelData.id
                                scale: tap.pressed ? 0.92 : 1
                            }

                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.maximumWidth: grid.cell - 20
                                text: tile.modelData.name
                                color: Theme.text
                                font.family: Theme.fontUi
                                font.pixelSize: 13
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                            }

                            // Running: a dot, as under the dock's icons.
                            Rectangle {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredWidth: 4
                                Layout.preferredHeight: 4
                                radius: 2
                                color: Theme.text
                                opacity: root.isRunning(tile.modelData) ? 0.85 : 0
                            }
                        }

                        MouseArea {
                            id: tap
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPositionChanged: m => root.hovered(tap, m.x, m.y, tile.index)
                            onClicked: root.launch(tile.modelData)
                        }
                    }
                }
            }
        }
    }
}
