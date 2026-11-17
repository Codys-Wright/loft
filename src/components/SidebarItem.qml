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
    // A switched-off entry: still listed, greyed.
    property bool dimmed: false
    // A second, smaller line (search results: where a setting lives).
    property string detail

    signal clicked

    Layout.fillWidth: true
    implicitHeight: detail !== "" ? 40 : 32
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
            opacity: item.dimmed && !item.current ? 0.45 : 1
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Text {
                Layout.fillWidth: true
                text: item.label
                elide: Text.ElideRight
                color: item.current && item.windowActive ? Theme.readableOn(Theme.accent, "#ffffff") : item.dimmed ? Theme.subtext : Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.weight: item.current ? Font.Medium : Font.Normal
            }
            Text {
                Layout.fillWidth: true
                visible: item.detail !== ""
                text: item.detail
                elide: Text.ElideRight
                color: item.current && item.windowActive ? Theme.withAlpha(Theme.readableOn(Theme.accent, "#ffffff"), 0.8) : Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
            }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: item.clicked()
    }
}
