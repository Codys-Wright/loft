import QtQuick
import qs.components
import qs.services

// The round icon on a device / network row: accent-filled when connected.
Rectangle {
    id: disc
    property string glyph
    property bool active: false
    property bool inverted: false // on a highlighted row
    property int discSize: 26

    implicitWidth: discSize
    implicitHeight: discSize
    radius: discSize / 2
    color: active ? (inverted ? Theme.bg : Theme.accent) : Theme.withAlpha(inverted ? Theme.bg : Theme.text, 0.14)

    Icon {
        anchors.centerIn: parent
        text: disc.glyph
        size: disc.discSize * 0.5
        color: disc.active ? (disc.inverted ? Theme.accent : Theme.bg) : (disc.inverted ? Theme.bg : Theme.text)
    }
}
