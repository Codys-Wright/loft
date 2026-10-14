import QtQuick
import QtQuick.Layouts
import qs.services

// "Label   value" lines for ⌥-click details.
GridLayout {
    id: grid
    // [[label, value], …]
    property var rows: []

    Layout.fillWidth: true
    columns: 2
    columnSpacing: 10
    rowSpacing: 2

    Repeater {
        model: grid.rows.length * 2
        delegate: Text {
            required property int index
            readonly property var pair: grid.rows[Math.floor(index / 2)]
            readonly property bool isKey: index % 2 === 0
            Layout.fillWidth: !isKey
            Layout.alignment: Qt.AlignTop
            text: pair ? (isKey ? pair[0] : pair[1]) : ""
            color: isKey ? Theme.subtext : Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 11
            elide: isKey ? Text.ElideNone : Text.ElideMiddle
        }
    }
}
