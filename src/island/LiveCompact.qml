import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// A live activity in the collapsed island: what's running and its clock —
// a recording, the focus timer, a countdown / stopwatch, a download.
Item {
    id: root

    property string activity: ""

    readonly property var timer: Timers.primary
    readonly property var download: Downloads.primary
    // Timers in the theme's warm color (iOS uses orange).
    readonly property color timerColor: Theme.warn

    readonly property string label: {
        switch (activity) {
        case "recording":
            return Recorder.paused ? "Paused" : "Recording";
        case "focus":
            return "Focus";
        case "timer":
            return Timers.title(timer) + (Timers.timers.length > 1 ? `  +${Timers.timers.length - 1}` : "");
        case "download":
            return download?.name ?? "";
        }
        return "";
    }
    readonly property string value: {
        switch (activity) {
        case "recording":
            return FocusTimer.format(Recorder.elapsed);
        case "focus":
            return FocusTimer.format(FocusTimer.remaining);
        case "timer":
            return Timers.display(timer);
        case "download":
            return download?.progress !== undefined ? `${Math.round(download.progress * 100)}%` : Downloads.size(download?.size ?? 0);
        }
        return "";
    }
    readonly property color valueColor: activity === "recording" ? Theme.urgent : activity === "timer" ? timerColor : Theme.accent

    RowLayout {
        anchors {
            fill: parent
            leftMargin: 12
            rightMargin: 14
        }
        spacing: 8

        // Recording: a pulsing red dot. Focus / timers / downloads: a small ring.
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

        Item {
            visible: root.activity !== "recording"
            Layout.preferredWidth: 18
            Layout.preferredHeight: 18

            ProgressRing {
                anchors.fill: parent
                visible: root.activity === "focus" || (root.activity === "timer" && root.timer?.kind === "timer") || (root.activity === "download" && root.download?.progress !== undefined)
                value: root.activity === "focus" ? FocusTimer.progress : root.activity === "timer" ? Timers.progress(root.timer) : (root.download?.progress ?? 0)
                color: root.activity === "timer" ? root.timerColor : Theme.accent
                lineWidth: 3
            }

            Icon {
                anchors.centerIn: parent
                visible: (root.activity === "timer" && root.timer?.kind === "stopwatch") || (root.activity === "download" && root.download?.progress === undefined)
                text: root.activity === "timer" ? "󱎫" : "󰇚"
                size: 14
                color: root.activity === "timer" ? root.timerColor : Theme.accent

                SequentialAnimation on opacity {
                    running: root.activity === "download"
                    loops: Animation.Infinite
                    NumberAnimation {
                        to: 0.35
                        duration: 600
                    }
                    NumberAnimation {
                        to: 1
                        duration: 600
                    }
                }
            }
        }

        Text {
            Layout.fillWidth: true
            text: root.label
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 13
            font.weight: Font.DemiBold
            elide: Text.ElideMiddle
        }

        Text {
            text: root.value
            color: root.valueColor
            opacity: root.activity === "timer" && root.timer?.paused ? 0.55 : 1
            font.family: Theme.fontUi
            font.pixelSize: 13
            font.weight: Font.DemiBold
            font.features: { "tnum": 1 }
        }
    }
}
