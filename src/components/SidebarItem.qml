import QtQuick
import QtQuick.Layouts
import qs.services

// A sidebar row for WindowChrome: a colored icon badge and a label
// (System Settings style). The current row is filled with the accent while
// the window is active, grey when it is in the background.
Rectangle {
    id: item

    property string icon
    property string label
    // Theme.badgeColor name.
    property string badge: "gray"
    property bool current: false
    // The window's active state (WindowChrome.active).
    property bool windowActive: true

    signal clicked

    Layout.fillWidth: true
    implicitHeight: 32
    radius: Theme.controlRadius
    color: current ? (windowActive ? Theme.accent : Theme.withAlpha(Theme.text, 0.14)) : mouse.containsMouse ? Theme.withAlpha(Theme.text, 0.07) : "transparent"

    Behavior on color {
        ColorAnimation {
            duration: 120
        }
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 6
        anchors.rightMargin: 8
        spacing: 9

        IconBadge {
            icon: item.icon
            badge: item.badge
            size: 22
        }

        Text {
            Layout.fillWidth: true
            text: item.label
            elide: Text.ElideRight
            color: item.current && item.windowActive ? Theme.readableOn(Theme.accent, "#ffffff") : Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 13
            font.weight: item.current ? Font.Medium : Font.Normal
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: item.clicked()
    }
}
