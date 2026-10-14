import QtQuick
import QtQuick.Layouts
import Quickshell.Services.UPower
import qs.services

// Battery (only with a battery): charge, time remaining, power source,
// power mode, and the apps using the most energy (CPU, from SystemStats).
ColumnLayout {
    id: root

    property bool details: false
    property bool shown: true
    property bool inMenu: true
    signal dismiss
    signal openSettings(string section)

    spacing: 0

    readonly property var dev: Controls.batteryDevice

    function hm(s) {
        if (!s || s <= 0)
            return "";
        const h = Math.floor(s / 3600);
        const m = Math.round((s % 3600) / 60);
        return h > 0 ? `${h}:${String(m).padStart(2, "0")}` : `${m} min`;
    }

    PanelHeader {
        title: "Battery"
        trailing: `${Math.round(Controls.batteryPercent)}%`
        subtitle: {
            if (!root.dev)
                return "";
            if (!UPower.onBattery)
                return root.dev.timeToFull > 0 ? `${root.hm(root.dev.timeToFull)} until full` : "Fully charged";
            return root.dev.timeToEmpty > 0 ? `${root.hm(root.dev.timeToEmpty)} remaining` : "Calculating…";
        }
    }

    PanelRow {
        interactive: false
        text: "Power Source"
        trailing: UPower.onBattery ? "Battery" : "Power Adapter"
    }

    PanelSection {
        text: "Power Mode"
    }
    PanelSegmented {
        Layout.leftMargin: 10
        Layout.rightMargin: 10
        Layout.bottomMargin: 4
        options: [{ value: PowerProfile.PowerSaver, label: "Low Power" }, { value: PowerProfile.Balanced, label: "Automatic" }].concat(PowerProfiles.hasPerformanceProfile ? [{ value: PowerProfile.Performance, label: "High Power" }] : [])
        current: PowerProfiles.profile
        onPicked: v => PowerProfiles.profile = v
    }

    PanelSection {
        visible: SystemStats.processes.length > 0
        text: "Using Significant Energy"
    }
    Repeater {
        model: SystemStats.processes.slice(0, 3).filter(p => (p.cpu ?? 0) > 0.05)
        delegate: PanelRow {
            required property var modelData
            interactive: false
            text: modelData.name
            trailing: `${Math.round(modelData.cpu * 100)}% CPU`
        }
    }

    PanelSeparator {}
    PanelRow {
        text: "Battery Settings…"
        onClicked: root.openSettings("system")
    }
}
