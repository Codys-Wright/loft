import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services
import qs.settings

// System Monitor → Processes: the top 30 by CPU or memory (sampled every
// 2 s while the monitor is open), with Quit / Force Quit after a confirm.
// The list holds still while the pointer is on it, so the row you aim at
// is the process you get.
ColumnLayout {
    id: page
    spacing: 12

    // The process waiting for confirmation, or null.
    property var confirming: null

    readonly property bool paused: listHover.hovered || confirming !== null
    property var shown: SystemStats.processes
    onPausedChanged: if (!paused)
        shown = SystemStats.processes
    Connections {
        target: SystemStats
        function onProcessesChanged() {
            if (!page.paused)
                page.shown = SystemStats.processes;
        }
    }

    readonly property int cpuWidth: 70
    readonly property int memWidth: 86
    readonly property int pidWidth: 70

    component HeaderText: Text {
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 10
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.4
    }

    SettingsCard {
        spacing: 6

        HoverHandler {
            id: listHover
        }

        PageHeader {
            title: `${SystemStats.processCount} processes · ${SystemStats.threadCount} threads` + (page.paused ? "  ·  paused" : "")
            SettingsSegmented {
                options: [
                    {
                        value: "cpu",
                        label: "CPU"
                    },
                    {
                        value: "memory",
                        label: "Memory"
                    }
                ]
                current: SystemStats.processSort
                onActivated: v => SystemStats.processSort = v
            }
        }

        Text {
            Layout.fillWidth: true
            visible: SystemStats.killError !== ""
            text: SystemStats.killError
            color: Theme.urgent
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 8
            HeaderText {
                Layout.fillWidth: true
                Layout.leftMargin: 34
                text: "Name"
            }
            HeaderText {
                Layout.preferredWidth: page.pidWidth
                horizontalAlignment: Text.AlignRight
                text: "PID"
            }
            HeaderText {
                Layout.preferredWidth: page.cpuWidth
                horizontalAlignment: Text.AlignRight
                text: "% CPU"
                color: SystemStats.processSort === "cpu" ? Theme.accent : Theme.subtext
            }
            HeaderText {
                Layout.preferredWidth: page.memWidth
                horizontalAlignment: Text.AlignRight
                text: "Memory"
                color: SystemStats.processSort === "memory" ? Theme.accent : Theme.subtext
            }
            Item {
                Layout.preferredWidth: 28
            }
        }

        Repeater {
            // By position, not by process: rows (and their hover state)
            // survive the list being re-sorted every sample.
            model: page.shown.length

            delegate: Rectangle {
                id: row
                required property int index
                readonly property var modelData: page.shown[index] ?? {
                    pid: 0,
                    name: "",
                    uid: -1,
                    cpu: 0,
                    rssKiB: 0
                }
                readonly property bool mine: modelData.uid === SystemStats.myUid && SystemStats.myUid >= 0
                readonly property string iconSource: Apps.themed(modelData.name.toLowerCase())

                Layout.fillWidth: true
                implicitHeight: 30
                radius: 8
                color: hover.hovered ? Theme.withAlpha(Theme.text, 0.08) : index % 2 === 1 ? Theme.withAlpha(Theme.text, 0.03) : "transparent"

                HoverHandler {
                    id: hover
                }

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 8
                        rightMargin: 4
                    }
                    spacing: 8

                    Item {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        Image {
                            anchors.fill: parent
                            visible: row.iconSource !== ""
                            source: row.iconSource
                            sourceSize: Qt.size(36, 36)
                            asynchronous: true
                        }
                        Icon {
                            anchors.centerIn: parent
                            visible: row.iconSource === ""
                            text: row.modelData.uid === 0 ? "󰒓" : "󰆍"
                            size: 13
                            color: Theme.subtext
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: row.modelData.name
                        color: row.mine ? Theme.text : Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.preferredWidth: page.pidWidth
                        horizontalAlignment: Text.AlignRight
                        text: row.modelData.pid
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        font.features: {
                            "tnum": 1
                        }
                    }
                    Text {
                        Layout.preferredWidth: page.cpuWidth
                        horizontalAlignment: Text.AlignRight
                        text: row.modelData.cpu.toFixed(1)
                        color: row.modelData.cpu >= 90 ? Theme.warn : Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.features: {
                            "tnum": 1
                        }
                    }
                    Text {
                        Layout.preferredWidth: page.memWidth
                        horizontalAlignment: Text.AlignRight
                        text: row.modelData.rssKiB > 0 ? SystemStats.formatKiB(row.modelData.rssKiB) : "—"
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.features: {
                            "tnum": 1
                        }
                    }

                    // Quit — your own processes only.
                    Rectangle {
                        Layout.preferredWidth: 22
                        Layout.preferredHeight: 22
                        Layout.rightMargin: 4
                        radius: 11
                        visible: row.mine
                        opacity: hover.hovered ? 1 : 0
                        color: quit.containsMouse ? Theme.urgent : Theme.withAlpha(Theme.text, 0.1)

                        Icon {
                            anchors.centerIn: parent
                            text: "󰅖"
                            size: 11
                            color: quit.containsMouse ? Theme.bg : Theme.text
                        }
                        MouseArea {
                            id: quit
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: page.confirming = row.modelData
                        }
                    }
                    Item {
                        visible: !row.mine
                        Layout.preferredWidth: 26
                    }
                }
            }
        }
    }
}
