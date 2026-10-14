import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// The Quick panel on one screen (QuickPanel.qml): a transparent overlay that
// takes the keyboard and holds a glass palette at the pointer (or centered):
// a search field, your favorite tools as a grid, then the latest clipboard
// entries and your snippets. Typing filters everything (and finds any other
// action of the catalog); arrows / Tab move, Enter runs, Esc closes, ⌃,
// opens Settings → Quick Panel. A click outside closes it.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property bool shown: QuickPanel.open && (QuickPanel.screen || modelData.name) === modelData.name
    // Where the pointer is, once the overlay has seen it.
    readonly property bool placed: !atPointer || QuickPanel.pointerX >= 0 || placeTimeout.fired
    readonly property bool atPointer: QuickPanel.cfg.position !== "center"

    visible: shown || fade.running
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:quickpanel"
    WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    // Only once the panel stops scaling: the region follows geometry, not scale.
    BackgroundEffect.blurRegion: Theme.blur && shown && panel.scale === 1 ? blur : null
    Region {
        id: blur
        item: panel
        radius: panel.radius
    }

    property string query: ""
    property int current: 0

    // ── Content model ────────────────────────────────────────────────────
    // sections: [{ key, title, grid, items: [{ type, id, entry, clip, snippet }] }]
    readonly property var sections: {
        const q = query.trim();
        const out = [];
        const favs = QuickPanel.favorites.filter(id => Actions.available(id)).map(id => Actions.entry(id)).filter(e => Actions.matches(e, q));
        if (favs.length > 0)
            out.push({ key: "favorites", title: q ? "Favorites" : "", grid: true, items: favs.map(e => ({ type: "action", id: e.id, entry: e })) });
        if (q) {
            const more = Actions.all().filter(e => !QuickPanel.isFavorite(e.id) && Actions.available(e.id) && Actions.matches(e, q)).slice(0, QuickPanel.columns * 2);
            if (more.length > 0)
                out.push({ key: "more", title: "Actions", grid: true, items: more.map(e => ({ type: "action", id: e.id, entry: e })) });
        }
        const nClip = QuickPanel.cfg.clipboard ?? 5;
        if (Features.on("clipboard") && nClip > 0) {
            const lq = q.toLowerCase();
            const clips = Clipboard.entries.filter(c => !q || c.text.toLowerCase().includes(lq)).slice(0, nClip);
            if (clips.length > 0)
                out.push({ key: "clipboard", title: "Clipboard", grid: false, items: clips.map(c => ({ type: "clip", id: "clip:" + c.id, clip: c })) });
        }
        if (Features.on("snippets") && QuickPanel.cfg.snippets !== false) {
            const sn = Snippets.search(q).slice(0, q ? 6 : 4);
            if (sn.length > 0)
                out.push({ key: "snippets", title: "Snippets", grid: false, items: sn.map(s => ({ type: "snippet", id: "snippet:" + s.id, snippet: s })) });
        }
        let offset = 0;
        for (const s of out) {
            s.offset = offset;
            offset += s.items.length;
        }
        return out;
    }
    readonly property int count: sections.reduce((n, s) => n + s.items.length, 0)

    function itemAt(i) {
        for (const s of sections)
            if (i >= s.offset && i < s.offset + s.items.length)
                return s.items[i - s.offset];
        return null;
    }

    function sectionAt(i) {
        return sections.find(s => i >= s.offset && i < s.offset + s.items.length) ?? null;
    }

    onCountChanged: if (current >= count)
        current = Math.max(0, count - 1)

    onShownChanged: {
        if (shown) {
            query = "";
            current = 0;
            search.text = "";
            search.forceActiveFocus();
            placeTimeout.fired = false;
            placeTimeout.restart();
        }
    }

    // The pointer is reported once the overlay is under it; without a
    // report (pointer on another display) the panel opens centered.
    Timer {
        id: placeTimeout
        property bool fired: false
        interval: 120
        onTriggered: fired = true
    }

    function close() {
        QuickPanel.open = false;
    }

    function run(item) {
        if (!item)
            return;
        if (item.type === "action")
            QuickPanel.runAction(item.id);
        else if (item.type === "clip")
            QuickPanel.activate(() => Clipboard.paste(item.clip));
        else if (item.type === "snippet")
            QuickPanel.activate(() => Snippets.expand(item.snippet));
    }

    function step(dir) {
        const s = sectionAt(current);
        if (!s)
            return;
        const i = current - s.offset;
        const cols = s.grid ? QuickPanel.columns : 1;
        if (dir === "right")
            current = Math.min(count - 1, current + 1);
        else if (dir === "left")
            current = Math.max(0, current - 1);
        else if (dir === "down") {
            if (i + cols < s.items.length)
                current += cols;
            else if (s.grid && Math.floor(i / cols) < Math.floor((s.items.length - 1) / cols))
                current = s.offset + s.items.length - 1;
            else
                current = Math.min(count - 1, s.offset + s.items.length);
        } else if (dir === "up") {
            if (i - cols >= 0)
                current -= cols;
            else if (s.offset > 0) {
                const p = sectionAt(s.offset - 1);
                const col = s.grid ? i % cols : 0;
                if (p.grid) {
                    const lastRow = Math.floor((p.items.length - 1) / QuickPanel.columns) * QuickPanel.columns;
                    current = p.offset + Math.min(p.items.length - 1, lastRow + col);
                } else
                    current = s.offset - 1;
            }
        }
    }

    // Outside the panel: track the pointer, close on click.
    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPositionChanged: mouse => root.notePointer(mouse.x, mouse.y)
        onEntered: root.notePointer(mouseX, mouseY)
        onPressed: root.close()
    }

    function notePointer(x, y) {
        if (root.shown && QuickPanel.pointerX < 0 && !placeTimeout.fired) {
            QuickPanel.pointerX = x;
            QuickPanel.pointerY = y;
        }
    }

    GlassSurface {
        id: panel

        readonly property real px: QuickPanel.pointerX >= 0 ? QuickPanel.pointerX : root.width / 2
        readonly property real py: QuickPanel.pointerY >= 0 ? QuickPanel.pointerY : root.height * 0.38

        width: QuickPanel.panelWidth
        height: Math.min(root.height - 80, body.implicitHeight + 28)
        // At the pointer: centered on it horizontally, its top just above
        // it; kept on screen.
        x: Math.round(Math.max(12, Math.min(root.width - width - 12, (root.atPointer ? px : root.width / 2) - width / 2)))
        y: Math.round(Math.max(40, Math.min(root.height - height - 12, root.atPointer && QuickPanel.pointerY >= 0 ? py - 34 : root.height * 0.38 - height / 2)))
        radius: 24
        strength: 1.6
        transformOrigin: Item.Top

        opacity: root.shown && root.placed ? 1 : 0
        scale: root.shown && root.placed ? 1 : 0.94
        Behavior on opacity {
            NumberAnimation {
                id: fade
                duration: root.shown ? 200 : 140
                easing.type: Easing.OutQuart
            }
        }
        Behavior on scale {
            NumberAnimation {
                duration: 200
                easing.type: Easing.OutQuart
            }
        }

        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            id: body
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: 14
            }
            spacing: 10

            // Search
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 6
                spacing: 10

                Icon {
                    text: "󰍉"
                    size: 17
                    color: Theme.subtext
                }

                TextInput {
                    id: search
                    Layout.fillWidth: true
                    color: Theme.text
                    selectionColor: Theme.withAlpha(Theme.accent, 0.5)
                    font.family: Theme.fontUi
                    font.pixelSize: 16
                    clip: true
                    onTextEdited: {
                        root.query = text;
                        root.current = 0;
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: search.text === ""
                        text: "Search tools, clipboard, snippets"
                        color: Theme.withAlpha(Theme.subtext, 0.7)
                        font: search.font
                    }

                    Keys.onPressed: event => {
                        const ctrl = event.modifiers & Qt.ControlModifier;
                        if (event.key === Qt.Key_Escape)
                            root.close();
                        else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_N))
                            root.step("down");
                        else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_P))
                            root.step("up");
                        else if (event.key === Qt.Key_Tab)
                            root.step("right");
                        else if (event.key === Qt.Key_Backtab)
                            root.step("left");
                        else if ((event.key === Qt.Key_Right || event.key === Qt.Key_Left) && search.text === "")
                            root.step(event.key === Qt.Key_Right ? "right" : "left");
                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                            root.run(root.itemAt(root.current));
                        else if (ctrl && event.key === Qt.Key_Comma)
                            QuickPanel.activate(() => Actions.showSettings("quickpanel"));
                        else
                            return;
                        event.accepted = true;
                    }
                }

                // Edit (Settings → Quick Panel)
                Rectangle {
                    implicitWidth: 26
                    implicitHeight: 26
                    radius: 13
                    color: gear.containsMouse ? Theme.withAlpha(Theme.text, 0.14) : "transparent"
                    Icon {
                        anchors.centerIn: parent
                        text: "󰒓"
                        size: 14
                        color: Theme.subtext
                    }
                    MouseArea {
                        id: gear
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: QuickPanel.activate(() => Actions.showSettings("quickpanel"))
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.glassBorder
            }

            Text {
                Layout.fillWidth: true
                Layout.topMargin: 10
                Layout.bottomMargin: 10
                visible: root.count === 0
                horizontalAlignment: Text.AlignHCenter
                text: root.query ? "No matches" : "Add tools in Settings → Quick Panel"
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 13
            }

            Repeater {
                model: root.sections

                delegate: ColumnLayout {
                    id: sec
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 4

                    Text {
                        visible: sec.modelData.title !== ""
                        Layout.leftMargin: 6
                        text: sec.modelData.title
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                    }

                    // Tools: a grid of tiles
                    Grid {
                        visible: sec.modelData.grid
                        Layout.fillWidth: true
                        columns: QuickPanel.columns
                        readonly property real cell: Math.floor(width / QuickPanel.columns)

                        Repeater {
                            model: sec.modelData.grid ? sec.modelData.items : []
                            delegate: Tile {
                                required property var modelData
                                required property int index
                                width: parent.cell
                                item: modelData
                                flatIndex: sec.modelData.offset + index
                            }
                        }
                    }

                    // Clipboard entries and snippets: rows
                    Repeater {
                        model: sec.modelData.grid ? [] : sec.modelData.items
                        delegate: Line {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            item: modelData
                            flatIndex: sec.modelData.offset + index
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.leftMargin: 6
                Layout.topMargin: 2
                text: "↵ run   ⇥ next   ⌃, edit   esc close"
                color: Theme.withAlpha(Theme.subtext, 0.8)
                font.family: Theme.fontUi
                font.pixelSize: 10
            }
        }
    }

    // ── A tool tile: a disc (accent while a toggle is on) and its name ───
    component Tile: Item {
        id: tile
        property var item
        property int flatIndex
        readonly property var entry: item.entry
        readonly property bool selected: flatIndex === root.current
        readonly property bool on: Actions.active(item.id)
        readonly property string state_: Actions.status(item.id)

        height: 86

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: 14
            color: tile.selected ? Theme.withAlpha(Theme.accent, 0.24) : hit.containsMouse ? Theme.withAlpha(Theme.text, 0.07) : "transparent"
            Behavior on color {
                ColorAnimation {
                    duration: 120
                }
            }
        }

        Rectangle {
            id: disc
            anchors.horizontalCenter: parent.horizontalCenter
            y: 8
            width: 42
            height: 42
            radius: 21
            color: tile.on ? Theme.accent : Theme.withAlpha(Theme.text, tile.entry.kind === "app" ? 0 : 0.13)
            scale: hit.pressed ? 0.92 : 1
            Behavior on scale {
                NumberAnimation {
                    duration: 90
                }
            }
            Behavior on color {
                ColorAnimation {
                    duration: 150
                }
            }

            Icon {
                visible: tile.entry.kind !== "app"
                anchors.centerIn: parent
                text: Actions.icon(tile.item.id)
                size: 19
                color: tile.on ? Theme.bg : Theme.text
            }
            AppIcon {
                visible: tile.entry.kind === "app"
                anchors.fill: parent
                appId: tile.entry.appId ?? ""
                pixelSize: 84
            }
        }

        Text {
            anchors {
                top: disc.bottom
                topMargin: 5
                left: parent.left
                right: parent.right
                leftMargin: 4
                rightMargin: 4
            }
            // A running timer shows its time; otherwise the name.
            text: tile.state_ !== "" && !["On", "Off"].includes(tile.state_) && tile.on ? tile.state_ : tile.entry.label
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 10
            lineHeight: 0.95
        }

        MouseArea {
            id: hit
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: root.current = tile.flatIndex
            onClicked: root.run(tile.item)
        }
    }

    // ── A clipboard entry or a snippet ───────────────────────────────────
    component Line: Rectangle {
        id: line
        property var item
        property int flatIndex
        readonly property bool selected: flatIndex === root.current
        readonly property bool isClip: item.type === "clip"
        readonly property string image: isClip && item.clip.image ? (Clipboard.images[item.clip.id] ?? "") : ""

        implicitHeight: 34
        radius: 10
        color: selected ? Theme.withAlpha(Theme.accent, 0.24) : lineHit.containsMouse ? Theme.withAlpha(Theme.text, 0.07) : "transparent"

        Component.onCompleted: if (isClip && item.clip.image)
            Clipboard.decodeImage(item.clip)

        RowLayout {
            anchors {
                fill: parent
                leftMargin: 10
                rightMargin: 10
            }
            spacing: 10

            Item {
                Layout.preferredWidth: 22
                Layout.preferredHeight: 22
                Icon {
                    anchors.centerIn: parent
                    visible: line.image === ""
                    text: line.isClip ? (line.item.clip.image ? "󰋩" : "󰅍") : "󱐋"
                    size: 14
                    color: Theme.subtext
                }
                Image {
                    anchors.fill: parent
                    visible: line.image !== ""
                    source: line.image ? "file://" + line.image : ""
                    sourceSize: Qt.size(44, 44)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }
            }

            Text {
                Layout.fillWidth: true
                text: line.isClip ? line.item.clip.text.replace(/\s+/g, " ").trim() : (line.item.snippet.name || "Snippet")
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 12
                elide: Text.ElideRight
            }

            Text {
                visible: !line.isClip && (line.item.snippet.trigger ?? "") !== ""
                text: line.isClip ? "" : (line.item.snippet.trigger ?? "")
                color: Theme.subtext
                font.family: "monospace"
                font.pixelSize: 11
            }
        }

        MouseArea {
            id: lineHit
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: root.current = line.flatIndex
            onClicked: root.run(line.item)
        }
    }
}
