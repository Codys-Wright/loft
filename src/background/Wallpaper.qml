import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.services

// Background layer. niri's xray blur samples it, so it is what the glass
// surfaces show through. Source, in order: the user's chosen image
// (Settings.wallpaper.path, set by the picker), the theme pack's image, the
// theme's gradient. Image changes crossfade.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    WlrLayershell.layer: WlrLayer.Background
    WlrLayershell.namespace: "studio:wallpaper"
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: Theme.bg

    readonly property string source: {
        const p = Settings.wallpaper.path || Theme.wallpaperImage;
        if (!p)
            return "";
        const abs = p.startsWith("~/") ? Quickshell.env("HOME") + p.slice(1) : p;
        return abs.startsWith("/") ? "file://" + abs : abs;
    }

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
        flip = !flip;
        (flip ? a : b).source = source;
    }
    Component.onCompleted: a.source = source

    component Layer: Image {
        anchors.fill: parent
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        sourceSize: Qt.size(root.width, root.height)
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: 600
                easing.type: Easing.InOutQuad
            }
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
}
