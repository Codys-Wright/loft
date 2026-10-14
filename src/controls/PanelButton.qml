import QtQuick
import QtQuick.Layouts
import qs.services

// Small pill button inside panels (Join, Cancel, Clear).
Rectangle {
    id: btn
    property string text
    property bool primary: false
    signal clicked

    implicitWidth: label.implicitWidth + 22
    implicitHeight: 24
    radius: Theme.controlRadius
    color: primary ? Theme.accent : Theme.withAlpha(Theme.text, hover.containsMouse ? 0.16 : 0.10)
    opacity: enabled ? 1 : 0.45

    Text {
        id: label
        anchors.centerIn: parent
        text: btn.text
        color: btn.primary ? Theme.bg : Theme.text
        font.family: Theme.fontUi
        font.pixelSize: 12
        font.weight: Font.Medium
    }
    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
