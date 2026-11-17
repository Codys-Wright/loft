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
// Under KWin the picture is a still from KWinThumbs (ScreenShot2), taken
// when this becomes active and every `interval` ms (at least 2 s) after;
// a capture that fails keeps the last still (else: not ready, the icon).
Item {
    id: root

    property int windowId: -1
    property bool active: true
    // Refresh period while active, ms (0: one still).
    property int interval: 1000
    property real radius: 8

    readonly property var toplevel: active && windowId >= 0 ? WindowCapture.toplevel(windowId) : null
    readonly property bool kwin: KWinThumbs.enabled
    readonly property string still: kwin && active && windowId >= 0 ? KWinThumbs.url(windowId) : ""
    readonly property bool stillReady: still !== "" && stillImage.status === Image.Ready
    readonly property Item picture: toplevel !== null ? view.item : stillReady ? stillImage : null
    readonly property bool ready: (toplevel !== null && (view.item?.hasContent ?? false)) || (toplevel === null && stillReady)
    // The picture's size inside this item.
    readonly property real paintedWidth: toplevel !== null ? (view.item?.width ?? 0) : stillReady ? stillImage.width : 0
    readonly property real paintedHeight: toplevel !== null ? (view.item?.height ?? 0) : stillReady ? stillImage.height : 0

    // KWin: ask for a still (cards opening together share one batch).
    function askStill() {
        if (kwin && active && windowId >= 0)
            KWinThumbs.request([windowId], 1000);
    }
    onActiveChanged: askStill()
    onWindowIdChanged: askStill()
    onKwinChanged: askStill()
    Component.onCompleted: askStill()
    Timer {
        running: root.kwin && root.active && root.interval > 0
        interval: Math.max(2000, root.interval)
        repeat: true
        onTriggered: KWinThumbs.request([root.windowId], 1500)
    }

    // Fitted, keeping the window's proportions (like the capture below).
    Image {
        id: stillImage
        readonly property real k: implicitWidth > 0 && implicitHeight > 0 ? Math.min(root.width / implicitWidth, root.height / implicitHeight) : 0
        anchors.centerIn: parent
        width: implicitWidth * k
        height: implicitHeight * k
        source: root.still
        cache: false
        // A small local PNG: loading in place swaps stills without a gap.
        asynchronous: false
        smooth: true
        mipmap: true
        visible: false
    }

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
        running: root.toplevel !== null && root.ready && root.interval > 0
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
        source: root.picture
        anchors.centerIn: parent
        width: root.paintedWidth
        height: root.paintedHeight
        maskEnabled: true
        maskSource: mask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1
    }
}
