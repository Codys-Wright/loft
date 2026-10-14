import QtQuick
import qs.services

// Four bouncing bars — the "now playing" glyph of the collapsed island.
Row {
    id: root

    property bool running: true

    spacing: 2

    Repeater {
        model: 4
        delegate: Rectangle {
            required property int index
            anchors.bottom: parent.bottom
            width: (root.width - 6) / 4
            height: root.height * 0.3
            radius: width / 2
            color: Theme.accent

            SequentialAnimation on height {
                running: root.running
                loops: Animation.Infinite
                NumberAnimation {
                    to: root.height * (0.5 + 0.5 * ((index * 37) % 10) / 10)
                    duration: 260 + index * 70
                    easing.type: Easing.InOutSine
                }
                NumberAnimation {
                    to: root.height * 0.25
                    duration: 260 + index * 70
                    easing.type: Easing.InOutSine
                }
            }
        }
    }
}
