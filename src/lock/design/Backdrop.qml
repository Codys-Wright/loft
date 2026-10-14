import QtQuick
import qs.services

// The lock's wallpaper: the same theme gradient + soft color fields the
// shell's Wallpaper draws, so locking feels like the desktop dimming rather
// than switching scenes. Drawn in-scene because a lock surface is opaque —
// there is nothing behind it for the compositor to blur.
Rectangle {
    id: root

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
