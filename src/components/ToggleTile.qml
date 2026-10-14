import QtQuick
import qs.services

// A Control Center toggle: icon disc + title + subtitle on a glass pill.
// The disc fills with the accent when on. Ported from javiiervm's tiles.
GlassSurface {
    id: root

    property string icon: ""
    property string title: ""
    property string subtitle: ""
    property bool active: false
    property bool available: true

    signal clicked
    signal rightClicked

    radius: height / 2
    showHighlight: false
    strength: mouse.containsMouse && available ? 1.35 : 1.0
    opacity: available ? 1 : 0.45

    Row {
        anchors {
            fill: parent
            leftMargin: 10
            rightMargin: 12
        }
        spacing: 10

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 36
            height: 36
            radius: 18
            color: root.active ? Theme.accent : Theme.withAlpha(Theme.text, 0.13)

            Behavior on color {
                ColorAnimation {
                    duration: 200
                }
            }

            Icon {
                anchors.centerIn: parent
                text: root.icon
                size: 16
                color: root.active ? Theme.bg : Theme.text
            }
        }

        Column {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 46
            spacing: 2

            Text {
                width: parent.width
                text: root.title
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                visible: text !== ""
                text: root.subtitle
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        enabled: root.available
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: mouse => mouse.button === Qt.RightButton ? root.rightClicked() : root.clicked()
    }
}
