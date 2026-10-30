import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services
import qs.menubar

// The dock (macOS): pinned apps, then running apps that aren't pinned |
// recent apps (feature dockRecents) | docked folders and the Trash (feature
// dockStacks), on a floating Liquid Glass shelf at the bottom, left or right
// edge. Icons magnify as a fisheye under the pointer; right-click anything
// for its menu (DockMenu, drawn by the menu bar's cascade).
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    // Per display (Settings → Dock → Displays): position, auto-hide.
    readonly property var prefs: DockData.profileFor(modelData)
    readonly property string edge: prefs.position
    readonly property bool vertical: edge !== "bottom"

    readonly property real iconSize: prefs.iconSize
    readonly property real mag: Math.max(1, prefs.magnification)
    readonly property int margin: 8
    readonly property int pad: 10
    readonly property int spacing: 8
    readonly property real thickness: iconSize + 2 * pad
    // Room beyond the shelf for magnified icons and the name tag.
    readonly property real depth: thickness + margin + iconSize * (mag - 1) + (vertical ? 240 : 48)

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "loft:dock"
    anchors {
        bottom: true
        top: root.vertical
        left: root.edge !== "right"
        right: root.edge !== "left"
    }
    implicitWidth: vertical ? depth : 0
    implicitHeight: vertical ? 0 : depth
    // Only an always-shown dock reserves space (and not under a fullscreen
    // window); "whenWindows" doesn't, so windows don't jump when it hides.
    exclusiveZone: prefs.autoHide === "never" && !fullscreen ? thickness + margin : 0
    color: "transparent"

    // ── Auto-hide (macOS): out of view until the pointer touches the edge;
    // stays while hovered or a menu / stack is open. A dock that doesn't
    // auto-hide still steps aside while a window is fullscreen here.
    readonly property bool fullscreen: Displays.fullscreenOn(modelData)
    // Windows on this display's active workspace (for "whenWindows").
    readonly property bool occupied: {
        const ws = Niri.workspaces.find(w => w.output === modelData.name && w.is_active);
        return !!ws && Niri.windows.some(w => w.workspace_id === ws.id);
    }
    readonly property bool hideable: fullscreen || prefs.hidden || prefs.autoHide === "always" || (prefs.autoHide === "whenWindows" && occupied)
    readonly property bool busy: winHover.hovered || menuOpen || stackOpenHere || dragging || previewHere
    property bool dragging: false
    property bool summoned: false
    readonly property bool revealed: !prefs.hidden && (!hideable || summoned)
    onBusyChanged: {
        if (busy)
            hideTimer.stop();
        else if (summoned)
            hideTimer.restart();
    }
    // Becoming hideable while the pointer is on the dock: stay until it leaves.
    onHideableChanged: {
        summoned = hideable && busy;
        if (summoned)
            hideTimer.restart();
    }

    Timer {
        id: revealTimer
        interval: 120
        onTriggered: {
            root.summoned = true;
            hideTimer.restart();
        }
    }
    Timer {
        id: hideTimer
        interval: 700
        onTriggered: if (!root.busy)
            root.summoned = false
    }

    // How far the shelf is slid out of view (animated).
    property real slide: revealed ? 0 : thickness + margin + 6
    Behavior on slide {
        NumberAnimation {
            duration: 220
            easing.type: Easing.OutCubic
        }
    }

    // The edge strip that summons a hidden dock.
    PanelWindow {
        screen: root.modelData
        visible: root.hideable && !root.revealed && !root.prefs.hidden
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "loft:dock-hotzone"
        exclusionMode: ExclusionMode.Ignore
        anchors {
            bottom: root.edge === "bottom" || root.vertical
            top: root.vertical
            left: root.edge !== "right"
            right: root.edge !== "left"
        }
        implicitWidth: root.vertical ? 2 : 0
        implicitHeight: root.vertical ? 0 : 2
        color: "transparent"

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onEntered: revealTimer.restart()
            onExited: revealTimer.stop()
        }
        DropArea {
            anchors.fill: parent
            onEntered: revealTimer.restart()
        }
    }

    // ── What's in the dock ───────────────────────────────────────────────
    // Tiles as strings (kind:section:id) so the model diffs and delegates
    // survive window changes.
    readonly property var tiles: {
        const t = [];
        const pinned = prefs.pinned;
        for (const a of pinned)
            t.push(`app:pinned:${a}`);
        const running = [];
        for (const w of Niri.windows) {
            const a = w.app_id;
            if (a && !pinned.some(p => DockData.sameApp(p, a)) && !running.some(r => DockData.sameApp(r, a)))
                running.push(a);
        }
        for (const a of running)
            t.push(`app:running:${a}`);
        // Launchpad second, after the first pinned app (macOS: Finder).
        if (Features.on("launchpad"))
            t.splice(Math.min(1, pinned.length), 0, "launchpad::");
        if (Features.on("dockRecents")) {
            const shown = pinned.concat(running);
            const recent = AppUsage.recentApps(40, shown).filter(a => Apps.own[a] === undefined && Apps.entry(a) !== null && !shown.some(s => DockData.sameApp(s, a))).slice(0, prefs.recentCount);
            if (recent.length > 0) {
                t.push("divider:recent:");
                for (const a of recent)
                    t.push(`app:recent:${a}`);
            }
        }
        if (DockData.stacksOn && (prefs.folders.length > 0 || prefs.trash)) {
            t.push("divider:stacks:");
            prefs.folders.forEach((f, i) => t.push(`folder:${i}:${f.path}`));
            if (prefs.trash)
                t.push("trash::");
        }
        return t;
    }

    function parse(tile) {
        const i = tile.indexOf(":"), j = tile.indexOf(":", i + 1);
        return { kind: tile.slice(0, i), section: tile.slice(i + 1, j), id: tile.slice(j + 1) };
    }

    readonly property real dividerSize: 13
    function baseSize(tile) {
        return tile.startsWith("divider:") ? dividerSize : iconSize;
    }

    // Resting (unmagnified) centers along the shelf: the fisheye measures
    // the pointer against these, so magnifying never feeds back on itself.
    readonly property var baseCenters: {
        const c = [];
        let at = pad;
        for (const t of tiles) {
            const s = baseSize(t);
            c.push(at + s / 2);
            at += s + spacing;
        }
        return c;
    }
    readonly property real baseLength: tiles.reduce((a, t) => a + baseSize(t), 0) + spacing * Math.max(0, tiles.length - 1) + 2 * pad

    // Pointer position along the resting shelf, or -1. While a menu, stack
    // or window preview from this dock is open, the fisheye holds where the
    // pointer last was (macOS keeps the icons magnified under a menu).
    readonly property bool magnifyHeld: menuOpen || stackOpenHere || previewHere
    property real heldPointer: -1
    onLivePointerChanged: if (!magnifyHeld && (livePointer >= 0 || !releaseGrace.running))
        heldPointer = livePointer
    // When the menu closes the pointer is often still on the dock, but the
    // dock only hears about it on the next motion: keep the held fisheye a
    // moment instead of collapsing and re-magnifying (a flash).
    onMagnifyHeldChanged: if (!magnifyHeld)
        releaseGrace.restart()
    Timer {
        id: releaseGrace
        interval: 350
        onTriggered: root.heldPointer = root.livePointer
    }
    readonly property real pointer: magnifyHeld || (releaseGrace.running && livePointer < 0) ? heldPointer : livePointer
    readonly property real livePointer: {
        if (!hover.hovered)
            return -1;
        // Window coordinates: the shelf is centered in the window, so the
        // resting layout starts at center − baseLength / 2. (Nothing here
        // may depend on the shelf's own size: that's what it sizes.)
        const p = winHover.point.position;
        const along = vertical ? p.y : p.x;
        const len = vertical ? root.height : root.width;
        return along - len / 2 + baseLength / 2;
    }
    readonly property bool menuOpen: MenuState.open && MenuState.context !== null && MenuState.screen === modelData.name

    function magnifyAt(index) {
        if (pointer < 0 || mag <= 1.001 || tiles[index]?.startsWith("divider:"))
            return 1;
        const d = Math.abs(pointer - baseCenters[index]);
        const range = iconSize * 2.6;
        return d >= range ? 1 : 1 + (mag - 1) * (Math.cos(Math.PI * d / range) + 1) / 2;
    }

    // ── Input: the shelf (and, while hovered, the magnified icons) ───────
    // The shelf plus the gap to the screen edge (and, while hovered, the
    // magnified icons); nothing while hidden.
    mask: Region {
        item: hitArea
    }
    Item {
        id: hitArea
        readonly property real grow: hover.hovered ? root.iconSize * (root.mag - 1) + 4 : 0
        readonly property bool on: root.revealed || root.slide < root.thickness
        x: !on ? 0 : root.edge === "right" ? shelf.x - grow : root.edge === "left" ? 0 : shelf.x
        y: !on ? 0 : root.vertical ? shelf.y : shelf.y - grow
        width: !on ? 0 : root.vertical ? shelf.width + grow + root.margin : shelf.width
        height: !on ? 0 : root.vertical ? shelf.height : shelf.height + grow + root.margin
    }
    HoverHandler {
        id: winHover
    }
    // Something dragged over the dock keeps it shown. Rejected here, so the
    // icons' own drop targets (an app, the Trash) get the drag; a rejected
    // area hears every move as a new "entered", which keeps the timer fed.
    DropArea {
        anchors.fill: hitArea
        onEntered: d => {
            root.dragging = true;
            dragOff.restart();
            d.accepted = false;
        }
    }
    Timer {
        id: dragOff
        interval: 2500
        onTriggered: root.dragging = false
    }

    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur ? shelf : null
        radius: shelf.radius

        Region {
            item: Theme.blur && nameTag.visible ? nameTag : null
            radius: nameTag.radius
        }
    }

    GlassSurface {
        id: shelf
        readonly property real length: (root.vertical ? row.height : row.width) + 2 * root.pad
        x: root.edge === "bottom" ? (root.width - width) / 2 : root.edge === "left" ? root.margin - root.slide : root.width - width - root.margin + root.slide
        y: root.vertical ? (root.height - height) / 2 : root.height - height - root.margin + root.slide
        opacity: root.slide >= root.thickness + root.margin ? 0 : 1
        width: root.vertical ? root.thickness : length
        height: root.vertical ? length : root.thickness
        radius: Theme.radius + 8
        strength: 1.4
        // Liquid Glass: a light frost over the blurred wallpaper.
        clear: true

        HoverHandler {
            id: hover
        }

        // Right-click on the shelf itself: the dock's own menu.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.RightButton
            onClicked: m => {
                // From the shelf's outer edge, like an icon's menu.
                const p = root.screenPoint(shelf, root.edge === "left" ? shelf.width : root.edge === "right" ? 0 : m.x, root.edge === "bottom" ? 0 : m.y);
                DockMenu.openDock(root.modelData, p.x, p.y, root.edge);
            }
        }

        Grid {
            id: row
            x: root.vertical ? root.pad : root.pad
            y: root.pad
            rows: root.vertical ? -1 : 1
            columns: root.vertical ? 1 : -1
            spacing: root.spacing
            verticalItemAlignment: Grid.AlignBottom
            horizontalItemAlignment: root.edge === "right" ? Grid.AlignRight : Grid.AlignLeft

            Repeater {
                model: ScriptModel {
                    values: root.tiles
                }

                delegate: Loader {
                    id: slot
                    required property string modelData
                    required property int index
                    readonly property var tile: root.parse(modelData)
                    readonly property real magnify: root.magnifyAt(index)
                    readonly property bool tileHovered: item?.hovered ?? false

                    onTileHoveredChanged: {
                        if (tileHovered)
                            root.hovered = slot;
                        else if (root.hovered === slot)
                            root.hovered = null;
                    }

                    sourceComponent: tile.kind === "app" ? appTile : tile.kind === "folder" ? folderTile : tile.kind === "trash" ? trashTile : tile.kind === "launchpad" ? launchpadTile : divider

                    Component {
                        id: appTile
                        DockItem {
                            appId: slot.tile.id
                            section: slot.tile.section
                            bounceOnLaunch: root.prefs.bounce
                            showIndicator: root.prefs.indicators
                            edge: root.edge
                            iconSize: root.iconSize
                            magnify: slot.magnify
                            previewOnClick: Previews.enabled && Previews.mode === "click"
                            onMenuRequested: alt => root.menuFor(slot, alt)
                            onClicked: root.previewClicked(slot)
                            onPreviewRequested: root.togglePreview(slot)
                        }
                    }
                    Component {
                        id: folderTile
                        DockStack {
                            folderIndex: Number(slot.tile.section)
                            folder: root.prefs.folders[folderIndex] ?? ({})
                            showIndicator: false
                            edge: root.edge
                            iconSize: root.iconSize
                            magnify: slot.magnify
                            onClicked: root.toggleStack(slot, Number(slot.tile.section))
                            onMenuRequested: root.menuFor(slot, false)
                        }
                    }
                    Component {
                        id: trashTile
                        DockTrash {
                            edge: root.edge
                            iconSize: root.iconSize
                            magnify: slot.magnify
                            onMenuRequested: root.menuFor(slot, false)
                        }
                    }
                    Component {
                        id: launchpadTile
                        DockLaunchpad {
                            screenName: root.modelData.name
                            showIndicator: root.prefs.indicators
                            edge: root.edge
                            iconSize: root.iconSize
                            magnify: slot.magnify
                        }
                    }
                    Component {
                        id: divider
                        Item {
                            implicitWidth: root.vertical ? root.iconSize : root.dividerSize
                            implicitHeight: root.vertical ? root.dividerSize : root.iconSize
                            Rectangle {
                                anchors.centerIn: parent
                                width: root.vertical ? root.iconSize * 0.8 : 1
                                height: root.vertical ? 1 : root.iconSize * 0.8
                                color: Theme.glassBorder
                            }
                        }
                    }
                }
            }
        }

        Behavior on width {
            enabled: !hover.hovered
            NumberAnimation {
                duration: 160
                easing.type: Easing.OutCubic
            }
        }
        Behavior on height {
            enabled: !hover.hovered
            NumberAnimation {
                duration: 160
                easing.type: Easing.OutCubic
            }
        }
    }

    // ── Name tag, menus, stacks ──────────────────────────────────────────
    property var hovered: null
    readonly property string hoveredLabel: hovered && !menuOpen && !stackOpenHere && !previewHere ? (hovered.item?.label ?? "") : ""

    // A point of `item` in screen coordinates (the window hugs the bottom
    // of the screen, and its left or right edge).
    function screenPoint(item, x, y) {
        const p = item.mapToItem(root.contentItem, x, y);
        return {
            x: p.x + (edge === "right" ? modelData.width - root.width : 0),
            y: p.y + modelData.height - root.height
        };
    }

    // The middle of a tile's outward edge (where its menu/popup attaches).
    function tileAnchor(slot) {
        const f = slot.item.face;
        const pt = edge === "bottom" ? [f.width / 2, 0] : edge === "left" ? [f.width, f.height / 2] : [0, f.height / 2];
        // Beyond the magnified face, so the menu doesn't cover the icon.
        const extra = root.iconSize * (root.mag - 1) * 0.3;
        const p = screenPoint(f, pt[0], pt[1]);
        if (edge === "bottom")
            p.y -= extra;
        else if (edge === "left")
            p.x += extra;
        else
            p.x -= extra;
        return p;
    }

    function menuFor(slot, alt) {
        DockData.openStack = null;
        Previews.close();
        const p = tileAnchor(slot);
        const t = slot.tile;
        if (t.kind === "app")
            DockMenu.openApp(modelData.name, p.x, p.y, edge, t.id, t.section, alt);
        else if (t.kind === "folder")
            DockMenu.openFolder(modelData.name, p.x, p.y, edge, Number(t.section));
        else if (t.kind === "trash")
            DockMenu.openTrash(modelData.name, p.x, p.y, edge);
    }

    readonly property bool stackOpenHere: DockData.openStack !== null && DockData.openStack.screen === modelData.name
    function toggleStack(slot, index) {
        if (stackOpenHere && DockData.openStack.index === index) {
            DockData.openStack = null;
            return;
        }
        Previews.close();
        const p = tileAnchor(slot);
        DockData.openStack = { screen: modelData.name, index: index, x: p.x, y: p.y, edge: edge };
    }

    // ── Window preview (Previews, PreviewPopup) ──────────────────────────
    // Hover mode: resting on a running app's icon for Previews.delay opens
    // it; moving to another app's icon while it's open switches at once.
    // Click mode: clicking an app with several windows toggles it. Either
    // way it stays while the pointer is on the icon or the popover, and
    // closes shortly after it leaves both. A click on the icon closes it
    // and mutes that icon until the pointer moves off.
    readonly property bool previewHere: Previews.current !== null && Previews.current.screen === modelData.name
    property var previewMuted: null

    function previewable(slot) {
        // (A slot can be gone by now: the tiles changed.)
        const t = slot?.tile;
        return !!t && t.kind === "app" && DockData.windowsOf(t.id).length > 0;
    }

    function openPreview(slot) {
        const p = tileAnchor(slot);
        previewClose.stop();
        Previews.current = { screen: modelData.name, appId: slot.tile.id, x: p.x, y: p.y, edge: edge };
    }

    function togglePreview(slot) {
        previewOpen.stop();
        if (previewHere && Previews.current.appId === slot.tile.id) {
            Previews.close();
            return;
        }
        // Snapshot first; the popover follows a moment later.
        thumbs.capture(slot.tile.id);
        previewOpen.slot = slot;
        previewOpen.interval = 90;
        previewOpen.restart();
    }

    function previewClicked(slot) {
        if (!Previews.enabled || Previews.mode !== "hover")
            return;
        previewOpen.stop();
        previewMuted = slot;
        Previews.close();
    }

    onHoveredChanged: {
        previewOpen.stop();
        if (hovered !== previewMuted)
            previewMuted = null;
        const s = hovered;
        if (!Previews.enabled || menuOpen || stackOpenHere)
            return;
        if (previewable(s) && s !== previewMuted) {
            if (previewHere && Previews.current.appId === s.tile.id) {
                previewClose.stop();
                return;
            }
            if (Previews.mode === "hover") {
                thumbs.capture(s.tile.id);
                if (previewHere) {
                    openPreview(s);
                    return;
                }
                previewOpen.slot = s;
                previewOpen.interval = Math.max(90, Previews.delay);
                previewOpen.restart();
                return;
            }
        }
        if (previewHere)
            previewClose.restart();
    }

    Connections {
        target: Previews
        function onHoveredChanged() {
            if (Previews.hovered)
                previewClose.stop();
            else if (root.previewHere)
                previewClose.restart();
        }
    }

    Timer {
        id: previewOpen
        property var slot: null
        onTriggered: {
            if (slot && root.previewable(slot) && !root.menuOpen && !root.stackOpenHere)
                root.openPreview(slot);
        }
    }
    Timer {
        id: previewClose
        interval: 300
        onTriggered: {
            if (!root.previewHere || Previews.hovered)
                return;
            const t = root.hovered?.tile;
            if (t && t.kind === "app" && t.id === Previews.current.appId)
                return;
            Previews.close();
        }
    }

    WindowThumbs {
        id: thumbs
    }

    PreviewPopup {
        dock: root
    }

    GlassSurface {
        id: nameTag
        visible: root.hoveredLabel !== ""
        height: 28
        width: labelText.implicitWidth + 24
        radius: height / 2
        strength: 1.6
        readonly property var c: root.hovered ? root.hovered.mapToItem(root.contentItem, root.hovered.width / 2, root.hovered.height / 2) : Qt.point(0, 0)
        readonly property real reach: root.iconSize * root.mag + 14
        x: root.edge === "bottom" ? Math.max(4, Math.min(root.width - width - 4, c.x - width / 2)) : root.edge === "left" ? shelf.x + shelf.width + root.iconSize * (root.mag - 1) + 12 : shelf.x - width - root.iconSize * (root.mag - 1) - 12
        y: root.edge === "bottom" ? shelf.y - root.iconSize * (root.mag - 1) - height - 10 : Math.max(4, Math.min(root.height - height - 4, c.y - height / 2))

        Text {
            id: labelText
            anchors.centerIn: parent
            text: root.hoveredLabel
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 13
            font.weight: Font.Medium
        }
    }

    StackPopup {
        dock: root
        folders: root.prefs.folders
    }
}
