import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Io
import qs.services

// Bluetooth (macOS's Bluetooth menu): the switch, paired devices (connected
// first) with battery, click to connect / disconnect, and "Nearby Devices"
// — discovery runs only while that list is open and the panel is shown —
// to pair + trust + connect. ⌥ (details): address, RSSI, trust.
ColumnLayout {
    id: root

    property bool details: false
    property bool shown: true
    property bool inMenu: true
    signal dismiss
    signal openSettings(string section)

    spacing: 0

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool on: adapter?.enabled ?? false
    readonly property var all: adapter ? adapter.devices.values : []
    readonly property var paired: all.filter(d => d.paired || d.bonded).sort((a, b) => (b.connected - a.connected) || a.name.localeCompare(b.name))
    readonly property var nearby: all.filter(d => !d.paired && !d.bonded && d.name && d.name.replace(/-/g, ":") !== d.address)

    // Discovery: only while "Nearby Devices" is open and the panel shown.
    // Stopped only if we started it.
    readonly property bool wantDiscovery: shown && on && nearbySection.expanded
    property bool startedDiscovery: false
    onWantDiscoveryChanged: {
        if (!adapter)
            return;
        if (wantDiscovery && !adapter.discovering) {
            adapter.discovering = true;
            startedDiscovery = true;
        } else if (!wantDiscovery && startedDiscovery) {
            adapter.discovering = false;
            startedDiscovery = false;
        }
    }
    Component.onDestruction: if (startedDiscovery && adapter)
        adapter.discovering = false

    // A device we're pairing: trust + connect once paired.
    property var pairing: null
    Connections {
        target: root.pairing
        function onPairedChanged() {
            if (root.pairing && root.pairing.paired) {
                root.pairing.trusted = true;
                root.pairing.connect();
                root.pairing = null;
            }
        }
    }

    function glyph(d) {
        const i = d?.icon ?? "";
        if (/headset|headphone/.test(i))
            return "󰋋";
        if (/mouse/.test(i))
            return "󰍽";
        if (/keyboard/.test(i))
            return "󰌌";
        if (/phone/.test(i))
            return "󰏲";
        if (/gaming|joystick/.test(i))
            return "󰊴";
        if (/audio|speaker|card/.test(i))
            return "󰓃";
        if (/computer/.test(i))
            return "󰟀";
        return "󰂯";
    }

    function stateText(d) {
        switch (d.state) {
        case BluetoothDeviceState.Connecting:
            return "Connecting…";
        case BluetoothDeviceState.Disconnecting:
            return "Disconnecting…";
        }
        return d.connected ? "Connected" : "";
    }

    // RSSI is not in Quickshell's model: read it (busctl, read-only) for ⌥.
    property var rssi: ({})
    Process {
        id: rssiProbe
        command: ["sh", "-c", "for p in \"$@\"; do printf '%s ' \"$p\"; busctl --system get-property org.bluez \"$p\" org.bluez.Device1 RSSI 2>/dev/null | cut -d' ' -f2 || echo; echo; done", "rssi"].concat(root.all.map(d => d.dbusPath))
        stdout: StdioCollector {
            onStreamFinished: {
                const m = {};
                for (const l of text.split("\n")) {
                    const [p, v] = l.trim().split(" ");
                    if (p && v)
                        m[p] = parseInt(v);
                }
                root.rssi = m;
            }
        }
    }
    function loadRssi() {
        if (details && shown && !rssiProbe.running)
            rssiProbe.running = true;
    }
    onDetailsChanged: loadRssi()
    onShownChanged: loadRssi()
    Component.onCompleted: loadRssi()

    function detailLine(d) {
        const parts = [d.address];
        if (rssi[d.dbusPath] !== undefined)
            parts.push(`RSSI ${rssi[d.dbusPath]} dBm`);
        if (d.trusted)
            parts.push("Trusted");
        return parts.join(" · ");
    }

    PanelHeader {
        title: "Bluetooth"
        subtitle: root.details && root.adapter ? `${root.adapter.name} · ${root.adapter.adapterId}` : !root.adapter ? "No Bluetooth adapter" : ""
        hasSwitch: root.adapter !== null
        checked: root.on
        onToggled: on => root.adapter.enabled = on
    }

    PanelSection {
        visible: root.on && root.paired.length > 0
        text: "Devices"
    }

    Repeater {
        model: root.on ? root.paired : []
        delegate: PanelRow {
            required property var modelData
            text: modelData.name
            detail: root.details ? root.detailLine(modelData) : root.stateText(modelData)
            glyph: root.glyph(modelData)
            glyphActive: modelData.connected
            trailing: modelData.batteryAvailable ? `${Math.round(modelData.battery * 100)}%` : ""
            onClicked: modelData.connected ? modelData.disconnect() : modelData.connect()
        }
    }

    PanelSection {
        id: nearbySection
        visible: root.on
        text: "Nearby Devices"
        collapsible: true
        expanded: false
        trailing: expanded && root.adapter?.discovering ? "Searching…" : ""
    }

    Repeater {
        model: root.on && nearbySection.expanded ? root.nearby : []
        delegate: PanelRow {
            required property var modelData
            text: modelData.name
            detail: modelData.pairing ? "Pairing…" : root.details ? root.detailLine(modelData) : ""
            glyph: root.glyph(modelData)
            onClicked: {
                root.pairing = modelData;
                modelData.pair();
            }
        }
    }

    PanelRow {
        visible: root.on && nearbySection.expanded && root.nearby.length === 0
        enabled: false
        text: "No devices found yet"
        dim: true
    }

    PanelSeparator {}
    PanelRow {
        text: "Bluetooth Settings…"
        onClicked: root.openSettings("menubar")
    }
}
