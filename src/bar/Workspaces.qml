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
// Without spaces (feature off, none defined) it is one cell per workspace:
//
//   [ 󰝚 music ]  󰋜 󰅩 (󰝚) 󰊗   ·  ·
//     ▲ this display's workspace   ▲ unnamed workspaces keep their dots
//
// A named workspace shows its icon (WorkspaceIcons: Settings → Menu Bar →
// Workspace Icons, the Nix default, or a guess from the name), dim when
// empty, with an urgent badge; the pacman wears the active one's icon, and
// the pill names it on every display, as wide as this display's longest
// name so the cells never move (hover a cell to see its name; click the
// pill for the overview). Icons off: plain dots, no pill. Design from
// javiiervm/dotfiles; data from niri.
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

    // Workspace icons (spaces off): a named workspace's glyph, "" = a dot.
    readonly property bool iconsOn: !spacesOn && WorkspaceIcons.enabled
    function wsIcon(w) {
        return iconsOn && w ? WorkspaceIcons.iconFor(w.name) : "";
    }
    // The pill only appears once this display has a named workspace.
    readonly property bool wsPill: iconsOn && workspaces.some(w => !!w.name)
    readonly property bool pillOn: spacesOn || wsPill

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

    // Hovering a dot previews its space (or workspace) in the pill.
    property string hoverId: ""
    readonly property var shown: Spaces.find(hoverId) ?? Spaces.active
    property int hoverWsId: -1
    readonly property var shownWs: workspaces.find(w => w.id === hoverWsId) ?? activeWs
    readonly property bool hovering: hoverId !== "" || hoverWsId >= 0

    // What the pill shows: the space, or this display's workspace (its
    // name, or its number when it has none).
    readonly property string pillIcon: spacesOn ? (shown?.icon || "󰕰") : wsIcon(shownWs)
    readonly property string pillText: spacesOn ? (shown?.name ?? "Spaces") : shownWs ? (shownWs.name || `${shownWs.idx}`) : ""

    // The widest workspace label on this display.
    readonly property real wsLabelWidth: wsPill ? Math.max(...workspaces.map(w => labelMetrics.advanceWidth(w.name || `${w.idx}`)), 0) : 0
    FontMetrics {
        id: labelMetrics
        font.family: Theme.fontUi
        font.pixelSize: 13
        font.weight: Font.DemiBold
    }

    implicitWidth: (pillOn ? pill.width + 10 : 0) + dots.implicitWidth
    implicitHeight: cell

    // ── The active space ────────────────────────────────────────────────
    Rectangle {
        id: pill
        visible: root.pillOn
        anchors.verticalCenter: parent.verticalCenter
        height: root.cell
        // Workspaces: fixed for this display's names (no shifting cells
        // while switching or hovering); spaces: the label's width.
        width: root.spacesOn ? label.implicitWidth + 18 : 18 + 16 + 6 + root.wsLabelWidth
        radius: height / 2
        color: pillMouse.pressed ? Theme.withAlpha(root.fg, 0.22) : pillMouse.containsMouse || (root.spacesOn && Spaces.switcherOutput === root.output) ? Theme.withAlpha(root.fg, 0.14) : "transparent"
        border.width: 1
        border.color: Theme.withAlpha(root.fg, root.hovering ? 0.35 : 0.22)

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
                visible: text !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: root.pillIcon
                size: 14
                color: root.fg
            }
            Text {
                // Workspaces: always named; spaces: the main display, or
                // while hovering.
                visible: !root.spacesOn || root.isMain || root.hovering
                anchors.verticalCenter: parent.verticalCenter
                // No space yet (an unowned workspace since login): "Spaces".
                text: root.pillText
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
            onClicked: root.spacesOn ? Spaces.toggleSwitcher(root.output) : Niri.toggleOverview()
        }
    }

    // ── Dots ────────────────────────────────────────────────────────────
    Item {
        id: dots
        anchors {
            left: root.pillOn ? pill.right : parent.left
            leftMargin: root.pillOn ? 10 : 0
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
                    // A named workspace's icon ("" = the dot glyphs).
                    readonly property string glyph: !isSpace && modelData.ws ? root.wsIcon(modelData.ws) : ""

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
                        text: dot.glyph || (dot.urgent ? "󰀦" : dot.occupied ? "󰧞" : "󰊠")
                        color: dot.urgent ? Theme.urgent : root.sub
                        // An icon is dim while its workspace is empty.
                        opacity: dot.glyph && !dot.occupied && !dot.urgent ? 0.45 : 1
                        size: dot.glyph ? 14 : 15

                        Behavior on opacity {
                            NumberAnimation {
                                duration: 200
                            }
                        }
                    }

                    // Urgent badge on an icon.
                    Rectangle {
                        visible: dot.glyph !== "" && dot.urgent
                        anchors {
                            top: parent.top
                            right: parent.right
                            topMargin: 2
                            rightMargin: 2
                        }
                        width: 6
                        height: 6
                        radius: 3
                        color: Theme.urgent
                    }

                    MouseArea {
                        id: mouse
                        visible: !dot.isDivider
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onContainsMouseChanged: {
                            if (!dot.isSpace) {
                                if (!root.wsPill || !dot.modelData.ws)
                                    return;
                                if (containsMouse)
                                    root.hoverWsId = dot.modelData.ws.id;
                                else if (root.hoverWsId === dot.modelData.ws.id)
                                    root.hoverWsId = -1;
                                return;
                            }
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
                // The active workspace's icon, or the pacman.
                text: root.wsIcon(root.activeWs) || "󰮯"
                color: Theme.barOnTextFor(root.output)
                size: 15
            }
        }
    }
}
