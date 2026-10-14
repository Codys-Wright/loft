import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// System Monitor → Overview: CPU, GPU, memory and temperature history over
// the last five minutes, plus network traffic when that module is on.
GridLayout {
    id: page
    columns: 2
    columnSpacing: 12
    rowSpacing: 12

    readonly property var h: SystemStats.history
    readonly property bool hasGpu: SystemStats.gpu >= 0 || SystemStats.gpuName !== ""
    readonly property real tempScale: Math.max(100, SystemStats.maxTemp + 5)

    function pct(v) {
        return v < 0 ? "—" : `${Math.round(v * 100)}%`;
    }

    // A small label/value pair under a graph.
    component Detail: ColumnLayout {
        property string label
        property string value
        property color valueColor: Theme.text
        spacing: 1
        Text {
            text: parent.label
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 10
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 0.4
        }
        Text {
            text: parent.value
            color: parent.valueColor
            font.family: Theme.fontUi
            font.pixelSize: 12
            font.weight: Font.Medium
            font.features: {
                "tnum": 1
            }
        }
    }

    component Legend: Row {
        property color color
        property string text
        spacing: 5
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 8
            height: 8
            radius: 4
            color: parent.color
        }
        Text {
            text: parent.text
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
    }

    // ── CPU ─────────────────────────────────────────────────────────────
    MonitorCard {
        Layout.preferredWidth: 1
        Layout.alignment: Qt.AlignTop
        icon: "󰍛"
        title: "CPU"
        caption: `${SystemStats.cores.length || "—"} threads · up ${SystemStats.formatDuration(SystemStats.uptime)}`
        value: page.pct(SystemStats.cpu)
        valueColor: SystemStats.cpu > SystemStats.maxLoad ? Theme.warn : Theme.text

        HistoryGraph {
            Layout.fillWidth: true
            Layout.preferredHeight: 84
            values: page.h.cpu
            color: Theme.accent
        }

        // Per-thread load, one bar each.
        Row {
            Layout.fillWidth: true
            Layout.preferredHeight: 22
            spacing: 2
            visible: SystemStats.cores.length > 0

            Repeater {
                model: SystemStats.cores
                delegate: Rectangle {
                    required property real modelData
                    width: Math.max(2, (parent.width - (SystemStats.cores.length - 1) * 2) / SystemStats.cores.length)
                    height: 22
                    radius: 2
                    color: Theme.withAlpha(Theme.text, 0.08)

                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: Math.max(1, parent.height * modelData)
                        radius: 2
                        color: modelData > 0.9 ? Theme.warn : Theme.accent
                        Behavior on height {
                            NumberAnimation {
                                duration: 300
                            }
                        }
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 18
            Detail {
                label: "Temp"
                value: SystemStats.cpuTemp > 0 ? `${Math.round(SystemStats.cpuTemp)} °C` : "—"
                valueColor: SystemStats.cpuTemp > SystemStats.maxTemp ? Theme.urgent : Theme.text
            }
            Detail {
                label: "Load avg"
                value: SystemStats.loadAvg.map(v => v.toFixed(2)).join("  ")
            }
            Detail {
                label: "Processes"
                value: SystemStats.processCount > 0 ? `${SystemStats.processCount} · ${SystemStats.threadCount} thr` : "—"
            }
        }
    }

    // ── GPU ─────────────────────────────────────────────────────────────
    MonitorCard {
        Layout.preferredWidth: 1
        Layout.alignment: Qt.AlignTop
        icon: "󰢮"
        title: "GPU"
        caption: SystemStats.gpuName || (page.hasGpu ? "" : "No GPU load counter found")
        value: page.pct(SystemStats.gpu)

        HistoryGraph {
            Layout.fillWidth: true
            Layout.preferredHeight: 84
            values: page.h.gpu
            color: Theme.accent2
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 18
            Detail {
                label: "Temp"
                value: SystemStats.gpuTemp > 0 ? `${Math.round(SystemStats.gpuTemp)} °C` : "—"
                valueColor: SystemStats.gpuTemp > SystemStats.maxTemp ? Theme.urgent : Theme.text
            }
            Detail {
                visible: SystemStats.gpuMemTotalMiB > 0
                label: "VRAM"
                value: `${(SystemStats.gpuMemUsedMiB / 1024).toFixed(1)} / ${(SystemStats.gpuMemTotalMiB / 1024).toFixed(0)} GiB`
            }
            Detail {
                visible: SystemStats.gpuPower >= 0
                label: "Power"
                value: `${Math.round(SystemStats.gpuPower)} W`
            }
            Detail {
                visible: SystemStats.gpuFan >= 0
                label: "Fan"
                value: `${Math.round(SystemStats.gpuFan)}%`
            }
        }
    }

    // ── Memory ──────────────────────────────────────────────────────────
    MonitorCard {
        Layout.preferredWidth: 1
        Layout.alignment: Qt.AlignTop
        icon: "󰘚"
        title: "Memory"
        caption: `${SystemStats.memoryUsedGiB.toFixed(1)} of ${SystemStats.memoryTotalGiB.toFixed(0)} GiB in use`
        value: page.pct(SystemStats.memory)
        valueColor: SystemStats.memory > SystemStats.maxLoad ? Theme.warn : Theme.text

        HistoryGraph {
            Layout.fillWidth: true
            Layout.preferredHeight: 84
            values: page.h.memory
            color: Theme.ok
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 18
            Detail {
                label: "Cached"
                value: `${SystemStats.memoryCachedGiB.toFixed(1)} GiB`
            }
            Detail {
                label: "Swap"
                value: SystemStats.swapTotalGiB > 0 ? `${SystemStats.swapUsedGiB.toFixed(1)} / ${SystemStats.swapTotalGiB.toFixed(0)} GiB` : "off"
            }
            Detail {
                label: "Pressure"
                value: `${SystemStats.memoryPressure.toFixed(1)}%`
                valueColor: SystemStats.memoryPressure > Settings.system.memoryPressure ? Theme.warn : Theme.text
            }
        }
    }

    // ── Temperatures ────────────────────────────────────────────────────
    MonitorCard {
        Layout.preferredWidth: 1
        Layout.alignment: Qt.AlignTop
        icon: "󰔏"
        title: "Temperatures"
        caption: `Alert above ${Math.round(SystemStats.maxTemp)} °C`
        value: SystemStats.cpuTemp > 0 ? `${Math.round(SystemStats.cpuTemp)}°` : "—"
        valueColor: SystemStats.overheating ? Theme.urgent : Theme.text

        HistoryGraph {
            Layout.fillWidth: true
            Layout.preferredHeight: 84
            values: page.h.cpuTemp
            values2: page.h.gpuTemp
            max: page.tempScale
            color: Theme.warn
            color2: Theme.accent2
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            Legend {
                color: Theme.warn
                text: SystemStats.cpuTemp > 0 ? `CPU ${Math.round(SystemStats.cpuTemp)} °C` : "CPU"
            }
            Legend {
                visible: SystemStats.gpuTemp > 0
                color: Theme.accent2
                text: `GPU ${Math.round(SystemStats.gpuTemp)} °C`
            }
            Item {
                Layout.fillWidth: true
            }
            Text {
                text: `0–${Math.round(page.tempScale)} °C`
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 10
            }
        }
    }

    // ── Network ─────────────────────────────────────────────────────────
    MonitorCard {
        Layout.columnSpan: 2
        Layout.fillWidth: true
        visible: Features.on("network")
        icon: "󰛳"
        title: "Network"
        caption: `This session: ↓ ${SystemStats.formatBytes(SystemStats.sessionRx)}  ↑ ${SystemStats.formatBytes(SystemStats.sessionTx)}`
        value: `↓ ${SystemStats.formatRate(SystemStats.netRx)}`

        HistoryGraph {
            Layout.fillWidth: true
            Layout.preferredHeight: 64
            values: page.h.rx
            values2: page.h.tx
            max: 0
            minMax: 64000
            color: Theme.accent
            color2: Theme.ok
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 14
            Legend {
                color: Theme.accent
                text: `Down ${SystemStats.formatRate(SystemStats.netRx)}`
            }
            Legend {
                color: Theme.ok
                text: `Up ${SystemStats.formatRate(SystemStats.netTx)}`
            }
        }
    }
}
