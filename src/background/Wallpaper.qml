import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.desktopmenu
import qs.palette
import qs.services

// Background layer. niri's xray blur samples it, so it is what the glass
// surfaces show through. Source: Vibes.wallpaperFor (this screen's active
// workspace's image: per-workspace and per-display choices, wallpaper sets,
// auto picks, rotation, the theme's default), else the theme's gradient.
// Image changes — a new choice, or switching to a workspace with its own
// image — crossfade (~400 ms); the outgoing image stays until the incoming
// one has decoded, so there is no flash. Each image is cropped around its
// interest (Vibes.focusFor, from the plan's framing) rather than its center:
// on the portrait display a landscape image keeps its subject.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.namespace: "loft:wallpaper"
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: Theme.bg

    readonly property string source: Vibes.url(Vibes.wallpaperFor(modelData.name))

    // Gradient fallback (no image), with soft color fields for the blur.
    Item {
        anchors.fill: parent
        visible: root.source === ""

        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.0; color: Theme.wallpaperGradient[0] ?? Theme.bg }
                GradientStop { position: 0.55; color: Theme.wallpaperGradient[1] ?? Theme.surface }
                GradientStop { position: 1.0; color: Theme.wallpaperGradient[2] ?? Theme.overlay }
            }
        }

        Repeater {
            model: [
                { x: 0.18, y: 0.30, size: 0.45, color: Theme.accent },
                { x: 0.62, y: 0.95, size: 0.55, color: Theme.accent2 }
            ]
            delegate: Rectangle {
                required property var modelData
                readonly property real d: Math.min(root.width, root.height) * modelData.size
                width: d
                height: d
                radius: d / 2
                x: root.width * modelData.x - d / 2
                y: root.height * modelData.y - d / 2
                color: Theme.withAlpha(modelData.color, 0.35)
            }
        }
    }

    // Two images: `flip` says which one is current (true = a). The outgoing
    // one stays until the incoming one has loaded, then they crossfade.
    property bool flip: true
    onSourceChanged: {
        if ((flip ? a : b).source.toString() === source)
            return;
        flip = !flip;
        const layer = flip ? a : b;
        layer.crop = Vibes.focusFor(Vibes.wallpaperFor(modelData.name));
        layer.source = source;
    }
    Component.onCompleted: {
        a.crop = Vibes.focusFor(Vibes.wallpaperFor(modelData.name));
        a.source = source;
    }

    component Layer: Item {
        id: layer
        property alias source: img.source
        readonly property alias status: img.status
        // The image point (0..1) to keep near the screen's center.
        property var crop: [0.5, 0.5]

        anchors.fill: parent
        clip: true
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: 400
                easing.type: Easing.InOutQuad
            }
        }

        // Decoded to cover the screen (PreserveAspectCrop scales to cover
        // sourceSize, keeping the aspect) and drawn at that size, shifted so
        // the focus sits as close to the center as the image's edges allow.
        Image {
            id: img
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            retainWhileLoading: true
            sourceSize: Qt.size(root.width, root.height)
            width: Math.max(implicitWidth, root.width)
            height: Math.max(implicitHeight, root.height)
            x: Math.min(0, Math.max(root.width - width, root.width / 2 - layer.crop[0] * width))
            y: Math.min(0, Math.max(root.height - height, root.height / 2 - layer.crop[1] * height))
        }
    }

    // A plan arriving later (framing) re-centers what is showing.
    Connections {
        target: Vibes
        function onPlanChanged() {
            (root.flip ? a : b).crop = Vibes.focusFor(Vibes.wallpaperFor(root.modelData.name));
        }
    }

    Layer {
        id: a
        opacity: root.source !== "" && a.status === Image.Ready && (root.flip || b.status !== Image.Ready) ? 1 : 0
    }

    Layer {
        id: b
        opacity: root.source !== "" && b.status === Image.Ready && (!root.flip || a.status !== Image.Ready) ? 1 : 0
    }

    // A right-click on the desktop (a click that lands on no window) opens
    // the desktop menu at the pointer (desktopmenu/DesktopMenu.qml).
    // The middle button held on the desktop opens the radial menu there:
    // drag toward a slice and let go (palette/Radial.qml). This surface
    // keeps the pointer until the release, so it feeds the wheel.
    MouseArea {
        anchors.fill: parent
        enabled: Features.on("desktopMenu") || Features.on("radialMenu")
        acceptedButtons: (Features.on("desktopMenu") ? Qt.RightButton : 0) | (Features.on("radialMenu") ? Qt.MiddleButton : 0)
        onPressed: mouse => {
            if (mouse.button === Qt.MiddleButton)
                Radial.openAt(root.modelData.name, mouse.x, mouse.y, "mouse");
            else
                DesktopMenu.openAt(root.modelData.name, mouse.x, mouse.y);
        }
        onPositionChanged: mouse => {
            if (pressedButtons & Qt.MiddleButton)
                Radial.pointer(mouse.x, mouse.y);
        }
        onReleased: mouse => {
            if (mouse.button === Qt.MiddleButton)
                Radial.release();
        }
    }
}
