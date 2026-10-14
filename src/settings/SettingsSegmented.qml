import QtQuick
import QtQuick.Layouts
import qs.services

// A segmented control (macOS-style). options: [{ value, label }] or plain
// strings; emits activated(value).
Rectangle {
    id: seg
    property var options: []
    property var current
    signal activated(var value)

    implicitWidth: row.implicitWidth + 4
    implicitHeight: 28
    radius: 8
    color: Theme.withAlpha(Theme.text, 0.08)
    opacity: enabled ? 1 : 0.4

    function valueOf(o) {
        return typeof o === "object" ? o.value : o;
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 2

        Repeater {
            model: seg.options
            delegate: Rectangle {
                id: opt
                required property var modelData
                readonly property bool selected: seg.valueOf(modelData) === seg.current
                Layout.preferredHeight: 24
                Layout.preferredWidth: Math.max(36, label.implicitWidth + 20)
                radius: 6
                color: selected ? Theme.accent : hover.containsMouse ? Theme.withAlpha(Theme.text, 0.08) : "transparent"

                Text {
                    id: label
                    anchors.centerIn: parent
                    text: typeof opt.modelData === "object" ? opt.modelData.label : String(opt.modelData)
                    color: opt.selected ? Theme.bg : Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                    font.weight: opt.selected ? Font.DemiBold : Font.Normal
                }

                MouseArea {
                    id: hover
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: seg.activated(seg.valueOf(opt.modelData))
                }
            }
        }
    }
}
