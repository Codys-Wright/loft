import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// Scrolling capture in progress (Capture.scrolling): the area stays clear
// and outlined while the rest of the screen dims; beside it a glass strip
// shows the stitched image growing as you scroll, and a pill under it says
// how tall it is, with Cancel / Done. Only the strip and the pill take
// input — the area itself (and everything else) stays usable, so you scroll
// the app as usual. Nothing of the HUD sits inside the area, so none of it
// ends up in the frames.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property var job: Capture.scrolling
    readonly property rect area: job?.rect ?? Qt.rect(0, 0, 0, 0)

    visible: job !== null && job.screen === modelData.name
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:capture-scroll"
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    mask: Region {
        item: pill
        Region {
            item: strip.visible ? strip : null
        }
    }
    BackgroundEffect.blurRegion: Theme.blur ? blur : null
    Region {
        id: blur
        item: pill
        radius: pill.radius
        Region {
            item: strip.visible ? strip : null
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

    // Dim everything but the area (visual only; not in the input mask).
    Item {
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
        Keys.onEscapePressed: Capture.scrollCancel()
        Keys.onReturnPressed: Capture.scrollDone()
        Keys.onEnterPressed: Capture.scrollDone()

        RowLayout {
            id: pillRow
            anchors.centerIn: parent
            spacing: 10

            Icon {
                text: "󰡏"
                size: 16
                color: Theme.accent
            }
            Text {
                text: {
                    if (Capture.scrollFinishing)
                        return "Stitching…";
                    if (Capture.scrollFrames <= 1)
                        return "Scroll to capture";
                    return `${Capture.scrollHeight.toLocaleString(Qt.locale(), "f", 0)} px tall`;
                }
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.weight: Font.Medium
                font.features: {
                    "tnum": 1
                }
            }
            Item {
                Layout.preferredWidth: 4
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
}
