import QtQuick
import QtQuick.Layouts
import qs.services

// Hairline between panel groups (MenuPanel's separator).
Item {
    Layout.fillWidth: true
    implicitHeight: 9

    Rectangle {
        anchors {
            left: parent.left
            right: parent.right
            verticalCenter: parent.verticalCenter
            leftMargin: 8
            rightMargin: 8
        }
        height: 1
        color: Theme.withAlpha(Theme.text, 0.14)
    }
}
