import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.services

// Background layer. niri's xray blur samples the background layer, so this
// is what the glass surfaces show through. Until wallpapers land (theme
// packs, PLAN §4.2) it's a gradient from the theme.
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

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            orientation: Gradient.Vertical
            GradientStop { position: 0.0; color: Theme.wallpaperGradient[0] ?? Theme.bg }
            GradientStop { position: 0.55; color: Theme.wallpaperGradient[1] ?? Theme.surface }
            GradientStop { position: 1.0; color: Theme.wallpaperGradient[2] ?? Theme.overlay }
        }
    }

    // A couple of soft color fields so the blur has something to show.
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
