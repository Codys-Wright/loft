import QtQuick
import qs.services

// A Nerd Font glyph, colored from the theme by default.
Text {
    property real size: 16

    color: Theme.text
    font.family: Theme.fontIcons
    font.pixelSize: size
    verticalAlignment: Text.AlignVCenter
    horizontalAlignment: Text.AlignHCenter

    Behavior on color {
        ColorAnimation {
            duration: 200
        }
    }
}
