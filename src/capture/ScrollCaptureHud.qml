import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// Scrolling capture in progress (Capture.scrolling): the area stays clear
// and outlined while the rest of the screen dims; beside it a glass strip
// shows the stitched image growing as you scroll, and a pill under it says
// how tall it is, with Auto / Cancel / Done. Only the strip and the pill take
// input — the area itself (and everything else) stays usable, so you scroll
// the app as usual. Nothing of the HUD sits inside the area, so none of it
// ends up in the frames.
//
// Auto Scroll (Capture.scrollAuto): once the helper has put the pointer in
// the middle of the area, the HUD takes input everywhere except a small hole
// under the pointer — the wheel notches go through the hole to the app, and
// the moment the real mouse moves the pointer out of it the guard sees it
// and stops Auto Scroll. The HUD also holds the keyboard meanwhile, so any
// key stops it (Return: Done).
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property var job: Capture.scrolling
    readonly property rect area: job?.rect ?? Qt.rect(0, 0, 0, 0)
    readonly property bool autoOn: Capture.scrollAuto === "starting" || Capture.scrollAuto === "running"
    // The pointer is in place: guard everything but the hole under it.
    readonly property bool guarding: visible && Capture.scrollAuto === "running"
    readonly property int holeSize: 24

    visible: job !== null && job.screen === modelData.name
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:capture-scroll"
    WlrLayershell.keyboardFocus: !visible ? WlrKeyboardFocus.None : autoOn ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    mask: guarding ? guardMask : handsMask
    Region {
        id: handsMask
        item: pill
        Region {
            item: strip.visible ? strip : null
        }
    }
    Region {
        id: guardMask
        item: everything
        Region {
            item: hole
            intersection: Intersection.Subtract
        }
    }
    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur ? pill : null
        radius: pill.radius
        Region {
            item: Theme.blur && strip.visible ? strip : null
            radius: strip.radius
        }
    }

    // ── Layout ──────────────────────────────────────────────────────────
    readonly property int gap: 14
    readonly property int stripWidth: 150
    // Which side has room for the preview strip: right, left or none.
    readonly property string side: width - (area.x + area.width) >= stripWidth + 2 * gap ? "right" : area.x >= stripWidth + 2 * gap ? "left" : "none"
    // The pill: under the area, above it, in the strip's column, or (no room
    // anywhere) inside the area's bottom edge.
    readonly property string pillAt: height - (area.y + area.height) >= pill.height + 2 * gap ? "below" : area.y >= pill.height + 2 * gap ? "above" : side !== "none" ? "side" : "inside"

    // Where the helper puts the pointer: the middle of the area (the same
    // rounding as `loft capture scroll`'s area_center).
    Item {
        id: hole
        x: root.area.x + Math.floor(root.area.width / 2) - root.holeSize / 2
        y: root.area.y + Math.floor(root.area.height / 2) - root.holeSize / 2
        width: root.holeSize
        height: root.holeSize
    }

    // Dim everything but the area (visual only; in the input mask only
    // while guarding Auto Scroll).
    Item {
        id: everything
        anchors.fill: parent
        readonly property color shade: Qt.rgba(0, 0, 0, 0.28)
        Rectangle {
            x: 0
            y: 0
            width: parent.width
            height: root.area.y
            color: parent.shade
        }
        Rectangle {
            x: 0
            y: root.area.y + root.area.height
            width: parent.width
            height: parent.height - y
            color: parent.shade
        }
        Rectangle {
            x: 0
            y: root.area.y
            width: root.area.x
            height: root.area.height
            color: parent.shade
        }
        Rectangle {
            x: root.area.x + root.area.width
            y: root.area.y
            width: parent.width - x
            height: root.area.height
            color: parent.shade
        }
    }

    // Outline just outside the area (so the frames never contain it).
    Rectangle {
        x: root.area.x - 2
        y: root.area.y - 2
        width: root.area.width + 4
        height: root.area.height + 4
        radius: 3
        color: "transparent"
        border.width: 2
        border.color: Theme.accent
    }

    // ── Live preview ────────────────────────────────────────────────────
    GlassSurface {
        id: strip
        visible: root.side !== "none"
        x: root.side === "right" ? root.area.x + root.area.width + root.gap : root.area.x - root.gap - width
        y: Math.max(root.gap, Math.min(root.height - height - root.gap, root.area.y + (root.pillAt === "side" ? pill.height + 10 : 0)))
        width: root.stripWidth
        height: Math.max(120, Math.min(root.area.height - (root.pillAt === "side" ? pill.height + 10 : 0), root.height - 2 * root.gap))
        radius: 14
        strength: 1.8

        RoundedClip {
            id: viewport
            anchors {
                fill: parent
                margins: 8
            }
            radius: 8

            Rectangle {
                anchors.fill: parent
                color: Theme.withAlpha(Theme.bg, 0.5)
            }

            // The stitched image at strip width; it slides up so the newest
            // rows stay in view.
            Item {
                id: canvas
                readonly property real k: Capture.scrollWidth > 0 ? viewport.width / Capture.scrollWidth : 0
                width: viewport.width
                height: Capture.scrollHeight * k
                y: Math.min(0, viewport.height - height)
                Behavior on y {
                    NumberAnimation {
                        duration: 180
                        easing.type: Easing.OutCubic
                    }
                }

                Repeater {
                    model: Capture.scrollSegments
                    delegate: Item {
                        required property var modelData
                        x: 0
                        y: modelData.y * canvas.k
                        width: canvas.width
                        height: Math.ceil(modelData.h * canvas.k)
                        clip: true

                        Image {
                            y: -parent.modelData.sy * canvas.k
                            width: canvas.width
                            height: Capture.scrollFrameHeight * canvas.k
                            source: "file://" + parent.modelData.path
                            sourceSize.width: Math.round(canvas.width * 2)
                            fillMode: Image.Stretch
                            asynchronous: true
                            smooth: true
                        }
                    }
                }
            }

            Text {
                visible: Capture.scrollFrames <= 1
                anchors.centerIn: parent
                width: parent.width - 16
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: "Scroll the area — new rows appear here"
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                style: Text.Outline
                styleColor: Theme.withAlpha(Theme.bg, 0.6)
            }
        }
    }

    // ── Done / Cancel ───────────────────────────────────────────────────
    component PillButton: Rectangle {
        id: btn
        property string text
        property bool primary: false
        signal clicked
        implicitWidth: label.implicitWidth + 26
        implicitHeight: 28
        radius: 14
        color: primary ? (mouse.containsMouse ? Qt.lighter(Theme.accent, 1.1) : Theme.accent) : mouse.containsMouse ? Theme.withAlpha(Theme.text, 0.16) : Theme.withAlpha(Theme.text, 0.09)

        Text {
            id: label
            anchors.centerIn: parent
            text: btn.text
            color: btn.primary ? Theme.bg : Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 12
            font.weight: btn.primary ? Font.DemiBold : Font.Medium
        }
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }

    GlassSurface {
        id: pill
        width: pillRow.implicitWidth + 24
        height: 44
        radius: 22
        strength: 1.8
        x: {
            if (root.pillAt === "side")
                return root.side === "right" ? strip.x : Math.max(root.gap, strip.x + strip.width - width);
            return Math.max(root.gap, Math.min(root.width - width - root.gap, root.area.x + root.area.width / 2 - width / 2));
        }
        y: {
            switch (root.pillAt) {
            case "below":
                return root.area.y + root.area.height + root.gap;
            case "above":
                return root.area.y - root.gap - height;
            case "side":
                return Math.max(root.gap, root.area.y);
            default:
                return root.area.y + root.area.height - height - root.gap;
            }
        }

        focus: root.visible
        // Return / Enter: Done. While Auto Scroll runs any other key (Esc
        // too) only stops it; otherwise Esc cancels.
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                Capture.scrollDone();
            else if (root.autoOn)
                Capture.scrollAutoStop(false);
            else if (event.key === Qt.Key_Escape)
                Capture.scrollCancel();
            else
                return;
            event.accepted = true;
        }

        RowLayout {
            id: pillRow
            anchors.centerIn: parent
            spacing: 10

            Icon {
                text: "󰡏"
                size: 16
                color: Theme.accent
            }
            ColumnLayout {
                spacing: 0
                Text {
                    readonly property string tall: `${Capture.scrollHeight.toLocaleString(Qt.locale(), "f", 0)} px`
                    text: {
                        if (Capture.scrollFinishing)
                            return "Stitching…";
                        if (root.autoOn || Capture.scrollAuto === "stopping")
                            return Capture.scrollFrames <= 1 ? "Auto Scrolling…" : `Auto Scrolling · ${tall}`;
                        if (Capture.scrollFrames <= 1)
                            return "Scroll to capture";
                        return `${tall} tall`;
                    }
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    font.features: {
                        "tnum": 1
                    }
                }
                Text {
                    readonly property var why: ({
                            end: "Reached the end",
                            pointer: "Stopped: the mouse moved",
                            stop: "Auto Scroll stopped",
                            timeout: "Auto Scroll timed out",
                            limit: "Reached the height limit",
                            error: "Auto Scroll failed",
                            unavailable: "Auto Scroll unavailable"
                        })
                    text: root.autoOn ? "Move the mouse or press a key to stop" : Capture.scrollAuto === "" ? (why[Capture.scrollAutoReason] ?? "") : ""
                    visible: text !== "" && !Capture.scrollFinishing
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 10
                }
            }
            Item {
                Layout.preferredWidth: 4
            }
            PillButton {
                id: autoButton
                // Auto ⇄ Stop. Stop is for the record (and IPC): reaching
                // for it with the mouse already stops Auto Scroll.
                text: root.autoOn || Capture.scrollAuto === "stopping" ? "Stop" : "Auto"
                visible: !Capture.scrollFinishing
                opacity: Capture.scrollAutoCooling || Capture.scrollAuto === "stopping" ? 0.5 : 1
                onClicked: {
                    if (root.autoOn) {
                        Capture.scrollAutoStop(false);
                        return;
                    }
                    const p = autoButton.mapToItem(null, autoButton.width / 2, autoButton.height / 2);
                    Capture.scrollAutoStart(root.modelData.x + p.x, root.modelData.y + p.y);
                }
            }
            PillButton {
                text: "Cancel"
                onClicked: Capture.scrollCancel()
            }
            PillButton {
                text: "Done"
                primary: true
                opacity: Capture.scrollFinishing ? 0.5 : 1
                onClicked: Capture.scrollDone()
            }
        }
    }

    // ── Auto Scroll guard ───────────────────────────────────────────────
    // Over everything (the input mask leaves only the hole): the real mouse
    // moving the pointer out of the hole, or any click / wheel on the HUD,
    // stops Auto Scroll and leaves the pointer where the user put it.
    MouseArea {
        anchors.fill: parent
        z: 100
        enabled: root.guarding
        hoverEnabled: true
        acceptedButtons: Qt.AllButtons
        onEntered: Capture.scrollAutoStop(true)
        onPositionChanged: Capture.scrollAutoStop(true)
        onPressed: Capture.scrollAutoStop(true)
        onWheel: Capture.scrollAutoStop(true)
    }
}
