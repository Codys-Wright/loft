import QtQuick
import QtQuick.Layouts
import qs.services

// Settings → System: the System Monitor, menu bar readouts and alerts
// (each card shows only while its module is on — Settings → Features).
ColumnLayout {
    id: page
    spacing: 12

    readonly property var cfg: Settings.system

    // Every readout the bar can show, in their default order.
    readonly property var readoutKinds: [
        {
            id: "cpu",
            label: "CPU load",
            hint: "Across all cores"
        },
        {
            id: "memory",
            label: "Memory",
            hint: "In use, excluding caches"
        },
        {
            id: "cpuTemp",
            label: "CPU temperature",
            hint: "k10temp / zenpower / coretemp"
        },
        {
            id: "gpu",
            label: "GPU load",
            hint: "Polls nvidia-smi every 6 s while shown"
        },
        {
            id: "network",
            label: "Network",
            hint: "Upload and download rate"
        },
        {
            id: "battery",
            label: "Battery",
            hint: "Only on machines with a battery"
        }
    ]

    function setReadout(id, on) {
        const cur = Array.from(cfg.readouts).filter(r => r !== id);
        if (on) {
            // Keep the canonical order.
            cur.push(id);
            const order = readoutKinds.map(k => k.id);
            cur.sort((a, b) => order.indexOf(a) - order.indexOf(b));
        }
        cfg.readouts = cur;
    }

    // ── System Monitor ──────────────────────────────────────────────────
    SettingsCard {
        visible: Features.on("systemMonitor")

        PageHeader {
            title: "System Monitor"
            SettingsButton {
                text: "Open"
                icon: "󰄧"
                onClicked: {
                    Panels.settingsOpen = false;
                    SystemStats.monitorOpen = true;
                }
            }
        }

        Text {
            Layout.fillWidth: true
            text: "History graphs (last five minutes), processes, network, disks and sensors. Processes, sensors and disks are only read while the window is open."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }
    }

    // ── Menu bar readouts ───────────────────────────────────────────────
    SettingsCard {
        visible: Features.on("barReadouts")

        PageHeader {
            title: "Menu bar readouts"
        }

        Repeater {
            model: page.readoutKinds
            delegate: SettingsRow {
                required property var modelData
                label: modelData.label
                hint: modelData.hint
                SettingsSwitch {
                    checked: page.cfg.readouts.includes(modelData.id)
                    onToggled: on => page.setReadout(modelData.id, on)
                }
            }
        }
    }

    // ── Alerts ──────────────────────────────────────────────────────────
    SettingsCard {
        visible: Features.on("alerts")

        PageHeader {
            title: "Alerts"
            SettingsButton {
                text: "Test"
                icon: "󰂚"
                onClicked: Notifications.show({
                    appName: "System",
                    appIcon: "utilities-system-monitor",
                    summary: "Sustained CPU load",
                    body: `CPU has been above ${Math.round(page.cfg.cpuThreshold * 100)}% for over ${page.cfg.cpuSeconds} s.`,
                    image: "",
                    actions: []
                })
            }
        }

        Text {
            Layout.fillWidth: true
            text: "A notification when a condition holds for a while. Each alert fires once, then waits until the condition has clearly passed (and at least 10 minutes) before it can fire again."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        SettingsRow {
            label: "Sustained CPU load"
            hint: "Whole-CPU load above the threshold"
            SettingsSwitch {
                checked: page.cfg.alertCpu
                onToggled: on => page.cfg.alertCpu = on
            }
        }
        SettingsRow {
            label: "    Above"
            enabled: page.cfg.alertCpu
            SettingsSlider {
                from: 0.5
                to: 1
                step: 0.01
                value: page.cfg.cpuThreshold
                format: v => `${Math.round(v * 100)}%`
                onMoved: v => page.cfg.cpuThreshold = v
            }
        }
        SettingsRow {
            label: "    For"
            enabled: page.cfg.alertCpu
            SettingsSlider {
                from: 10
                to: 300
                step: 10
                suffix: " s"
                value: page.cfg.cpuSeconds
                onMoved: v => page.cfg.cpuSeconds = Math.round(v)
            }
        }

        SettingsRow {
            label: "High temperature"
            hint: "CPU or GPU for 20 s · shared with the island's overheat border"
            SettingsSwitch {
                checked: page.cfg.alertTemp
                onToggled: on => page.cfg.alertTemp = on
            }
        }
        SettingsRow {
            label: "    Above"
            enabled: page.cfg.alertTemp
            SettingsSlider {
                from: 60
                to: 110
                step: 1
                suffix: " °C"
                value: Settings.island.maxTemp
                onMoved: v => Settings.island.maxTemp = v
            }
        }

        SettingsRow {
            label: "Memory pressure"
            hint: "Share of time tasks stall waiting for memory (PSI), or 95% used"
            SettingsSwitch {
                checked: page.cfg.alertMemory
                onToggled: on => page.cfg.alertMemory = on
            }
        }
        SettingsRow {
            label: "    Above"
            enabled: page.cfg.alertMemory
            SettingsSlider {
                from: 5
                to: 60
                step: 1
                suffix: "%"
                value: page.cfg.memoryPressure
                onMoved: v => page.cfg.memoryPressure = v
            }
        }

        SettingsRow {
            label: "Low disk space"
            hint: "Any local filesystem · alerts again only when another one fills up"
            SettingsSwitch {
                checked: page.cfg.alertDisk
                onToggled: on => page.cfg.alertDisk = on
            }
        }
        SettingsRow {
            label: "    Fuller than"
            enabled: page.cfg.alertDisk
            SettingsSlider {
                from: 0.7
                to: 0.99
                step: 0.01
                value: page.cfg.diskThreshold
                format: v => `${Math.round(v * 100)}%`
                onMoved: v => page.cfg.diskThreshold = v
            }
        }

        SettingsRow {
            label: "Low battery"
            hint: "While discharging · critical alert at 5%"
            SettingsSwitch {
                checked: page.cfg.alertBattery
                onToggled: on => page.cfg.alertBattery = on
            }
        }
        SettingsRow {
            label: "    At or below"
            enabled: page.cfg.alertBattery
            SettingsSlider {
                from: 5
                to: 50
                step: 1
                suffix: "%"
                value: page.cfg.batteryThreshold
                onMoved: v => page.cfg.batteryThreshold = Math.round(v)
            }
        }
        SettingsRow {
            label: "Desktop shell running slow"
            hint: Perf.troubled ? `Now: ${Perf.culprit}` : "Once per session, when the shell lags or uses over 60% CPU for 30 s · details: loft doctor perf"
            SettingsSwitch {
                checked: page.cfg.perfHint
                onToggled: on => page.cfg.perfHint = on
            }
        }
    }

    Text {
        Layout.fillWidth: true
        visible: !Features.on("systemMonitor") && !Features.on("barReadouts") && !Features.on("alerts")
        text: "The System Monitor, menu bar readouts and alerts are all switched off (Settings → Features)."
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 12
        wrapMode: Text.Wrap
    }
}
