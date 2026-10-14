import QtQuick
import qs.components
import qs.services

// A pill button. `primary` fills it with the accent.
Rectangle {
    id: btn
    property string text
    property string icon
    property bool primary: false
    signal clicked

    implicitWidth: row.implicitWidth + 24
    implicitHeight: 28
    radius: 14
    color: primary ? (hover.containsMouse ? Qt.lighter(Theme.accent, 1.1) : Theme.accent) : hover.containsMouse ? Theme.withAlpha(Theme.text, 0.16) : Theme.withAlpha(Theme.text, 0.09)
    opacity: enabled ? 1 : 0.4

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Icon {
            visible: btn.icon !== ""
            text: btn.icon
            size: 12
            color: btn.primary ? Theme.bg : Theme.text
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            text: btn.text
            color: btn.primary ? Theme.bg : Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 12
            font.weight: btn.primary ? Font.DemiBold : Font.Medium
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
