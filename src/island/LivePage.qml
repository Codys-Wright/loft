import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Island page for the running live activity, with its controls: screen
// recording, the focus timer, a countdown / stopwatch (the Timers page has
// them all), a download in progress.
Item {
    id: root

    property string activity: ""

    readonly property var timer: Timers.primary
    readonly property var download: Downloads.primary
    readonly property color tint: activity === "recording" ? Theme.urgent : activity === "timer" ? Theme.warn : Theme.accent

    readonly property string heading: {
        switch (activity) {
        case "recording":
            return "Screen Recording";
        case "focus":
            return "Focus";
        case "timer":
            return Timers.title(timer);
        case "download":
            return download?.name ?? "Downloading";
        }
        return "";
    }
    readonly property string detail: {
        switch (activity) {
        case "recording":
            return `${FocusTimer.format(Recorder.elapsed)}${Recorder.paused ? "  ·  paused" : ""}`;
        case "focus":
            return FocusTimer.paused ? "Paused" : `${Settings.island.focusMinutes} minute session`;
        case "timer":
            return timer?.kind === "stopwatch" ? (timer.paused ? "Stopwatch · paused" : "Stopwatch") : `${Timers.describe(timer?.duration ?? 0)} timer${timer?.paused ? " · paused" : ""}`;
        case "download":
            return Downloads.detail(download);
        }
        return "";
    }
    readonly property bool paused: activity === "recording" ? Recorder.paused : activity === "focus" ? FocusTimer.paused : activity === "timer" ? (timer?.paused ?? false) : false

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

                trackColor: Theme.withAlpha(Theme.islandText, 0.15)
                anchors.fill: parent
                visible: root.activity === "focus" || root.activity === "timer" || (root.activity === "download" && root.download?.progress !== undefined)
                value: root.activity === "focus" ? FocusTimer.progress : root.activity === "timer" ? Timers.progress(root.timer) : (root.download?.progress ?? 0)
                color: root.tint
                lineWidth: 8
            }

            Rectangle {
                anchors.centerIn: parent
                visible: root.activity === "recording" || (root.activity === "download" && root.download?.progress === undefined)
                width: 84
                height: 84
                radius: 42
                color: Theme.withAlpha(root.tint, 0.18)

                Rectangle {
                    anchors.centerIn: parent
                    visible: root.activity === "recording"
                    width: 30
                    height: 30
                    radius: 15
                    color: Theme.urgent
                }

                Icon {
                    anchors.centerIn: parent
                    visible: root.activity === "download"
                    text: "󰇚"
                    size: 34
                    color: Theme.accent
                }
            }

            Text {
                anchors.centerIn: parent
                visible: root.activity === "focus" || root.activity === "timer" || (root.activity === "download" && root.download?.progress !== undefined)
                text: root.activity === "focus" ? FocusTimer.format(FocusTimer.remaining) : root.activity === "timer" ? Timers.display(root.timer) : `${Math.round((root.download?.progress ?? 0) * 100)}%`
                color: Theme.islandText
                font.family: Theme.fontUi
                font.pixelSize: text.length > 5 ? 18 : 22
                font.weight: Font.DemiBold
                font.features: { "tnum": 1 }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 4

            Text {
                Layout.fillWidth: true
                text: root.heading
                color: Theme.islandText
                font.family: Theme.fontUi
                font.pixelSize: 16
                font.weight: Font.DemiBold
                elide: Text.ElideMiddle
            }

            Text {
                Layout.fillWidth: true
                text: root.detail
                color: Theme.islandSubtext
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.features: { "tnum": 1 }
                elide: Text.ElideRight
            }

            RowLayout {
                Layout.topMargin: 10
                spacing: 12

                IslandButton {
                    visible: root.activity !== "download"
                    icon: root.paused ? "󰐊" : "󰏤"
                    onClicked: {
                        if (root.activity === "recording")
                            Recorder.pause();
                        else if (root.activity === "focus")
                            FocusTimer.pause();
                        else if (root.timer)
                            Timers.pause(root.timer.id);
                    }
                }

                IslandButton {
                    visible: root.activity === "timer" && root.timer?.kind === "timer"
                    icon: "󰐕"
                    onClicked: Timers.addTime(root.timer.id, 60)
                }

                IslandButton {
                    visible: root.activity !== "download"
                    icon: "󰓛"
                    tint: Theme.urgent
                    onClicked: {
                        if (root.activity === "recording")
                            Recorder.stop();
                        else if (root.activity === "focus")
                            FocusTimer.stop();
                        else if (root.timer)
                            Timers.stop(root.timer.id);
                    }
                }

                IslandButton {
                    visible: root.activity === "download"
                    icon: "󰉋"
                    onClicked: Downloads.show(root.download ? `${Downloads.watching}/${root.download.temp}` : Downloads.watching)
                }
            }
        }
    }
}
