import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import qs.services

// A window's picture, fitted into this item with rounded corners: captured
// by niri (WindowCapture: hyprland-toplevel-export through ScreencopyView)
// while `active`, and refreshed every `interval` ms. Nothing is captured
// while inactive, and the capture's buffers go when it stops. `ready` says
// a picture is showing; callers show their icon fallback until then (or
// when capture isn't available at all).
Item {
    id: root

    property int windowId: -1
    property bool active: true
    // Refresh period while active, ms (0: one still).
    property int interval: 1000
    property real radius: 8

    readonly property var toplevel: active && windowId >= 0 ? WindowCapture.toplevel(windowId) : null
    readonly property bool ready: toplevel !== null && (view.item?.hasContent ?? false)
    // The picture's size inside this item.
    readonly property real paintedWidth: view.item?.width ?? 0
    readonly property real paintedHeight: view.item?.height ?? 0

    // Only made while capturing: merely creating a ScreencopyView sets up
    // Quickshell's buffer code, which ends the shell on a dmabuf-v3-only
    // compositor (WindowCapture.toplevel() is null there).
    Loader {
        id: view
        anchors.centerIn: parent
        active: root.toplevel !== null
        sourceComponent: ScreencopyView {
            // Fitted, keeping the window's proportions.
            readonly property real k: sourceSize.width > 0 ? Math.min(root.width / sourceSize.width, root.height / sourceSize.height) : 0
            width: sourceSize.width * k
            height: sourceSize.height * k
            captureSource: root.toplevel
            live: false
            visible: false
        }
    }

    Timer {
        running: root.ready && root.interval > 0
        interval: root.interval
        repeat: true
        onTriggered: view.item.captureFrame()
    }

    Rectangle {
        id: mask
        width: root.paintedWidth
        height: root.paintedHeight
        anchors.centerIn: parent
        radius: root.radius
        visible: false
        layer.enabled: true
    }
    MultiEffect {
        visible: root.ready
        source: view.item
        anchors.fill: view
        maskEnabled: true
        maskSource: mask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1
    }
}
