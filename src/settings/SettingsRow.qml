import QtQuick
import QtQuick.Layouts
import qs.services

// A settings row: label (+ hint) on the left, the control (children)
// right-aligned.
Item {
    id: row
    property string label
    property string hint
    property color hintColor: Theme.subtext
    default property alias control: slot.data

    Layout.fillWidth: true
    implicitHeight: Math.max(labels.implicitHeight, slot.implicitHeight)

    ColumnLayout {
        id: labels
        anchors {
            left: parent.left
            right: slot.left
            rightMargin: 16
            verticalCenter: parent.verticalCenter
        }
        spacing: 1

        Text {
            Layout.fillWidth: true
            text: row.label
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 13
            elide: Text.ElideRight
        }
        Text {
            Layout.fillWidth: true
            visible: text !== ""
            text: row.hint
            color: row.hintColor
            font.family: Theme.fontUi
            font.pixelSize: 11
            elide: Text.ElideMiddle
        }
    }

    RowLayout {
        id: slot
        anchors {
            right: parent.right
            verticalCenter: parent.verticalCenter
        }
    }
}
