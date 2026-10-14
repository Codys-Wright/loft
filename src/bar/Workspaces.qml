import QtQuick
import qs.components
import qs.services

// The space indicator for one output (docs/SPACES.md §6.1):
//
//   [ 󰝚 Music ]  ● ● ◉ ● ○   │  ·  ·
//     ▲ active space ▲ one dot per space    ▲ workspaces no space owns
//
// The pill shows the active space (icon and name on the main display, the
// icon elsewhere; "Spaces" before one is active); clicking it opens the
// space switcher (Mod+Ctrl+S).
// A space's dot is its workspace on *this* display: filled when it has
// windows, a ghost when empty, faint when the space doesn't use this
// display. The sliding "pacman" sits on what this display shows. Hover a
// dot to see its name in the pill; click it to activate the space.
// Without spaces (feature off, none defined) it is today's per-workspace
// dots. Design from javiiervm/dotfiles; data from niri.
Item {
    id: root

    required property string output
    property var window: null

    // Bar colors for this output (light/dark from the wallpaper, Theme).
    readonly property color fg: Theme.barTextFor(output)
    readonly property color sub: Theme.barSubtextFor(output)

    readonly property bool spacesOn: Spaces.enabled && Spaces.loaded && Spaces.spaces.length > 0
    readonly property bool isMain: Displays.mainScreen?.name === output
    readonly property var workspaces: Niri.workspacesOn(output)
    readonly property var activeWs: workspaces.find(w => w.is_active) ?? null

    // The cells, in order: { kind: "space" | "ws" | "divider", space, ws }.
    readonly property var cells: {
        const out = [];
        if (spacesOn) {
            for (const s of Spaces.spaces)
                out.push({ kind: "space", space: s, ws: null });
            const loose = Spaces.unownedOn(output);
            if (loose.length > 0) {
                out.push({ kind: "divider" });
                for (const w of loose)
                    out.push({ kind: "ws", ws: w });
            }
        } else {
            for (const w of workspaces)
                out.push({ kind: "ws", ws: w });
        }
        return out;
    }

    readonly property int cell: 22
    readonly property int gap: 6
    readonly property int dividerWidth: 9

    function cellWidth(c) {
        return c.kind === "divider" ? dividerWidth : cell;
    }

    // Where the pacman goes: the cell of the workspace this display shows.
    readonly property int activeCell: {
        const ws = activeWs;
        if (!ws)
            return -1;
        const owner = spacesOn ? Spaces.ownerOf(ws.name) : "";
        return cells.findIndex(c => owner ? c.kind === "space" && c.space.id === owner : c.kind === "ws" && c.ws.id === ws.id);
    }
    readonly property real activeX: {
        let x = 0;
        for (let i = 0; i < activeCell; i++)
            x += cellWidth(cells[i]) + gap;
        return x;
    }

    // Hovering a dot previews its space in the pill.
    property string hoverId: ""
    readonly property var shown: Spaces.find(hoverId) ?? Spaces.active

    implicitWidth: (spacesOn ? pill.width + 10 : 0) + dots.implicitWidth
    implicitHeight: cell

    // ── The active space ────────────────────────────────────────────────
    Rectangle {
        id: pill
        visible: root.spacesOn
        anchors.verticalCenter: parent.verticalCenter
        height: root.cell
        width: label.implicitWidth + 18
        radius: height / 2
        color: pillMouse.pressed ? Theme.withAlpha(root.fg, 0.22) : pillMouse.containsMouse || Spaces.switcherOutput === root.output ? Theme.withAlpha(root.fg, 0.14) : "transparent"
        border.width: 1
        border.color: Theme.withAlpha(root.fg, root.hoverId ? 0.35 : 0.22)

        Behavior on width {
            NumberAnimation {
                duration: 220
                easing.type: Easing.OutQuint
            }
        }
        Behavior on color {
            ColorAnimation {
                duration: 160
            }
        }

        Row {
            id: label
            anchors.centerIn: parent
            spacing: 6

            Icon {
                anchors.verticalCenter: parent.verticalCenter
                text: root.shown?.icon || "󰕰"
                size: 14
                color: root.fg
            }
            Text {
                visible: root.isMain || root.hoverId !== ""
                anchors.verticalCenter: parent.verticalCenter
                // No space yet (an unowned workspace since login): "Spaces".
                text: root.shown?.name ?? "Spaces"
                color: root.fg
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.weight: Font.DemiBold
            }
        }

        MouseArea {
            id: pillMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Spaces.toggleSwitcher(root.output)
        }
    }

    // ── Dots ────────────────────────────────────────────────────────────
    Item {
        id: dots
        anchors {
            left: root.spacesOn ? pill.right : parent.left
            leftMargin: root.spacesOn ? 10 : 0
            verticalCenter: parent.verticalCenter
        }
        implicitWidth: row.implicitWidth
        width: implicitWidth
        height: root.cell

        Row {
            id: row
            spacing: root.gap

            Repeater {
                model: root.cells

                delegate: Item {
                    id: dot

                    required property var modelData
                    required property int index

                    readonly property bool isSpace: modelData.kind === "space"
                    readonly property bool isDivider: modelData.kind === "divider"
                    // This display's workspaces of the space (or the one workspace).
                    readonly property var mine: isSpace ? Spaces.workspacesOf(modelData.space.id, root.output) : modelData.ws ? [modelData.ws] : []
                    readonly property bool occupied: mine.some(w => Niri.windowsOn(w.id).length > 0)
                    readonly property bool urgent: mine.some(w => w.is_urgent)
                    readonly property bool here: mine.length > 0

                    width: root.cellWidth(modelData)
                    height: root.cell

                    // Fade the glyph the pacman is about to "eat"; a space
                    // that doesn't use this display is faint.
                    opacity: {
                        if (isDivider)
                            return 1;
                        const d = Math.abs(pacman.x + pacman.width / 2 - (x + width / 2));
                        const eaten = d < 20 ? Math.pow(d / 20, 0.55) : 1;
                        return eaten * (here || !isSpace ? 1 : 0.4);
                    }

                    Rectangle {
                        visible: dot.isDivider
                        anchors.centerIn: parent
                        width: 1
                        height: 12
                        color: Theme.withAlpha(root.fg, 0.35)
                    }

                    Rectangle {
                        visible: !dot.isDivider
                        anchors.fill: parent
                        radius: width / 2
                        color: mouse.containsMouse ? Theme.withAlpha(root.fg, 0.14) : "transparent"

                        Behavior on color {
                            ColorAnimation {
                                duration: 200
                            }
                        }
                    }

                    Icon {
                        visible: !dot.isDivider
                        anchors.centerIn: parent
                        text: dot.urgent ? "󰀦" : dot.occupied ? "󰧞" : "󰊠"
                        color: dot.urgent ? Theme.urgent : root.sub
                        size: 15
                    }

                    MouseArea {
                        id: mouse
                        visible: !dot.isDivider
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onContainsMouseChanged: {
                            if (!dot.isSpace)
                                return;
                            if (containsMouse)
                                root.hoverId = dot.modelData.space.id;
                            else if (root.hoverId === dot.modelData.space.id)
                                root.hoverId = "";
                        }
                        onClicked: {
                            if (dot.isSpace)
                                Spaces.focus(dot.modelData.space.id);
                            else
                                Niri.focusWorkspace(dot.modelData.ws.id);
                        }
                    }
                }
            }
        }

        Rectangle {
            id: pacman
            visible: root.activeCell >= 0
            width: root.cell + 8
            height: root.cell
            radius: root.cell / 2
            x: root.activeX - 4
            color: root.fg

            Behavior on x {
                NumberAnimation {
                    duration: 250
                    easing.type: Easing.OutQuint
                }
            }

            Icon {
                anchors.centerIn: parent
                text: "󰮯"
                color: Theme.barOnTextFor(root.output)
                size: 15
            }
        }
    }
}
