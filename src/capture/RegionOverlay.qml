import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// Area selection on a frozen frame of one output (Capture.freeze): the
// frame fills the screen, the outside of the selection dims, a pixel loupe
// follows the pointer (with the color under it), and releasing the drag —
// or a click, for the color picker — hands the result to Capture.selected.
// Escape cancels.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property string purpose: Capture.selecting
    readonly property string frame: Capture.frozen[modelData.name] ?? ""
    readonly property bool primary: Capture.selectScreen === modelData.name

    visible: purpose !== "" && frame !== ""
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "studio:capture"
    WlrLayershell.keyboardFocus: visible && primary ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "black"

    // Frame pixels per logical pixel (the output's scale).
    readonly property real ratio: bg.sourceSize.width > 0 ? bg.sourceSize.width / width : 1

    // Pointer, selection (logical, this screen).
    property point cursor: Qt.point(width / 2, height / 2)
    property bool hovering: false
    property bool dragging: false
    property point anchor: Qt.point(0, 0)
    readonly property rect sel: Qt.rect(Math.min(anchor.x, cursor.x), Math.min(anchor.y, cursor.y), Math.abs(cursor.x - anchor.x), Math.abs(cursor.y - anchor.y))
    readonly property bool hasSel: dragging && sel.width >= 2 && sel.height >= 2

    // The frame pixel under the pointer, and its color (from `probe`).
    readonly property point pixel: Qt.point(Math.min(bg.sourceSize.width - 1, Math.floor(cursor.x * ratio)), Math.min(bg.sourceSize.height - 1, Math.floor(cursor.y * ratio)))
    property string hex: ""

    onVisibleChanged: {
        dragging = false;
        hovering = false;
        hex = "";
    }
    onPixelChanged: probe.requestPaint()

    function finish() {
        if (purpose === "color") {
            Capture.selected(modelData, Qt.rect(cursor.x, cursor.y, 1, 1), Qt.rect(pixel.x, pixel.y, 1, 1), hex);
            return;
        }
        const r = sel;
        dragging = false;
        if (r.width < 4 || r.height < 4)
            return;
        const px = Qt.rect(Math.round(r.x * ratio), Math.round(r.y * ratio), Math.round(r.width * ratio), Math.round(r.height * ratio));
        Capture.selected(modelData, r, px, "");
    }

    Item {
        anchors.fill: parent
        focus: root.visible && root.primary
        Keys.onEscapePressed: Capture.cancel()

        Image {
            id: bg
            anchors.fill: parent
            source: root.frame !== "" ? "file://" + root.frame : ""
            fillMode: Image.Stretch
            smooth: false
            cache: false
        }

        // Dim everything but the selection.
        Item {
            anchors.fill: parent
            readonly property color shade: Qt.rgba(0, 0, 0, root.purpose === "color" ? 0 : 0.32)

            Rectangle {
                visible: !root.hasSel
                anchors.fill: parent
                color: parent.shade
            }
            Rectangle {
                visible: root.hasSel
                x: 0
                y: 0
                width: parent.width
                height: root.sel.y
                color: parent.shade
            }
            Rectangle {
                visible: root.hasSel
                x: 0
                y: root.sel.y + root.sel.height
                width: parent.width
                height: parent.height - y
                color: parent.shade
            }
            Rectangle {
                visible: root.hasSel
                x: 0
                y: root.sel.y
                width: root.sel.x
                height: root.sel.height
                color: parent.shade
            }
            Rectangle {
                visible: root.hasSel
                x: root.sel.x + root.sel.width
                y: root.sel.y
                width: parent.width - x
                height: root.sel.height
                color: parent.shade
            }
        }

        // Selection outline.
        Rectangle {
            visible: root.hasSel
            x: root.sel.x - 1
            y: root.sel.y - 1
            width: root.sel.width + 2
            height: root.sel.height + 2
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(0, 0, 0, 0.5)

            Rectangle {
                anchors.fill: parent
                anchors.margins: 1
                color: "transparent"
                border.width: 1
                border.color: "white"
            }
        }

        // Crosshair guides before the drag starts.
        Rectangle {
            visible: root.hovering && !root.dragging && root.purpose !== "color"
            x: 0
            y: Math.round(root.cursor.y)
            width: parent.width
            height: 1
            color: Qt.rgba(1, 1, 1, 0.35)
        }
        Rectangle {
            visible: root.hovering && !root.dragging && root.purpose !== "color"
            x: Math.round(root.cursor.x)
            y: 0
            width: 1
            height: parent.height
            color: Qt.rgba(1, 1, 1, 0.35)
        }

        // Size of the selection, under it (above when there's no room).
        Rectangle {
            visible: root.hasSel
            readonly property bool below: root.sel.y + root.sel.height + height + 12 < parent.height
            x: Math.max(8, Math.min(parent.width - width - 8, root.sel.x + root.sel.width / 2 - width / 2))
            y: below ? root.sel.y + root.sel.height + 10 : root.sel.y - height - 10
            width: sizeText.implicitWidth + 18
            height: 24
            radius: 12
            color: Qt.rgba(0, 0, 0, 0.6)

            Text {
                id: sizeText
                anchors.centerIn: parent
                text: `${Math.round(root.sel.width * root.ratio)} × ${Math.round(root.sel.height * root.ratio)}`
                color: "white"
                font.family: Theme.fontUi
                font.pixelSize: 12
                font.weight: Font.DemiBold
                font.features: {
                    "tnum": 1
                }
            }
        }

        // What to do, at the top.
        GlassSurface {
            visible: root.primary && !root.dragging
            anchors {
                top: parent.top
                horizontalCenter: parent.horizontalCenter
                topMargin: 56
            }
            width: hint.implicitWidth + 32
            height: 34
            radius: 17
            strength: 2

            Text {
                id: hint
                anchors.centerIn: parent
                text: {
                    switch (root.purpose) {
                    case "color":
                        return "Click to pick a color  ·  Esc to cancel";
                    case "text":
                        return "Select text or a QR code to copy  ·  Esc to cancel";
                    case "record":
                        return "Drag to choose the area to record  ·  Esc to cancel";
                    default:
                        return "Drag to capture an area  ·  Esc to cancel";
                    }
                }
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.weight: Font.Medium
            }
        }

        // ── Loupe ───────────────────────────────────────────────────────
        Item {
            id: loupe
            readonly property int cells: 15
            readonly property int cell: 9
            readonly property int size: cells * cell
            readonly property bool flipX: root.cursor.x + 28 + size > parent.width
            readonly property bool flipY: root.cursor.y + 28 + size + 34 > parent.height

            visible: root.hovering && (root.purpose === "color" || !root.dragging || root.hasSel)
            x: flipX ? root.cursor.x - 28 - size : root.cursor.x + 28
            y: flipY ? root.cursor.y - 28 - size - 34 : root.cursor.y + 28
            width: size
            height: size + 34

            RoundedClip {
                id: lens
                width: loupe.size
                height: loupe.size
                radius: loupe.size / 2

                // The frame, scaled up without smoothing: one cell per pixel.
                Image {
                    source: bg.source
                    smooth: false
                    mipmap: false
                    cache: false
                    width: bg.sourceSize.width * loupe.cell
                    height: bg.sourceSize.height * loupe.cell
                    x: -(root.pixel.x - (loupe.cells - 1) / 2) * loupe.cell
                    y: -(root.pixel.y - (loupe.cells - 1) / 2) * loupe.cell
                }

                // The picked pixel.
                Rectangle {
                    x: (loupe.cells - 1) / 2 * loupe.cell - 1
                    y: x
                    width: loupe.cell + 2
                    height: loupe.cell + 2
                    color: "transparent"
                    border.width: 1
                    border.color: "white"

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -1
                        color: "transparent"
                        border.width: 1
                        border.color: Qt.rgba(0, 0, 0, 0.6)
                    }
                }
            }

            Rectangle {
                width: loupe.size
                height: loupe.size
                radius: loupe.size / 2
                color: "transparent"
                border.width: 3
                border.color: Theme.withAlpha(Theme.text, 0.85)
            }

            Rectangle {
                anchors {
                    horizontalCenter: parent.horizontalCenter
                    bottom: parent.bottom
                }
                width: readout.implicitWidth + 30
                height: 26
                radius: 13
                color: Qt.rgba(0, 0, 0, 0.7)

                Row {
                    id: readout
                    anchors.centerIn: parent
                    spacing: 6

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 12
                        height: 12
                        radius: 3
                        color: root.hex || "transparent"
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.5)
                    }
                    Text {
                        text: root.purpose === "color" ? Capture.formatColor(root.hex || "#000000", Capture.cfg.colorFormat) : `${root.pixel.x}, ${root.pixel.y}`
                        color: "white"
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        font.features: {
                            "tnum": 1
                        }
                    }
                }
            }
        }

        // Reads the color of the pixel under the pointer from the frame.
        Canvas {
            id: probe
            width: 1
            height: 1
            readonly property string url: bg.source.toString()
            onUrlChanged: if (url !== "")
                loadImage(url)
            onImageLoaded: requestPaint()
            onPaint: {
                if (url === "" || !isImageLoaded(url))
                    return;
                const ctx = getContext("2d");
                ctx.clearRect(0, 0, 1, 1);
                ctx.drawImage(url, root.pixel.x, root.pixel.y, 1, 1, 0, 0, 1, 1);
                const d = ctx.getImageData(0, 0, 1, 1).data;
                const h = n => n.toString(16).padStart(2, "0");
                root.hex = `#${h(d[0])}${h(d[1])}${h(d[2])}`;
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.CrossCursor
            onEntered: root.hovering = true
            onExited: root.hovering = false
            onPositionChanged: mouse => {
                root.hovering = true;
                root.cursor = Qt.point(mouse.x, mouse.y);
            }
            onPressed: mouse => {
                if (mouse.button === Qt.RightButton) {
                    Capture.cancel();
                    return;
                }
                root.cursor = Qt.point(mouse.x, mouse.y);
                root.anchor = root.cursor;
                root.dragging = root.purpose !== "color";
            }
            onReleased: root.finish()
            acceptedButtons: Qt.LeftButton | Qt.RightButton
        }
    }

    // Tests (Capture IPC testHover / testSelect / testPick).
    Connections {
        target: Capture
        enabled: root.visible && root.primary
        function onTestRequested(what) {
            root.hovering = true;
            if (what === "hover") {
                root.cursor = Qt.point(409.5, 238.5);
            } else if (what === "pick") {
                root.cursor = Qt.point(409.5, 238.5);
                pickLater.restart();
            } else if (what === "select") {
                root.anchor = Qt.point(100, 100);
                root.cursor = Qt.point(660, 500);
                root.dragging = true;
                selectLater.restart();
            }
        }
    }
    Timer {
        id: pickLater
        interval: 300
        onTriggered: root.finish()
    }
    Timer {
        id: selectLater
        interval: 600
        onTriggered: root.finish()
    }
}
