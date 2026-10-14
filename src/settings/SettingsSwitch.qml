import QtQuick
import qs.services

// An on/off switch. Emits toggled(on); the owner sets `checked`.
Rectangle {
    id: sw
    property bool checked
    signal toggled(bool on)
    implicitWidth: 44
    implicitHeight: 26
    radius: 13
    color: checked ? Theme.accent : Theme.withAlpha(Theme.text, 0.2)
    opacity: enabled ? 1 : 0.4

    Rectangle {
        width: 22
        height: 22
        radius: 11
        y: 2
        x: sw.checked ? sw.width - width - 2 : 2
        color: "white"
        Behavior on x {
            NumberAnimation {
                duration: 150
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: sw.toggled(!sw.checked)
    }
}
