import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// A live activity in the collapsed island: what's running and its clock.
Item {
    id: root

    property string activity: ""

    RowLayout {
        anchors {
            fill: parent
            leftMargin: 12
            rightMargin: 14
        }
        spacing: 8

        // Recording: a pulsing red dot. Focus: a small progress ring.
        Rectangle {
            visible: root.activity === "recording"
            Layout.preferredWidth: 10
            Layout.preferredHeight: 10
            radius: 5
            color: Theme.urgent

            SequentialAnimation on opacity {
                running: root.activity === "recording" && !Recorder.paused
                loops: Animation.Infinite
                NumberAnimation {
                    to: 0.3
                    duration: 700
                }
                NumberAnimation {
                    to: 1
                    duration: 700
                }
            }
        }

        ProgressRing {
            visible: root.activity === "focus"
            Layout.preferredWidth: 18
            Layout.preferredHeight: 18
            value: FocusTimer.progress
            lineWidth: 3
        }

        Text {
            Layout.fillWidth: true
            text: root.activity === "recording" ? (Recorder.paused ? "Paused" : "Recording") : "Focus"
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 13
            font.weight: Font.DemiBold
        }

        Text {
            text: root.activity === "recording" ? FocusTimer.format(Recorder.elapsed) : FocusTimer.format(FocusTimer.remaining)
            color: root.activity === "recording" ? Theme.urgent : Theme.accent
            font.family: Theme.fontUi
            font.pixelSize: 13
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }
    }
}
