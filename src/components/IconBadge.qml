import QtQuick
import qs.services

// A colored rounded-square icon badge, System Settings style: a white glyph
// on a Theme.badgeColor(name) tile with a subtle top-to-bottom sheen.
Rectangle {
    id: root

    property string icon
    // An Apple system color name (Theme.badgeColor), or set `tint` directly.
    property string badge: "gray"
    property color tint: Theme.badgeColor(badge)
    property real size: 22

    width: size
    height: size
    radius: Math.round(size * 0.27)
    gradient: Gradient {
        GradientStop {
            position: 0
            color: Qt.lighter(root.tint, 1.14)
        }
        GradientStop {
            position: 1
            color: Qt.darker(root.tint, 1.08)
        }
    }
    border.width: 1
    border.color: Theme.withAlpha("#000000", 0.08)

    Text {
        anchors.centerIn: parent
        text: root.icon
        color: "white"
        font.family: Theme.fontIcons
        font.pixelSize: Math.round(root.size * 0.6)
    }
}
