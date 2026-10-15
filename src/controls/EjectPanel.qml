import QtQuick
import QtQuick.Layouts
import qs.services

// Eject: the external drives with a mounted filesystem (Drives.qml), one
// row each — click to unmount and power it off — and Eject All. Shown in the
// menu bar only while there is something to eject.
ColumnLayout {
    id: root

    property bool details: false
    property bool shown: true
    property bool inMenu: true
    signal dismiss
    signal openSettings(string section)

    spacing: 0

    onShownChanged: if (shown)
        Drives.refresh()

    PanelHeader {
        title: "Eject"
        subtitle: Drives.count === 0 ? "No external drives" : Drives.count === 1 ? "1 drive" : `${Drives.count} drives`
    }

    Repeater {
        model: Drives.list
        delegate: PanelRow {
            required property var modelData
            readonly property bool busy: Drives.busy.includes(modelData.id)
            text: modelData.name
            // "28.9G · Kingston DataTraveler 3.0" (or where it's mounted).
            detail: [modelData.size, modelData.model || modelData.mounts.map(m => m.mount).join(", ")].filter(s => s).join("  ·  ")
            glyph: modelData.kind === "rom" ? "\u{F01D8}" : "\u{F0553}"
            trailingGlyph: busy ? "\u{F0450}" : "\u{F01EA}"
            enabled: !busy
            onClicked: Drives.eject(modelData.id)
        }
    }

    PanelSeparator {
        visible: Drives.count > 1
    }
    PanelRow {
        visible: Drives.count > 1
        text: "Eject All"
        onClicked: {
            Drives.ejectAll();
            root.dismiss();
        }
    }

    PanelRow {
        visible: Drives.count === 0
        interactive: false
        dim: true
        text: "Plug in a USB drive, SD card or disc"
    }

    PanelSeparator {
        visible: Features.on("systemMonitor")
    }
    PanelRow {
        visible: Features.on("systemMonitor")
        text: "Disks & Sensors…"
        onClicked: {
            root.dismiss();
            SystemStats.monitorSection = "disks";
            SystemStats.monitorOpen = true;
        }
    }
}
