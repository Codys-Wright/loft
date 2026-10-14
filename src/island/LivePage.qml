import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Island page for the running live activity, with its controls.
Item {
    id: root

    property string activity: ""

    component RoundButton: Rectangle {
        id: btn
        property string icon
        property color tint: Theme.text
        signal clicked

        width: 46
        height: 46
        radius: 23
        color: mouse.containsMouse ? Theme.withAlpha(tint, 0.3) : Theme.withAlpha(tint, 0.18)

        Icon {
            anchors.centerIn: parent
            text: btn.icon
            size: 20
            color: btn.tint
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }

    RowLayout {
        anchors {
            fill: parent
            margins: 22
            bottomMargin: 28
        }
        spacing: 20

        Item {
            Layout.preferredWidth: 110
            Layout.preferredHeight: 110

            ProgressRing {
                anchors.fill: parent
                visible: root.activity === "focus"
                value: FocusTimer.progress
                lineWidth: 8
            }

            Rectangle {
                anchors.centerIn: parent
                visible: root.activity === "recording"
                width: 84
                height: 84
                radius: 42
                color: Theme.withAlpha(Theme.urgent, 0.18)

                Rectangle {
                    anchors.centerIn: parent
                    width: 30
                    height: 30
                    radius: 15
                    color: Theme.urgent
                }
            }

            Text {
                anchors.centerIn: parent
                visible: root.activity === "focus"
                text: FocusTimer.format(FocusTimer.remaining)
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 22
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4

            Text {
                text: root.activity === "recording" ? "Screen Recording" : "Focus"
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 16
                font.weight: Font.DemiBold
            }

            Text {
                Layout.fillWidth: true
                text: root.activity === "recording" ? `${FocusTimer.format(Recorder.elapsed)}${Recorder.paused ? "  ·  paused" : ""}` : FocusTimer.paused ? "Paused" : `${Settings.island.focusMinutes} minute session`
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.features: { "tnum": 1 }
                elide: Text.ElideRight
            }

            RowLayout {
                Layout.topMargin: 10
                spacing: 12

                RoundButton {
                    icon: (root.activity === "recording" ? Recorder.paused : FocusTimer.paused) ? "󰐊" : "󰏤"
                    onClicked: root.activity === "recording" ? Recorder.pause() : FocusTimer.pause()
                }

                RoundButton {
                    icon: "󰓛"
                    tint: Theme.urgent
                    onClicked: root.activity === "recording" ? Recorder.stop() : FocusTimer.stop()
                }
            }
        }
    }
}
