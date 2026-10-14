import QtQuick
import qs.components
import qs.services

// A round glass button on an island page (transport, timers, toggles).
// `on` fills it with the tint, like an active Control Center toggle.
Rectangle {
    id: btn

    property string icon
    property color tint: Theme.islandText
    property bool on: false
    property real size: 46
    signal clicked

    width: size
    height: size
    radius: size / 2
    color: on ? Theme.withAlpha(tint, mouse.containsMouse ? 0.95 : 0.85) : mouse.containsMouse ? Theme.withAlpha(tint, 0.3) : Theme.withAlpha(tint, 0.16)

    Behavior on color {
        ColorAnimation {
            duration: 160
        }
    }

    Icon {
        anchors.centerIn: parent
        text: btn.icon
        size: btn.size * 0.43
        color: btn.on ? Theme.readableOn(btn.tint, Theme.islandBg) : btn.tint
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
