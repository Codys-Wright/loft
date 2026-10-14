import QtQuick
import QtQuick.Layouts
import qs.services

// A compact segmented picker (rate / buffer / power mode / appearance).
Rectangle {
    id: seg
    property var options: [] // [{ value, label }]
    property var current
    signal picked(var value)

    Layout.fillWidth: true
    implicitHeight: 24
    radius: 7
    color: Theme.withAlpha(Theme.text, 0.10)

    RowLayout {
        anchors {
            fill: parent
            margins: 2
        }
        spacing: 2

        Repeater {
            model: seg.options
            delegate: Rectangle {
                required property var modelData
                readonly property bool on: modelData.value === seg.current
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 5
                color: on ? Theme.accent : hover.containsMouse ? Theme.withAlpha(Theme.text, 0.10) : "transparent"

                Text {
                    anchors.centerIn: parent
                    text: modelData.label
                    color: parent.on ? Theme.bg : Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    font.weight: parent.on ? Font.DemiBold : Font.Normal
                }
                MouseArea {
                    id: hover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: seg.picked(parent.modelData.value)
                }
            }
        }
    }
}
