import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// A capture pinned above everything (layer shell, so it stays on top of
// every window): drag to move, scroll to resize, double-click to annotate,
// hover for close. One per Capture.pins entry (shell.qml Variants).
PanelWindow {
    id: root

    required property var modelData
    readonly property var pin: modelData
    // The screen it was pinned on (not following focus).
    screen: Quickshell.screens.find(s => s.name === pin.screen) ?? Quickshell.screens[0]
    // Out of the way while a workspace panorama grabs the display.
    visible: !Capture.panoramaRunning

    readonly property real natW: img.implicitWidth / (screen?.devicePixelRatio ?? 1)
    readonly property real natH: img.implicitHeight / (screen?.devicePixelRatio ?? 1)
    // Start at most half the screen, never upscaled.
    property real zoom: natW > 0 ? Math.min(1, (screen?.width ?? 1280) * 0.5 / natW, (screen?.height ?? 800) * 0.5 / natH) : 1
    property point pos: Qt.point(((screen?.width ?? 1280) - natW * zoom) / 2 + (pin.id % 6) * 24, ((screen?.height ?? 800) - natH * zoom) / 2 + (pin.id % 6) * 24)

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "loft:capture-pin"
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        left: true
    }
    margins {
        left: Math.round(pos.x)
        top: Math.round(pos.y)
    }
    implicitWidth: Math.max(60, Math.round(natW * zoom)) + 12
    implicitHeight: Math.max(40, Math.round(natH * zoom)) + 12
    color: "transparent"

    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur ? frame : null
        radius: frame.radius
    }

    GlassSurface {
        id: frame
        anchors.fill: parent
        radius: 12
        strength: 1.6

        HoverHandler {
            id: hover
        }

        RoundedClip {
            anchors {
                fill: parent
                margins: 6
            }
            radius: 7

            Image {
                id: img
                anchors.fill: parent
                source: "file://" + root.pin.path
                fillMode: Image.PreserveAspectFit
                cache: false
                mipmap: true
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            property point grab
            onPressed: mouse => grab = Qt.point(mouse.x, mouse.y)
            onPositionChanged: mouse => {
                if (pressed)
                    root.pos = Qt.point(root.pos.x + mouse.x - grab.x, root.pos.y + mouse.y - grab.y);
            }
            onDoubleClicked: Capture.annotate(root.pin.path)
            onWheel: wheel => {
                const f = wheel.angleDelta.y > 0 ? 1.1 : 1 / 1.1;
                root.zoom = Math.max(0.1, Math.min(4, root.zoom * f));
            }
        }

        Rectangle {
            visible: hover.hovered
            anchors {
                left: parent.left
                top: parent.top
                margins: 12
            }
            width: 26
            height: 26
            radius: 13
            color: closeMouse.containsMouse ? Theme.withAlpha(Theme.bg, 0.95) : Theme.withAlpha(Theme.bg, 0.75)
            border.width: 1
            border.color: Theme.glassBorder

            Icon {
                anchors.centerIn: parent
                text: "󰅖"
                size: 13
            }
            MouseArea {
                id: closeMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Capture.unpin(root.pin.id)
            }
        }
    }
}
