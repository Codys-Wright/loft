import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services
import qs.settings

// System Monitor → Disks & Sensors: space per filesystem (df, one row per
// device), every hwmon temperature and fan (read-only RPM), and the GPU.
ColumnLayout {
    id: page
    spacing: 12

    // hwmon chips in display order, each with its readings.
    readonly property var chips: {
        const out = [];
        for (const s of SystemStats.sensors) {
            let c = out.find(x => x.id === s.chipId);
            if (!c) {
                c = {
                    id: s.chipId,
                    name: s.chip,
                    readings: []
                };
                out.push(c);
            }
            c.readings.push(s);
        }
        // Same-named chips (several "nvme", "spd5118" DIMMs) get a number.
        for (const c of out) {
            const same = out.filter(x => x.name === c.name);
            if (same.length > 1)
                c.title = `${c.name} ${same.indexOf(c) + 1}`;
            else
                c.title = c.name;
        }
        return out;
    }

    function chipIcon(name) {
        if (/k10temp|zenpower|coretemp|cpu/i.test(name))
            return "󰍛";
        if (/nvme|ssd|sata|drive|samsung|wd|crucial/i.test(name))
            return "󰋊";
        if (/spd|dimm|mem/i.test(name))
            return "󰘚";
        if (/battery/i.test(name))
            return "󰁹";
        if (/^en|^wl|^eth|net/i.test(name))
            return "󰈀";
        return "󰔏";
    }

    // ── Disks ───────────────────────────────────────────────────────────
    SettingsCard {
        spacing: 14

        PageHeader {
            title: "Disks"
            SettingsButton {
                text: "Refresh"
                icon: "󰑐"
                onClicked: SystemStats.refreshDisks()
            }
        }

        Repeater {
            model: SystemStats.disks

            delegate: ColumnLayout {
                id: disk
                required property var modelData
                readonly property bool full: modelData.use >= Settings.system.diskThreshold
                Layout.fillWidth: true
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Icon {
                        text: disk.modelData.mount === "/" ? "󰋜" : "󰋊"
                        size: 16
                        color: disk.full ? Theme.warn : Theme.accent
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Text {
                            text: disk.modelData.mount
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 13
                            font.weight: Font.Medium
                        }
                        Text {
                            Layout.fillWidth: true
                            text: `${disk.modelData.source} · ${disk.modelData.fstype}`
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 10
                            elide: Text.ElideMiddle
                        }
                    }
                    ColumnLayout {
                        spacing: 0
                        Text {
                            Layout.alignment: Qt.AlignRight
                            text: `${SystemStats.formatBytes(disk.modelData.avail)} free`
                            color: disk.full ? Theme.warn : Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            font.features: {
                                "tnum": 1
                            }
                        }
                        Text {
                            Layout.alignment: Qt.AlignRight
                            text: `${SystemStats.formatBytes(disk.modelData.used)} of ${SystemStats.formatBytes(disk.modelData.size)}`
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 10
                            font.features: {
                                "tnum": 1
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: 26
                    implicitHeight: 6
                    radius: 3
                    color: Theme.withAlpha(Theme.text, 0.1)
                    Rectangle {
                        width: parent.width * Math.min(1, disk.modelData.use)
                        height: parent.height
                        radius: 3
                        color: disk.full ? Theme.warn : Theme.accent
                    }
                }
            }
        }

        Text {
            visible: SystemStats.disks.length === 0
            text: "Reading filesystems…"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
    }

    // ── Sensors ─────────────────────────────────────────────────────────
    SettingsCard {
        spacing: 14

        PageHeader {
            title: "Sensors"
        }

        Text {
            Layout.fillWidth: true
            text: "Temperatures and fan speeds from the kernel's hwmon drivers. Fans are read-only."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        // The GPU (nvidia-smi / sysfs) isn't a hwmon chip on NVIDIA.
        ColumnLayout {
            Layout.fillWidth: true
            visible: SystemStats.gpuTemp > 0 || SystemStats.gpuFan >= 0
            spacing: 6
            RowLayout {
                spacing: 8
                Icon {
                    text: "󰢮"
                    size: 14
                    color: Theme.accent
                }
                Text {
                    text: SystemStats.gpuName || "GPU"
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                }
            }
            Flow {
                Layout.fillWidth: true
                Layout.leftMargin: 22
                spacing: 6
                SensorChip {
                    visible: SystemStats.gpuTemp > 0
                    label: "Core"
                    value: `${Math.round(SystemStats.gpuTemp)} °C`
                    hot: SystemStats.gpuTemp > SystemStats.maxTemp
                }
                SensorChip {
                    visible: SystemStats.gpuFan >= 0
                    fan: true
                    label: "Fan"
                    value: `${Math.round(SystemStats.gpuFan)}%`
                }
            }
        }

        Repeater {
            model: page.chips

            delegate: ColumnLayout {
                id: chip
                required property var modelData
                Layout.fillWidth: true
                spacing: 6

                RowLayout {
                    spacing: 8
                    Icon {
                        text: page.chipIcon(chip.modelData.name)
                        size: 14
                        color: Theme.accent
                    }
                    Text {
                        text: chip.modelData.title
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                    }
                }

                Flow {
                    Layout.fillWidth: true
                    Layout.leftMargin: 22
                    spacing: 6
                    Repeater {
                        model: chip.modelData.readings
                        delegate: SensorChip {
                            required property var modelData
                            fan: modelData.kind === "fan"
                            label: modelData.label
                            value: fan ? `${modelData.value} RPM` : `${modelData.value.toFixed(0)} °C`
                            hot: !fan && modelData.value > SystemStats.maxTemp
                        }
                    }
                }
            }
        }

        Text {
            visible: page.chips.length === 0
            text: "Reading sensors…"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
    }

    component SensorChip: Rectangle {
        id: sc
        property string label
        property string value
        property bool fan: false
        property bool hot: false
        implicitWidth: scRow.implicitWidth + 18
        implicitHeight: 26
        radius: 13
        color: hot ? Theme.withAlpha(Theme.urgent, 0.2) : Theme.withAlpha(Theme.text, 0.07)

        Row {
            id: scRow
            anchors.centerIn: parent
            spacing: 6
            Icon {
                anchors.verticalCenter: parent.verticalCenter
                text: sc.fan ? "󰈐" : "󰔏"
                size: 11
                color: sc.hot ? Theme.urgent : Theme.subtext
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: sc.label
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: sc.value
                color: sc.hot ? Theme.urgent : Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 11
                font.weight: Font.DemiBold
                font.features: {
                    "tnum": 1
                }
            }
        }
    }
}
