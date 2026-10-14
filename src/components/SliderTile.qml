import QtQuick
import qs.services

// A glass slider (volume, brightness): drag or scroll; click the icon to
// toggle (e.g. mute). `value` is 0..1; `moved(v)` fires while dragging.
GlassSurface {
    id: root

    property string icon: ""
    property string title: ""
    property real value: 0
    property bool dimmed: false

    signal moved(real value)
    signal iconClicked

    implicitHeight: 70
    radius: 22
    showHighlight: false

    Text {
        id: label
        anchors {
            left: parent.left
            top: parent.top
            leftMargin: 16
            topMargin: 10
        }
        text: root.title
        color: Theme.text
        font.family: Theme.fontUi
        font.pixelSize: 13
        font.weight: Font.DemiBold
    }

    Item {
        id: track
        anchors {
            left: parent.left
            right: parent.right
            bottom: parent.bottom
            margins: 12
        }
        height: 26

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: Theme.withAlpha(Theme.text, 0.12)
        }

        Rectangle {
            width: Math.max(height, parent.width * Math.max(0, Math.min(1, root.value)))
            height: parent.height
            radius: height / 2
            color: root.dimmed ? Theme.withAlpha(Theme.text, 0.35) : Theme.text

            Behavior on width {
                enabled: !drag.pressed
                NumberAnimation {
                    duration: 120
                }
            }
        }

        Icon {
            anchors {
                left: parent.left
                leftMargin: 8
                verticalCenter: parent.verticalCenter
            }
            text: root.icon
            size: 14
            color: Theme.bg
            z: 2

            MouseArea {
                anchors.fill: parent
                anchors.margins: -4
                cursorShape: Qt.PointingHandCursor
                onClicked: root.iconClicked()
            }
        }

        MouseArea {
            id: drag
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            function update(x) {
                root.moved(Math.max(0, Math.min(1, x / width)));
            }
            onPressed: mouse => update(mouse.x)
            onPositionChanged: mouse => pressed && update(mouse.x)
            onWheel: wheel => root.moved(Math.max(0, Math.min(1, root.value + (wheel.angleDelta.y > 0 ? 0.05 : -0.05))))
        }
    }
}
