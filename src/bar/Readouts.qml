import QtQuick
import QtQuick.Layouts
import Quickshell.Services.UPower
import qs.components
import qs.services

// Menu bar readouts (iStat-style): compact live values in the status pill —
// CPU, memory, CPU temperature, GPU, network up/down, battery. Which ones
// show, and their order, is Settings → System → Menu bar readouts.
// Clicking one opens the System Monitor.
RowLayout {
    id: root
    spacing: 12
    visible: Features.on("barReadouts") && shown.length > 0

    readonly property var battery: UPower.displayDevice
    readonly property bool hasBattery: battery !== null && battery.ready && battery.isLaptopBattery
    // Battery only where there is one; GPU only where it can be read.
    // Only these keys (the menu bar arranges each readout as its own item).
    property var only: null
    // Bar colors (the bar adapts them to the wallpaper).
    property color textColor: Theme.text
    property color subColor: Theme.subtext
    readonly property var shown: (Features.on("barReadouts") ? (only ?? Settings.system.readouts) : []).filter(k => k !== "battery" || hasBattery)

    function openMonitor(key) {
        if (!Features.on("systemMonitor"))
            return;
        if (SystemStats.monitorOpen) {
            SystemStats.monitorOpen = false;
            return;
        }
        SystemStats.monitorSection = key === "network" && Features.on("network") ? "network" : "overview";
        SystemStats.monitorOpen = true;
    }

    Repeater {
        model: root.shown

        delegate: Item {
            id: readout
            required property string modelData
            readonly property bool isNet: modelData === "network"
            readonly property var r: {
                const s = SystemStats;
                switch (modelData) {
                case "cpu":
                    return {
                        icon: "󰍛",
                        text: `${Math.round(s.cpu * 100)}%`,
                        sample: "100%",
                        alert: s.cpu > s.maxLoad
                    };
                case "memory":
                    return {
                        icon: "󰘚",
                        text: `${Math.round(s.memory * 100)}%`,
                        sample: "100%",
                        alert: s.memory > s.maxLoad
                    };
                case "cpuTemp":
                    return {
                        icon: "󰔏",
                        text: s.cpuTemp > 0 ? `${Math.round(s.cpuTemp)}°` : "—",
                        sample: "100°",
                        alert: s.cpuTemp > s.maxTemp
                    };
                case "gpu":
                    return {
                        icon: "󰢮",
                        text: s.gpu >= 0 ? `${Math.round(s.gpu * 100)}%` : "—",
                        sample: "100%",
                        alert: s.gpuTemp > s.maxTemp
                    };
                case "battery":
                    {
                        const p = root.hasBattery ? (root.battery.percentage > 1 ? root.battery.percentage : root.battery.percentage * 100) : 0;
                        const charging = !UPower.onBattery;
                        return {
                            icon: charging ? "󰂄" : p > 80 ? "󰁹" : p > 50 ? "󰂀" : p > 20 ? "󰁻" : "󰂃",
                            text: `${Math.round(p)}%`,
                            sample: "100%",
                            alert: !charging && p <= Settings.system.batteryThreshold
                        };
                    }
                default:
                    return {
                        icon: "",
                        text: "",
                        sample: "",
                        alert: false
                    };
                }
            }

            implicitWidth: isNet ? net.implicitWidth : single.implicitWidth
            implicitHeight: 24

            TextMetrics {
                id: metrics
                font.family: Theme.fontUi
                font.pixelSize: 12
                font.weight: Font.DemiBold
                text: readout.r.sample
            }

            // One value: icon + number (fixed width, so the bar doesn't jitter).
            RowLayout {
                id: single
                anchors.verticalCenter: parent.verticalCenter
                visible: !readout.isNet
                spacing: 4
                Icon {
                    text: readout.r.icon
                    size: 13
                    color: readout.r.alert ? Theme.urgent : hover.containsMouse ? Theme.accent : root.subColor
                }
                Text {
                    Layout.preferredWidth: metrics.advanceWidth
                    text: readout.r.text
                    color: readout.r.alert ? Theme.urgent : root.textColor
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    font.features: {
                        "tnum": 1
                    }
                }
            }

            // Network: up over down, stacked small.
            RowLayout {
                id: net
                anchors.verticalCenter: parent.verticalCenter
                visible: readout.isNet
                spacing: 4
                Icon {
                    text: "󰛳"
                    size: 13
                    color: hover.containsMouse ? Theme.accent : root.subColor
                }
                Column {
                    spacing: -2
                    // A count, not an array of the rates: a new array every
                    // tick rebuilt both labels each time.
                    Repeater {
                        model: 2
                        delegate: Text {
                            required property int index
                            width: netMetrics.advanceWidth
                            horizontalAlignment: Text.AlignRight
                            text: index === 0 ? `↑ ${SystemStats.formatRateShort(SystemStats.netTx)}` : `↓ ${SystemStats.formatRateShort(SystemStats.netRx)}`
                            color: root.textColor
                            font.family: Theme.fontUi
                            font.pixelSize: 9
                            font.weight: Font.DemiBold
                            font.features: {
                                "tnum": 1
                            }
                        }
                    }
                }
                TextMetrics {
                    id: netMetrics
                    font.family: Theme.fontUi
                    font.pixelSize: 9
                    font.weight: Font.DemiBold
                    text: "↑ 888.8K"
                }
            }

            MouseArea {
                id: hover
                anchors.fill: parent
                anchors.margins: -4
                hoverEnabled: true
                cursorShape: Features.on("systemMonitor") ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.openMonitor(readout.modelData)
            }
        }
    }
}
