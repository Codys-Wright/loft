import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.services

// The menu bar: a full-width Liquid Glass strip across the top of each screen.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "studio:bar"
    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: 34
    color: "transparent"

    // Ask the compositor to blur everything behind the glass.
    BackgroundEffect.blurRegion: Theme.blur ? glassRegion : null
    Region {
        id: glassRegion
        item: glass
    }

    Rectangle {
        id: glass
        anchors.fill: parent
        color: Theme.glassFill

        // Hairline at the bottom edge, like the macOS menu bar.
        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            height: 1
            color: Theme.glassBorder
        }
    }

    RowLayout {
        anchors {
            fill: parent
            leftMargin: 16
            rightMargin: 16
        }
        spacing: 18

        Text {
            text: "studio"
            color: Theme.text
            font.pixelSize: 14
            font.weight: Font.Bold
        }

        Text {
            text: Theme.name
            color: Theme.subtext
            font.pixelSize: 13
        }

        Item {
            Layout.fillWidth: true
        }

        Text {
            text: Qt.formatDateTime(clock.date, "ddd MMM d   h:mm AP")
            color: Theme.text
            font.pixelSize: 13
            font.weight: Font.Medium
        }
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }
}
