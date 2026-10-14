import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// A docked folder's contents, opened from its stack (macOS): a Fan of the
// newest items curving up from the dock, a Grid of thumbnails, or a List.
// "Automatic" fans up to 10 items (bottom dock), else a grid. Click opens an
// item (xdg-open), drag it out to any app (text/uri-list), Esc or a click
// outside closes.
PanelWindow {
    id: root

    required property var dock
    // The dock's profile folders (DockData.profileFor).
    property var folders: []
    screen: dock.modelData

    readonly property var pop: DockData.openStack
    readonly property bool shown: pop !== null && pop.screen === dock.modelData.name
    readonly property var folder: shown ? (folders[pop.index] ?? null) : null
    readonly property var source: folder ? DockData.folder(folder.path) : null
    readonly property var items: source?.items ?? []
    readonly property string title: source?.listing?.name || (folder?.path ?? "")
    readonly property string view: {
        const v = folder?.view ?? "auto";
        if (v !== "auto")
            return v === "fan" && pop?.edge !== "bottom" ? "grid" : v;
        return pop?.edge === "bottom" && items.length <= 10 ? "fan" : "grid";
    }

    visible: shown
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:dock-stack"
    WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    // While an item is dragged, only the popup's own content takes input,
    // so the drag can land on the dock (the Trash, an app) or any window.
    property bool dragging: false
    mask: Region {
        item: root.dragging ? (root.view === "fan" ? fanBox : panel) : full
    }
    // Roughly where the fan is drawn.
    Item {
        id: fanBox
        readonly property int n: Math.min(10, root.items.length)
        x: root.ax - 400
        y: root.ay - (n + 1) * 62 - 10
        width: 480
        height: (n + 1) * 62 + 10
    }
    Item {
        id: full
        anchors.fill: parent
    }

    function close() {
        DockData.openStack = null;
    }

    function open(item) {
        close();
        DockData.openFile(item.path);
    }

    function openFolder() {
        close();
        DockData.openFile(source?.path || folder?.path || "");
    }

    function uri(path) {
        return "file://" + path.split("/").map(encodeURIComponent).join("/");
    }

    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur && shown && root.view !== "fan" ? panel : null
        radius: panel.radius
    }

    // Anywhere else closes.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.close()
    }

    Item {
        anchors.fill: parent
        focus: root.shown
        Keys.onEscapePressed: root.close()
    }

    // Where the popup attaches: the stack's outward edge.
    readonly property real ax: pop?.x ?? 0
    readonly property real ay: pop?.y ?? 0

    // One draggable entry: drag starts a system drag-and-drop with the file.
    component Draggable: MouseArea {
        id: dm
        required property var entry
        property Item proxy
        hoverEnabled: true
        drag.target: proxy
        cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.PointingHandCursor
        drag.onActiveChanged: root.dragging = drag.active
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: m => {
            if (m.button !== Qt.RightButton) {
                root.open(entry);
                return;
            }
            // The item's menu (Open, Show in Files, Quick Actions ▸) at the pointer.
            // (Closing destroys this delegate: take everything first.)
            const p = dm.mapToItem(root.contentItem, m.x, m.y);
            const path = entry.path;
            const screen = root.screen.name;
            root.close();
            DockMenu.openStackItem(screen, p.x, p.y, path);
        }
        onReleased: {
            if (proxy) {
                proxy.x = 0;
                proxy.y = 0;
            }
        }
    }

    component DragProxy: Item {
        required property var entry
        Drag.active: false
        Drag.dragType: Drag.Automatic
        Drag.supportedActions: Qt.CopyAction | Qt.MoveAction | Qt.LinkAction
        Drag.proposedAction: Qt.CopyAction
        Drag.mimeData: ({
                "text/uri-list": root.uri(entry.path) + "\r\n",
                "text/plain": entry.path
            })
        Drag.imageSourceSize: Qt.size(64, 64)
        Drag.keys: ["text/uri-list"]
        // Dropped somewhere (or cancelled): the stack closes, as on macOS.
        Drag.onDragFinished: dropAction => root.close()
        Drag.hotSpot.x: width / 2
        Drag.hotSpot.y: height / 2
    }

    // ── Fan ──────────────────────────────────────────────────────────────
    Item {
        id: fan
        visible: root.shown && root.view === "fan"
        readonly property int rowH: 62
        readonly property var shownItems: root.items.slice(0, 10)

        Repeater {
            model: fan.visible ? fan.shownItems : []

            delegate: Item {
                id: fr
                required property var modelData
                required property int index
                // Curve to the right as it climbs (macOS fans arc).
                readonly property real bend: Math.pow(index / 9, 2) * 70
                width: 420
                height: fan.rowH
                x: root.ax - width + 28 + bend
                y: root.ay - (index + 1) * fan.rowH - 6
                rotation: index * 1.2
                transformOrigin: Item.Right

                GlassSurface {
                    anchors {
                        right: icon.left
                        rightMargin: 8
                        verticalCenter: parent.verticalCenter
                    }
                    width: Math.min(300, name.implicitWidth + 22)
                    height: 26
                    radius: 13
                    strength: fdrag.containsMouse ? 2.4 : 1.8
                    Text {
                        id: name
                        anchors.centerIn: parent
                        width: Math.min(implicitWidth, 278)
                        text: fr.modelData.name
                        elide: Text.ElideMiddle
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.weight: Font.Medium
                    }
                }

                Item {
                    id: icon
                    anchors {
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                    }
                    width: 56
                    height: 56
                    scale: fdrag.containsMouse ? 1.08 : 1
                    Behavior on scale {
                        NumberAnimation {
                            duration: 120
                        }
                    }
                    AppIcon {
                        anchors.fill: parent
                        sources: DockData.fileIcons(fr.modelData)
                    }
                    DragProxy {
                        id: fproxy
                        entry: fr.modelData
                        width: 56
                        height: 56
                        Drag.active: fdrag.drag.active
                        Drag.imageSource: fr.modelData.thumb ? "file://" + fr.modelData.thumb : ""
                    }
                }

                Draggable {
                    id: fdrag
                    anchors.fill: parent
                    entry: fr.modelData
                    proxy: fproxy
                }
            }
        }

        // The top of the fan: open the folder.
        GlassSurface {
            visible: fan.visible
            readonly property int n: fan.shownItems.length
            width: openLabel.implicitWidth + 30
            height: 28
            radius: 14
            strength: openMouse.containsMouse ? 2.4 : 1.8
            x: root.ax - width / 2 + Math.pow(Math.max(0, n) / 9, 2) * 70
            y: root.ay - (n + 1) * fan.rowH + 10
            Text {
                id: openLabel
                anchors.centerIn: parent
                text: root.items.length > fan.shownItems.length ? `${root.items.length - fan.shownItems.length} more in Files ›` : "Open in Files ›"
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 12
                font.weight: Font.Medium
            }
            MouseArea {
                id: openMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openFolder()
            }
        }
    }

    // ── Grid / List: a glass panel ───────────────────────────────────────
    GlassSurface {
        id: panel
        visible: root.shown && root.view !== "fan"
        readonly property bool grid: root.view === "grid"
        readonly property int cols: Math.max(1, Math.min(5, root.items.length))
        readonly property int cellW: 104
        readonly property int cellH: 108
        readonly property real contentH: grid ? Math.ceil(root.items.length / cols) * cellH : root.items.length * 30
        readonly property real maxH: (root.height - 120) * 0.7
        width: grid ? Math.max(260, cols * cellW + 24) : 320
        height: Math.min(maxH, Math.max(80, contentH)) + 84
        radius: 18
        strength: 2
        x: {
            const e = root.pop?.edge ?? "bottom";
            const want = e === "left" ? root.ax + 8 : e === "right" ? root.ax - width - 8 : root.ax - width / 2;
            return Math.max(8, Math.min(root.width - width - 8, want));
        }
        y: {
            const e = root.pop?.edge ?? "bottom";
            const want = e === "bottom" ? root.ay - height - 10 : root.ay - height / 2;
            return Math.max(40, Math.min(root.height - height - 8, want));
        }

        // Swallow clicks inside.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
        }

        Text {
            id: head
            anchors {
                top: parent.top
                topMargin: 14
                horizontalCenter: parent.horizontalCenter
            }
            text: root.title
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 15
            font.weight: Font.DemiBold
        }

        Text {
            visible: root.items.length === 0
            anchors.centerIn: parent
            text: "No items"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 13
        }

        GridView {
            id: gridView
            visible: panel.grid
            anchors {
                top: head.bottom
                topMargin: 10
                bottom: footer.top
                bottomMargin: 8
                horizontalCenter: parent.horizontalCenter
            }
            width: panel.cols * panel.cellW
            cellWidth: panel.cellW
            cellHeight: panel.cellH
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: panel.visible && panel.grid ? root.items : []

            delegate: Item {
                id: gcell
                required property var modelData
                width: panel.cellW
                height: panel.cellH

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 3
                    radius: 10
                    color: gdrag.containsMouse ? Theme.withAlpha(Theme.text, 0.1) : "transparent"
                }
                Item {
                    id: gicon
                    anchors {
                        top: parent.top
                        topMargin: 8
                        horizontalCenter: parent.horizontalCenter
                    }
                    width: 64
                    height: 64
                    AppIcon {
                        anchors.fill: parent
                        sources: DockData.fileIcons(gcell.modelData)
                    }
                    DragProxy {
                        id: gproxy
                        entry: gcell.modelData
                        width: 64
                        height: 64
                        Drag.active: gdrag.drag.active
                        Drag.imageSource: gcell.modelData.thumb ? "file://" + gcell.modelData.thumb : ""
                    }
                }
                Text {
                    anchors {
                        top: gicon.bottom
                        topMargin: 4
                        left: parent.left
                        right: parent.right
                        leftMargin: 6
                        rightMargin: 6
                    }
                    horizontalAlignment: Text.AlignHCenter
                    text: gcell.modelData.name
                    // Break between words when there are any ("Reference
                    // Images", not "Reference Image|s").
                    wrapMode: Text.Wrap
                    maximumLineCount: 2
                    elide: Text.ElideRight
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                }
                Draggable {
                    id: gdrag
                    anchors.fill: parent
                    entry: gcell.modelData
                    proxy: gproxy
                }
            }
        }

        ListView {
            id: listView
            visible: !panel.grid
            anchors {
                top: head.bottom
                topMargin: 10
                bottom: footer.top
                bottomMargin: 8
                left: parent.left
                right: parent.right
                leftMargin: 6
                rightMargin: 6
            }
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: panel.visible && !panel.grid ? root.items : []

            delegate: Item {
                id: lc
                required property var modelData
                width: ListView.view.width
                height: 30

                Rectangle {
                    anchors.fill: parent
                    radius: 6
                    color: ldrag.containsMouse ? Theme.accent : "transparent"
                }
                Item {
                    id: licon
                    x: 8
                    anchors.verticalCenter: parent.verticalCenter
                    width: 20
                    height: 20
                    AppIcon {
                        anchors.fill: parent
                        sources: DockData.fileIcons(lc.modelData, false)
                        pixelSize: 40
                    }
                    DragProxy {
                        id: lproxy
                        entry: lc.modelData
                        width: 20
                        height: 20
                        Drag.active: ldrag.drag.active
                    }
                }
                Text {
                    anchors {
                        left: licon.right
                        leftMargin: 8
                        right: parent.right
                        rightMargin: 10
                        verticalCenter: parent.verticalCenter
                    }
                    text: lc.modelData.name
                    elide: Text.ElideMiddle
                    color: ldrag.containsMouse ? Theme.bg : Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                }
                Draggable {
                    id: ldrag
                    anchors.fill: parent
                    entry: lc.modelData
                    proxy: lproxy
                }
            }
        }

        // "Open in Files"
        Rectangle {
            id: footer
            anchors {
                bottom: parent.bottom
                bottomMargin: 12
                horizontalCenter: parent.horizontalCenter
            }
            width: footText.implicitWidth + 26
            height: 26
            radius: 13
            color: footMouse.containsMouse ? Theme.withAlpha(Theme.text, 0.16) : Theme.withAlpha(Theme.text, 0.08)
            Text {
                id: footText
                anchors.centerIn: parent
                text: root.source && root.source.count > root.items.length ? `Open in Files (${root.source.count} items) ›` : "Open in Files ›"
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 12
                font.weight: Font.Medium
            }
            MouseArea {
                id: footMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openFolder()
            }
        }
    }
}
