import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services
import qs.menubar

// The dock's window preview (macOS / vorssaint "Dock Preview"): a Liquid
// Glass popover beside a running app's icon with a card per window — a
// snapshot where one exists (Previews / WindowThumbs), else the app icon in
// the window's shape — its title, and where it is (desktop, display, or
// hidden on the parking workspace). Click a card to focus that window
// anywhere (a hidden one comes back first), × closes it, ⋯ or a right-click
// gives Move to Desktop ▸ / Display ▸ / Hide; middle-click closes too.
// The dock opens and closes it (Dock.qml): the pointer may travel from the
// icon into the popover, and leaving both closes it.
PanelWindow {
    id: root

    required property var dock
    screen: dock.modelData

    readonly property bool shown: Previews.current !== null && Previews.current.screen === dock.modelData.name
    // What's on show; kept while the popover fades out.
    property var spec: null
    onShownChanged: if (shown)
        spec = Previews.current
    Connections {
        target: Previews
        function onCurrentChanged() {
            if (root.shown)
                root.spec = Previews.current;
        }
    }

    readonly property string appId: spec?.appId ?? ""
    readonly property string edge: spec?.edge ?? "bottom"
    readonly property bool vertical: edge !== "bottom"
    readonly property var windows: appId !== "" ? DockData.windowsOf(appId) : []
    // The last window closed: nothing left to show.
    onWindowsChanged: if (shown && windows.length === 0)
        Previews.close()

    // 0 = closed, 1 = open; opening and closing share the dock's curve.
    property real progress: shown ? 1 : 0
    Behavior on progress {
        NumberAnimation {
            duration: 200
            easing.type: Easing.OutCubic
        }
    }

    visible: shown || progress > 0.01
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:dock-preview"
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    // Only the popover takes input, and only while open.
    mask: Region {
        item: root.shown ? panel : nothing
    }
    Item {
        id: nothing
    }

    BackgroundEffect.blurRegion: Theme.blur && root.visible ? blur : null
    Region {
        id: blur
        item: panel
        radius: panel.radius
    }

    // ── Layout ───────────────────────────────────────────────────────────
    readonly property int cardW: 212
    readonly property int thumbW: 196
    readonly property int thumbH: 124
    readonly property int cardH: thumbH + 58
    readonly property int gap: 6
    readonly property int count: windows.length
    readonly property int cols: {
        if (count === 0)
            return 1;
        if (!vertical)
            return Math.max(1, Math.min(count, Math.floor((width - 64) / (cardW + gap))));
        const rows = Math.max(1, Math.floor((height - 140) / (cardH + gap)));
        return Math.ceil(count / rows);
    }
    readonly property int rows: Math.max(1, Math.ceil(count / cols))

    readonly property real ax: spec?.x ?? 0
    readonly property real ay: spec?.y ?? 0

    GlassSurface {
        id: panel
        readonly property real slide: (1 - root.progress) * 10
        // While the pointer is on it, closing a card doesn't shrink it out
        // from under the pointer.
        property real holdW: 0
        property real holdH: 0
        width: Math.max(grid.width + 24, holdW)
        height: Math.max(head.height + grid.height + 34, holdH)
        radius: 20
        strength: 2
        x: {
            const want = root.edge === "left" ? root.ax + 10 - slide : root.edge === "right" ? root.ax - width - 10 + slide : root.ax - width / 2;
            return Math.max(8, Math.min(root.width - width - 8, want));
        }
        y: {
            const want = root.edge === "bottom" ? root.ay - height - 10 + slide : root.ay - height / 2;
            return Math.max(40, Math.min(root.height - height - 8, want));
        }
        opacity: root.progress
        scale: 0.94 + 0.06 * root.progress
        transformOrigin: root.edge === "left" ? Item.Left : root.edge === "right" ? Item.Right : Item.Bottom

        HoverHandler {
            id: hover
            onHoveredChanged: {
                Previews.hovered = hovered && root.shown;
                panel.holdW = hovered ? panel.width : 0;
                panel.holdH = hovered ? panel.height : 0;
            }
        }

        // Header: the app.
        Item {
            id: head
            x: 16
            y: 12
            width: panel.width - 32
            height: 22

            AppIcon {
                id: headIcon
                width: 18
                height: 18
                anchors.verticalCenter: parent.verticalCenter
                appId: root.appId
                pixelSize: 36
            }
            Text {
                anchors {
                    left: headIcon.right
                    leftMargin: 8
                    right: countText.left
                    rightMargin: 8
                    verticalCenter: parent.verticalCenter
                }
                text: root.appId !== "" ? Apps.name(root.appId) : ""
                elide: Text.ElideRight
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.weight: Font.DemiBold
            }
            Text {
                id: countText
                anchors {
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                }
                text: root.count === 1 ? "1 window" : `${root.count} windows`
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
            }
        }

        Grid {
            id: grid
            x: 12
            y: head.y + head.height + 10
            columns: root.vertical ? -1 : root.cols
            flow: root.vertical ? Grid.TopToBottom : Grid.LeftToRight
            rows: root.vertical ? root.rows : -1
            spacing: root.gap

            Repeater {
                model: ScriptModel {
                    values: root.windows.map(w => w.id)
                }

                delegate: Card {}
            }
        }
    }

    // Where a window is, in words.
    function where(w) {
        if (Previews.isParked(w))
            return "Hidden";
        const ws = Niri.workspaceMap[w.workspace_id];
        if (!ws)
            return "";
        let s = DockData.wsName(ws);
        if (Quickshell.screens.length > 1 && ws.output) {
            const scr = Quickshell.screens.find(x => x.name === ws.output);
            s += " · " + (scr ? (Displays.models[scr.name] ?? scr.name) : ws.output);
        }
        return s;
    }

    function act(fn) {
        Previews.close();
        fn();
    }

    // A point of `item` in screen coordinates (this window covers the screen).
    function menuAt(item, x, y, id) {
        const p = item.mapToItem(root.contentItem, x, y);
        const name = dock.modelData.name;
        const e = root.edge;
        Previews.close();
        DockMenu.openWindow(name, p.x, p.y, e, id);
    }

    // ── A window card ────────────────────────────────────────────────────
    component Card: Item {
        id: card
        required property int modelData
        readonly property var win: Niri.windowMap[modelData] ?? null
        readonly property bool parked: win ? Previews.isParked(win) : false
        readonly property string thumb: Previews.thumb(modelData)
        readonly property bool hot: cardMouse.containsMouse || closeMouse.containsMouse || moreMouse.containsMouse
        // The window's shape, fitted into the thumbnail box.
        readonly property var size: win?.layout?.window_size ?? [16, 10]
        readonly property real fit: Math.min(root.thumbW / Math.max(1, size[0]), root.thumbH / Math.max(1, size[1]))
        width: root.cardW
        height: root.cardH

        Rectangle {
            anchors.fill: parent
            radius: 14
            color: card.hot ? Theme.withAlpha(Theme.text, 0.1) : "transparent"
            Behavior on color {
                ColorAnimation {
                    duration: 120
                }
            }
        }

        MouseArea {
            id: cardMouse
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            cursorShape: Qt.PointingHandCursor
            onClicked: m => {
                const w = card.win;
                if (!w)
                    return;
                if (m.button === Qt.RightButton)
                    root.menuAt(cardMouse, m.x, m.y, w.id);
                else if (m.button === Qt.MiddleButton)
                    DockMenu.closeWindow(w);
                else
                    root.act(() => DockMenu.focus(w));
            }
        }

        // The thumbnail box; the frame inside has the window's proportions.
        Item {
            id: box
            x: (card.width - root.thumbW) / 2
            y: 8
            width: root.thumbW
            height: root.thumbH

            Item {
                id: frame
                anchors.centerIn: parent
                width: card.thumb !== "" ? root.thumbW : Math.max(72, card.size[0] * card.fit)
                height: card.thumb !== "" ? root.thumbH : Math.max(48, card.size[1] * card.fit)
                opacity: card.parked ? 0.55 : 1

                Rectangle {
                    anchors.fill: parent
                    visible: card.thumb === ""
                    radius: 10
                    color: Theme.withAlpha(Theme.text, 0.08)
                    border.width: 1
                    border.color: Theme.withAlpha(Theme.text, 0.12)
                    AppIcon {
                        anchors.centerIn: parent
                        width: Math.min(56, parent.height * 0.6)
                        height: width
                        appId: card.win?.app_id ?? root.appId
                    }
                }

                Image {
                    id: shot
                    anchors.fill: parent
                    visible: false
                    source: card.thumb
                    fillMode: Image.PreserveAspectFit
                    asynchronous: false
                    smooth: true
                    mipmap: true
                }
                // Rounded corners for the snapshot.
                Rectangle {
                    id: shotMask
                    width: shot.paintedWidth
                    height: shot.paintedHeight
                    anchors.centerIn: parent
                    radius: 8
                    visible: false
                    layer.enabled: true
                }
                MultiEffect {
                    visible: card.thumb !== "" && shot.status === Image.Ready
                    source: shot
                    anchors.fill: shot
                    maskEnabled: true
                    maskSource: shotMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1
                }
                // Focused window: an accent ring.
                Rectangle {
                    visible: card.win?.is_focused ?? false
                    anchors.centerIn: parent
                    width: (card.thumb !== "" ? shot.paintedWidth : parent.width) + 6
                    height: (card.thumb !== "" ? shot.paintedHeight : parent.height) + 6
                    radius: 11
                    color: "transparent"
                    border.width: 2
                    border.color: Theme.accent
                }
            }

            // Hidden: a pill on the frame.
            Rectangle {
                visible: card.parked
                anchors {
                    bottom: parent.bottom
                    bottomMargin: 6
                    horizontalCenter: parent.horizontalCenter
                }
                width: hiddenText.implicitWidth + 16
                height: 20
                radius: 10
                color: Theme.withAlpha(Theme.bg, 0.8)
                Text {
                    id: hiddenText
                    anchors.centerIn: parent
                    text: "Hidden"
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    font.weight: Font.Medium
                }
            }

            // × close, ⋯ more — on hover.
            Rectangle {
                id: closeBtn
                x: frame.x - 7
                y: frame.y - 7
                width: 20
                height: 20
                radius: 10
                visible: card.hot
                color: closeMouse.containsMouse ? Theme.trafficClose : Theme.withAlpha(Theme.bg, 0.85)
                border.width: 1
                border.color: Theme.withAlpha(Theme.text, 0.2)
                Icon {
                    anchors.centerIn: parent
                    text: "󰅖"
                    size: 12
                    color: closeMouse.containsMouse ? "#4d0000" : Theme.text
                }
                MouseArea {
                    id: closeMouse
                    anchors.fill: parent
                    anchors.margins: -3
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (card.win)
                        DockMenu.closeWindow(card.win)
                }
            }
            Rectangle {
                x: frame.x + frame.width - width + 7
                y: frame.y - 7
                width: 22
                height: 20
                radius: 10
                visible: card.hot
                color: moreMouse.containsMouse ? Theme.withAlpha(Theme.accent, 0.9) : Theme.withAlpha(Theme.bg, 0.85)
                border.width: 1
                border.color: Theme.withAlpha(Theme.text, 0.2)
                Icon {
                    anchors.centerIn: parent
                    text: "󰇘"
                    size: 13
                    color: Theme.text
                }
                MouseArea {
                    id: moreMouse
                    anchors.fill: parent
                    anchors.margins: -3
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: m => {
                        if (card.win)
                            root.menuAt(moreMouse, moreMouse.width / 2, root.edge === "bottom" ? 0 : moreMouse.height / 2, card.win.id);
                    }
                }
            }
        }

        Text {
            id: title
            anchors {
                top: box.bottom
                topMargin: 8
                left: parent.left
                right: parent.right
                leftMargin: 10
                rightMargin: 10
            }
            horizontalAlignment: Text.AlignHCenter
            text: card.win ? (card.win.title || Apps.name(card.win.app_id)) : ""
            elide: Text.ElideRight
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 12
            font.weight: Font.Medium
        }
        Text {
            anchors {
                top: title.bottom
                topMargin: 2
                left: parent.left
                right: parent.right
                leftMargin: 10
                rightMargin: 10
            }
            horizontalAlignment: Text.AlignHCenter
            text: card.win ? root.where(card.win) : ""
            elide: Text.ElideRight
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
    }
}
