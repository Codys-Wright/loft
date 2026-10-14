import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.controls
import qs.services

// macOS (Golden Gate) Control Center: a grid of glass modules — 1×1, 2×1,
// 2×2 and 4-wide slider rows on a 4-column cell grid — anchored top-right
// under the bar. Panel modules (Wi-Fi, Bluetooth, Sound, Display, Focus,
// Now Playing) expand in place into the same panels the menu bar's
// dropdowns show (src/controls/). Edit Controls: drag to reorder, − to
// remove, ⤢ to resize, and a gallery to add controls or pin them to the
// menu bar. The layout lives in Settings.controlCenter.layout (Controls).
//
// Keyboard: arrows move between modules, Space toggles, Enter (or Right on
// an expandable module) expands, Tab cycles, Esc backs out then closes.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property bool shown: Panels.controlCenterOpen && Panels.controlCenterScreen === modelData.name

    visible: shown || slide.running
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "studio:controlcenter"
    WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    // ── Geometry ─────────────────────────────────────────────────────────
    readonly property int cols: 4
    readonly property int cell: 72
    readonly property int gap: 10
    readonly property int pad: 12
    readonly property int gridWidth: cols * cell + (cols - 1) * gap
    readonly property int panelWidth: gridWidth + 2 * pad
    // One curve for opening, closing and expanding (Golden Gate).
    readonly property int motion: 320
    readonly property int curve: Easing.OutQuart

    readonly property bool editing: Panels.ccEditing && shown
    readonly property string expanded: shown ? Panels.ccExpanded : ""
    property var draft: []
    readonly property var layout: editing ? draft : Controls.ccVisible

    onEditingChanged: if (editing)
        draft = Controls.ccLayout.filter(e => Controls.available(e.id))
    onShownChanged: {
        if (!shown) {
            Panels.ccExpanded = "";
            if (Panels.ccEditing)
                finishEdit();
            Nav.ccFocus = null;
        }
    }

    function finishEdit() {
        // Keep entries for controls unavailable right now (battery, …).
        const hidden = Controls.ccLayout.filter(e => !Controls.available(e.id) && !draft.some(d => d.id === e.id));
        Controls.saveCc(draft.concat(hidden));
        Panels.ccEditing = false;
    }

    function cellsOf(size) {
        const p = size.split("x").map(Number);
        return { w: p[0], h: p[1] };
    }

    // First-fit packing on the 4-column grid → id → { x, y, w, h, size }.
    readonly property var geom: {
        const occ = [];
        const taken = (r, c) => (occ[r] ?? [])[c] === true;
        const out = {};
        let rows = 0;
        for (const e of layout) {
            const s = cellsOf(e.size);
            let placed = false;
            for (let r = 0; !placed && r < 64; r++) {
                for (let c = 0; c + s.w <= cols && !placed; c++) {
                    let free = true;
                    for (let dr = 0; dr < s.h && free; dr++)
                        for (let dc = 0; dc < s.w && free; dc++)
                            if (taken(r + dr, c + dc))
                                free = false;
                    if (!free)
                        continue;
                    for (let dr = 0; dr < s.h; dr++) {
                        occ[r + dr] = occ[r + dr] ?? [];
                        for (let dc = 0; dc < s.w; dc++)
                            occ[r + dr][c + dc] = true;
                    }
                    out[e.id] = {
                        x: c * (cell + gap),
                        y: r * (cell + gap),
                        w: s.w * cell + (s.w - 1) * gap,
                        h: s.h * cell + (s.h - 1) * gap,
                        size: e.size
                    };
                    rows = Math.max(rows, r + s.h);
                    placed = true;
                }
            }
        }
        out.__rows = rows;
        return out;
    }
    readonly property real gridHeight: Math.max(cell, geom.__rows * cell + Math.max(0, geom.__rows - 1) * gap)

    // ── Keyboard ─────────────────────────────────────────────────────────
    function focusables() {
        const out = [];
        const walk = it => {
            for (const c of it.children) {
                if (!c.visible)
                    continue;
                if (c.ccFocusable === true)
                    out.push(c);
                walk(c);
            }
        };
        walk(grid);
        return out;
    }

    function center(it) {
        return it.mapToItem(grid, it.width / 2, it.height / 2);
    }

    function moveFocus(dx, dy) {
        const l = focusables();
        if (l.length === 0)
            return;
        const cur = Nav.ccFocus && l.includes(Nav.ccFocus) ? Nav.ccFocus : null;
        if (!cur) {
            Nav.ccFocus = l[0];
            return;
        }
        const a = center(cur);
        let best = null;
        let bestScore = Infinity;
        for (const it of l) {
            if (it === cur)
                continue;
            const b = center(it);
            const along = dx !== 0 ? (b.x - a.x) * dx : (b.y - a.y) * dy;
            const across = dx !== 0 ? Math.abs(b.y - a.y) : Math.abs(b.x - a.x);
            if (along <= 4)
                continue;
            const score = along + across * 2;
            if (score < bestScore) {
                bestScore = score;
                best = it;
            }
        }
        if (best)
            Nav.ccFocus = best;
    }

    function cycleFocus(delta) {
        const l = focusables();
        if (l.length === 0)
            return;
        const i = l.indexOf(Nav.ccFocus);
        Nav.ccFocus = l[(i + delta + l.length) % l.length];
    }

    function key(event) {
        const k = event.key;
        if (expanded !== "") {
            if (Nav.typing && ![Qt.Key_Up, Qt.Key_Down, Qt.Key_Escape].includes(k))
                return false;
            if (k === Qt.Key_Escape || k === Qt.Key_Left) {
                if (!(k === Qt.Key_Escape && host.back()))
                    Panels.ccExpanded = "";
            } else if (k === Qt.Key_Down)
                Nav.step(1);
            else if (k === Qt.Key_Up)
                Nav.step(-1);
            else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space)
                Nav.activate();
            else if (event.text && event.text.length === 1 && /\S/.test(event.text))
                Nav.typeSelect(event.text);
            return true;
        }
        if (editing) {
            if (k === Qt.Key_Escape || k === Qt.Key_Return)
                finishEdit();
            return true;
        }
        const f = Nav.ccFocus;
        switch (k) {
        case Qt.Key_Escape:
            Panels.controlCenterOpen = false;
            break;
        case Qt.Key_Left:
            moveFocus(-1, 0);
            break;
        case Qt.Key_Up:
            moveFocus(0, -1);
            break;
        case Qt.Key_Down:
            moveFocus(0, 1);
            break;
        case Qt.Key_Right:
            if (f && f.ccExpandable)
                f.ccExpand();
            else
                moveFocus(1, 0);
            break;
        case Qt.Key_Tab:
            cycleFocus(1);
            break;
        case Qt.Key_Backtab:
            cycleFocus(-1);
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (f)
                f.ccExpandable ? f.ccExpand() : f.ccToggle();
            break;
        case Qt.Key_Space:
            if (f)
                f.ccToggle();
            break;
        }
        return true;
    }

    // ── Blur behind the panel(s) ─────────────────────────────────────────
    BackgroundEffect.blurRegion: Theme.blur && shown && !slide.running ? blur : null
    Region {
        id: blur
        item: backing
        radius: backing.radius
        Region {
            item: root.editing ? gallery : null
            radius: gallery.radius
        }
    }

    // Anywhere outside closes (or leaves Edit mode).
    MouseArea {
        anchors.fill: parent
        onClicked: root.editing ? root.finishEdit() : Panels.controlCenterOpen = false
    }

    FocusScope {
        anchors.fill: parent
        focus: root.shown

        Item {
            id: keys
            anchors.fill: parent
            focus: true
            Keys.onPressed: event => {
                if (root.key(event))
                    event.accepted = true;
            }

            // ── The panel ────────────────────────────────────────────────
            Item {
                id: panel
                width: root.panelWidth
                height: root.expanded !== "" ? Math.min(root.height - 60, Math.max(root.gridHeight + 2 * root.pad, expander.wanted)) : root.gridHeight + 2 * root.pad + footer.height
                anchors {
                    top: parent.top
                    right: parent.right
                    topMargin: 36
                    rightMargin: 10
                }
                opacity: root.shown ? 1 : 0

                Behavior on height {
                    NumberAnimation {
                        duration: root.motion
                        easing.type: root.curve
                    }
                }
                transform: Translate {
                    x: root.shown ? 0 : root.panelWidth + 30
                    Behavior on x {
                        NumberAnimation {
                            id: slide
                            duration: root.motion
                            easing.type: root.curve
                        }
                    }
                }
                Behavior on opacity {
                    NumberAnimation {
                        duration: root.motion
                        easing.type: root.curve
                    }
                }

                GlassSurface {
                    id: backing
                    anchors.fill: parent
                    radius: Theme.radius + 14
                }

                // Swallow clicks on the panel itself.
                MouseArea {
                    anchors.fill: parent
                }

                // ── The grid ─────────────────────────────────────────────
                Item {
                    id: grid
                    x: root.pad
                    y: root.pad
                    width: root.gridWidth
                    height: root.gridHeight
                    opacity: root.expanded === "" ? 1 : 0
                    visible: opacity > 0
                    scale: root.expanded === "" ? 1 : 0.96
                    Behavior on opacity {
                        NumberAnimation {
                            duration: root.motion
                            easing.type: root.curve
                        }
                    }
                    Behavior on scale {
                        NumberAnimation {
                            duration: root.motion
                            easing.type: root.curve
                        }
                    }

                    Repeater {
                        // Every control the CC can hold: delegates stay put
                        // while the layout changes (so a drag survives).
                        model: Controls.controls.filter(c => (c.sizes ?? []).length > 0)

                        delegate: CcModule {
                            id: tile
                            required property var modelData
                            readonly property var g: root.geom[modelData.id] ?? null
                            readonly property bool dragged: dragArea.drag.active

                            controlId: modelData.id
                            size: g?.size ?? modelData.sizes[0]
                            visible: g !== null
                            editing: root.editing
                            dragging: dragged
                            width: g?.w ?? 0
                            height: g?.h ?? 0
                            x: g?.x ?? 0
                            y: g?.y ?? 0
                            Behavior on x {
                                enabled: !tile.dragged
                                NumberAnimation {
                                    duration: 200
                                    easing.type: Easing.OutCubic
                                }
                            }
                            Behavior on y {
                                enabled: !tile.dragged
                                NumberAnimation {
                                    duration: 200
                                    easing.type: Easing.OutCubic
                                }
                            }

                            onExpand: panelId => {
                                expander.from = Qt.rect(x, y, width, height);
                                Panels.ccExpanded = panelId;
                            }
                            onRemoveRequested: root.draft = root.draft.filter(e => e.id !== modelData.id)
                            onResizeRequested: {
                                const sizes = modelData.sizes;
                                root.draft = root.draft.map(e => e.id !== modelData.id ? e : { id: e.id, size: sizes[(sizes.indexOf(e.size) + 1) % sizes.length] });
                            }

                            // Edit mode: drag to reorder.
                            MouseArea {
                                id: dragArea
                                anchors.fill: parent
                                z: -1 // under the − / ⤢ badges
                                enabled: root.editing
                                cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                                drag.target: tile
                                drag.threshold: 4
                                onPositionChanged: {
                                    if (!drag.active)
                                        return;
                                    const cx = tile.x + tile.width / 2;
                                    const cy = tile.y + tile.height / 2;
                                    const over = root.draft.find(e => {
                                        const o = root.geom[e.id];
                                        return e.id !== tile.modelData.id && o && cx >= o.x && cx < o.x + o.w && cy >= o.y && cy < o.y + o.h;
                                    });
                                    if (!over)
                                        return;
                                    const l = root.draft.filter(e => e.id !== tile.modelData.id);
                                    const me = root.draft.find(e => e.id === tile.modelData.id);
                                    l.splice(root.draft.indexOf(over), 0, me);
                                    root.draft = l;
                                }
                                onReleased: {
                                    // Snap back onto the grid.
                                    tile.x = Qt.binding(() => tile.g?.x ?? 0);
                                    tile.y = Qt.binding(() => tile.g?.y ?? 0);
                                }
                            }
                        }
                    }
                }

                // ── Edit Controls / Done ─────────────────────────────────
                Item {
                    id: footer
                    visible: root.expanded === ""
                    anchors {
                        left: parent.left
                        right: parent.right
                        bottom: parent.bottom
                    }
                    height: 34

                    Rectangle {
                        anchors.centerIn: parent
                        width: editLabel.implicitWidth + 24
                        height: 24
                        radius: 12
                        color: root.editing ? Theme.accent : editMouse.containsMouse ? Theme.withAlpha(Theme.text, 0.12) : "transparent"
                        Text {
                            id: editLabel
                            anchors.centerIn: parent
                            text: root.editing ? "Done" : "Edit Controls…"
                            color: root.editing ? Theme.bg : Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 12
                            font.weight: Font.Medium
                        }
                        MouseArea {
                            id: editMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.editing ? root.finishEdit() : Panels.ccEditing = true
                        }
                    }
                }

                // ── Expanded module ──────────────────────────────────────
                Item {
                    id: expander
                    // The module's rect it grows from.
                    property rect from: Qt.rect(0, 0, root.gridWidth, root.cell)
                    readonly property bool open: root.expanded !== ""
                    readonly property real wanted: host.implicitHeight + 44 + 2 * root.pad

                    visible: open || grow.running
                    clip: true
                    x: open ? 0 : root.pad + from.x
                    y: open ? 0 : root.pad + from.y
                    width: open ? panel.width : from.width
                    height: open ? panel.height : from.height
                    opacity: open ? 1 : 0
                    Behavior on x {
                        NumberAnimation {
                            id: grow
                            duration: root.motion
                            easing.type: root.curve
                        }
                    }
                    Behavior on y {
                        NumberAnimation {
                            duration: root.motion
                            easing.type: root.curve
                        }
                    }
                    Behavior on width {
                        NumberAnimation {
                            duration: root.motion
                            easing.type: root.curve
                        }
                    }
                    Behavior on height {
                        NumberAnimation {
                            duration: root.motion
                            easing.type: root.curve
                        }
                    }
                    Behavior on opacity {
                        NumberAnimation {
                            duration: root.motion / 2
                        }
                    }

                    // Back to the grid.
                    Rectangle {
                        id: back
                        x: root.pad
                        y: root.pad
                        width: backRow.implicitWidth + 16
                        height: 26
                        radius: 13
                        color: backMouse.containsMouse ? Theme.withAlpha(Theme.text, 0.12) : "transparent"
                        Row {
                            id: backRow
                            anchors.centerIn: parent
                            spacing: 4
                            Icon {
                                text: "󰅁"
                                size: 13
                                color: Theme.subtext
                            }
                            Text {
                                text: "Control Center"
                                color: Theme.subtext
                                font.family: Theme.fontUi
                                font.pixelSize: 12
                            }
                        }
                        MouseArea {
                            id: backMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Panels.ccExpanded = ""
                        }
                    }

                    Flickable {
                        anchors {
                            left: parent.left
                            right: parent.right
                            top: back.bottom
                            bottom: parent.bottom
                            topMargin: 6
                            leftMargin: root.pad - 4
                            rightMargin: root.pad - 4
                            bottomMargin: root.pad
                        }
                        contentHeight: host.implicitHeight
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds

                        PanelHost {
                            id: host
                            width: parent.width
                            panel: root.expanded
                            inMenu: false
                            shown: root.expanded !== "" && root.shown
                            screenName: root.modelData.name
                            window: root
                            onDismiss: Panels.controlCenterOpen = false
                            onOpenSettings: section => {
                                Panels.controlCenterOpen = false;
                                Panels.settingsSection = section;
                                Panels.settingsOpen = true;
                            }
                        }
                    }
                }
            }

            // ── Edit Controls gallery (left of the panel) ────────────────
            CcGallery {
                id: gallery
                visible: root.editing
                anchors {
                    top: panel.top
                    right: panel.left
                    rightMargin: 12
                }
                width: 330
                height: Math.min(root.height - 80, 560)
                present: root.draft.map(e => e.id)
                onAdd: id => root.draft = root.draft.concat([{ id: id, size: Controls.control(id).sizes[0] }])
            }
        }
    }

    Binding {
        target: Nav
        property: "root"
        value: host
        when: root.shown && root.expanded !== ""
    }

    // Text field done (Wi-Fi password): the keyboard back to the panel.
    Connections {
        target: Nav
        function onTypingChanged() {
            if (!Nav.typing && root.shown)
                keys.forceActiveFocus();
        }
    }
}
