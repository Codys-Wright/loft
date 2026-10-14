import QtQuick
import QtQuick.Layouts
import Quickshell.Networking
import qs.components
import qs.services

// Wi-Fi & network (macOS's Wi-Fi menu): the Wi-Fi switch, the current
// network, known and other networks (scanning only while shown), inline
// password entry, "Other Network…" for hidden SSIDs, every wired link and
// VPNs (Tailscale & co.). ⌥ (details): addresses, router, DNS, channel,
// band, rate, signal. Shared by the menu bar dropdown and the Control
// Center's expanded Wi-Fi module.
ColumnLayout {
    id: root

    property bool details: false
    property bool shown: true
    property bool inMenu: true
    signal dismiss
    signal openSettings(string section)

    spacing: 0

    readonly property var dev: NetStatus.wifiDevice
    readonly property bool wifiOn: Networking.wifiEnabled
    readonly property var current: NetStatus.wifiNetwork
    readonly property var networks: {
        const seen = {};
        const out = [];
        // Strongest first; one row per name; hidden SSIDs (no name) skipped.
        for (const n of NetStatus.wifiNetworks.slice().sort((a, b) => b.signalStrength - a.signalStrength)) {
            if (!n.name || seen[n.name])
                continue;
            seen[n.name] = true;
            out.push(n);
        }
        return out;
    }
    readonly property var known: networks.filter(n => n.known && !n.connected)
    readonly property var others: networks.filter(n => !n.known && !n.connected)

    // Scan while visible (and the Other Networks list is open).
    Binding {
        target: root.dev
        when: root.dev !== null
        property: "scannerEnabled"
        value: root.shown && root.wifiOn
    }

    // Details: read addresses for the links on show.
    function loadDetails() {
        if (!details || !shown)
            return;
        if (dev) {
            NetStatus.loadDetails(dev.name);
            NetStatus.loadAp(dev.name);
        }
        for (const w of NetStatus.wiredDevices)
            NetStatus.loadDetails(w.name);
        for (const v of NetStatus.vpns)
            if (v.device)
                NetStatus.loadDetails(v.device);
    }
    onDetailsChanged: loadDetails()
    onShownChanged: {
        loadDetails();
        if (shown)
            NetStatus.refresh();
        else
            reset();
    }
    Component.onCompleted: {
        loadDetails();
        NetStatus.refresh();
    }

    // Password / hidden network entry.
    property string askFor: "" // network name waiting for a password
    property string failed: "" // name whose last attempt failed
    property bool otherOpen: false
    property bool joining: false
    property string joinError: ""

    function reset() {
        askFor = "";
        failed = "";
        otherOpen = false;
        joinError = "";
    }

    // Esc inside the panel: close an open entry first.
    function back() {
        if (askFor !== "" || otherOpen) {
            reset();
            return true;
        }
        return false;
    }

    function pick(n) {
        if (n.connected)
            return;
        failed = "";
        if (n.known || !NetStatus.secured(n)) {
            n.connect();
        } else {
            askFor = askFor === n.name ? "" : n.name;
        }
    }

    function addrText(iface) {
        const d = NetStatus.details[iface];
        return d ? (d.ip[0] ?? "—") : "…";
    }

    function detailRows(iface, extra) {
        const d = NetStatus.details[iface];
        if (!d)
            return [["Interface", iface]];
        const out = [["IP address", d.ip.join(", ") || "—"]];
        if (d.ip6.length > 0)
            out.push(["IPv6", d.ip6[0]]);
        out.push(["Router", d.router || "—"]);
        if (d.dns.length > 0)
            out.push(["DNS", d.dns.join(", ")]);
        out.push(["Hardware", d.mac || "—"]);
        out.push(["Interface", iface]);
        return out.concat(extra ?? []);
    }

    // ── Wi-Fi ────────────────────────────────────────────────────────────
    PanelHeader {
        visible: root.dev !== null
        title: "Wi-Fi"
        subtitle: root.details && root.dev ? [root.dev.name, root.dev.address].filter(x => x).join(" · ") : ""
        hasSwitch: true
        checked: root.wifiOn
        onToggled: on => Networking.wifiEnabled = on
    }

    PanelRow {
        visible: root.dev !== null && root.wifiOn && root.current !== null
        text: root.current?.name ?? ""
        detail: root.current ? (root.current.stateChanging ? "Connecting…" : "Connected") : ""
        glyph: root.current ? NetStatus.bars(root.current.signalStrength) : ""
        glyphActive: true
        trailingGlyph: NetStatus.secured(root.current) ? "󰌾" : ""
        onClicked: root.details = !root.details

        PanelValue {
            visible: root.details && root.current !== null
            rows: {
                const ap = NetStatus.apInfo[root.current?.name ?? ""];
                const extra = ap ? [["Security", ap.security || "Open"], ["BSSID", ap.bssid], ["Channel", `${ap.channel} (${ap.band})`], ["Rate", ap.rate], ["Signal", `${ap.signal}%`]] : [["Signal", `${Math.round((root.current?.signalStrength ?? 0) * 100)}%`]];
                return root.detailRows(root.dev?.name ?? "", extra);
            }
        }
        RowLayout {
            visible: root.details && root.current !== null
            PanelButton {
                text: "Disconnect"
                onClicked: root.current.disconnect()
            }
        }
    }

    PanelSection {
        visible: root.dev !== null && root.wifiOn && root.known.length > 0
        text: "Known Networks"
    }

    Repeater {
        model: root.wifiOn ? root.known : []
        delegate: NetworkRow {}
    }

    PanelSection {
        id: otherSection
        visible: root.dev !== null && root.wifiOn
        text: "Other Networks"
        collapsible: true
        expanded: !root.inMenu || root.known.length === 0 && root.current === null
        trailing: root.others.length > 0 ? String(root.others.length) : ""
    }

    Repeater {
        model: root.wifiOn && otherSection.expanded ? root.others : []
        delegate: NetworkRow {}
    }

    PanelRow {
        visible: root.dev !== null && root.wifiOn && otherSection.expanded
        text: "Other Network…"
        dim: true
        onClicked: {
            root.askFor = "";
            root.otherOpen = !root.otherOpen;
        }

        ColumnLayout {
            visible: root.otherOpen
            Layout.fillWidth: true
            spacing: 6

            PanelTextField {
                id: ssidField
                placeholder: "Network name"
                onCancelled: root.reset()
                onAccepted: hiddenPw.focusField()
                onVisibleChanged: if (visible)
                    focusField()
            }
            PanelTextField {
                id: hiddenPw
                placeholder: "Password (leave empty for an open network)"
                password: true
                onCancelled: root.reset()
                onAccepted: joinHidden.clicked()
            }
            Text {
                Layout.fillWidth: true
                visible: root.joinError !== ""
                text: root.joinError
                color: Theme.urgent
                wrapMode: Text.WordWrap
                font.family: Theme.fontUi
                font.pixelSize: 11
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                PanelButton {
                    text: "Cancel"
                    onClicked: root.reset()
                }
                PanelButton {
                    id: joinHidden
                    primary: true
                    text: root.joining ? "Joining…" : "Join"
                    enabled: ssidField.text !== "" && !root.joining
                    onClicked: {
                        root.joining = true;
                        root.joinError = "";
                        NetStatus.join(ssidField.text, hiddenPw.text, true);
                    }
                }
            }
        }
    }

    Connections {
        target: NetStatus
        function onJoinFinished(ok, message) {
            root.joining = false;
            if (ok)
                root.reset();
            else
                root.joinError = message;
        }
    }

    // ── Wired ────────────────────────────────────────────────────────────
    PanelSeparator {
        visible: NetStatus.wiredDevices.length > 0 && root.dev !== null
    }
    PanelSection {
        visible: NetStatus.wiredDevices.length > 0
        text: "Ethernet"
    }
    Repeater {
        model: NetStatus.wiredDevices
        delegate: PanelRow {
            id: wd
            required property var modelData
            readonly property var link: NetStatus.links.find(l => l.device === modelData.name)
            text: modelData.network?.name || link?.connection || modelData.name
            detail: {
                if (modelData.connected) {
                    const parts = ["Connected", NetStatus.speedText(modelData.linkSpeed)];
                    if (!root.details)
                        parts.push(modelData.name);
                    return parts.filter(x => x).join(" · ");
                }
                return modelData.hasLink ? "Not connected" : "Cable unplugged";
            }
            glyph: "󰈀"
            glyphActive: modelData.connected
            dim: !modelData.connected
            onClicked: root.details = !root.details

            PanelValue {
                visible: root.details && wd.modelData.connected
                rows: root.detailRows(wd.modelData.name)
            }
        }
    }

    // ── VPN ──────────────────────────────────────────────────────────────
    PanelSection {
        visible: NetStatus.vpns.length > 0
        text: "VPN"
    }
    Repeater {
        model: NetStatus.vpns
        delegate: PanelRow {
            required property var modelData
            text: modelData.name
            detail: modelData.external ? "Connected (externally)" : modelData.connected ? "Connected" : "Not connected"
            glyph: "󰦝"
            glyphActive: modelData.connected
            trailing: root.details && modelData.device ? root.addrText(modelData.device) : ""
            onClicked: {
                if (modelData.external || !modelData.uuid)
                    root.details = !root.details;
                else
                    NetStatus.setVpn(modelData, !modelData.connected);
            }
        }
    }

    // ── Traffic + footer ─────────────────────────────────────────────────
    PanelSeparator {}
    Text {
        Layout.fillWidth: true
        Layout.leftMargin: 10
        Layout.rightMargin: 10
        Layout.bottomMargin: 2
        visible: SystemStats.networkWanted
        text: `↓ ${SystemStats.formatRateShort(SystemStats.netRx)}/s   ↑ ${SystemStats.formatRateShort(SystemStats.netTx)}/s`
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
        font.features: {
            "tnum": 1
        }
    }
    PanelRow {
        text: "Wi-Fi Settings…"
        onClicked: root.openSettings("menubar")
    }

    // One network: bars, lock, click to join; inline password when needed.
    component NetworkRow: PanelRow {
        id: nr
        required property var modelData
        readonly property bool asking: root.askFor === modelData.name
        text: modelData.name
        detail: modelData.stateChanging ? "Connecting…" : root.failed === modelData.name ? "Couldn't join — check the password" : ""
        trailingGlyph: NetStatus.bars(modelData.signalStrength)
        trailingGlyph2: NetStatus.secured(modelData) ? "󰌾" : ""
        onClicked: root.pick(modelData)

        Connections {
            target: nr.modelData
            function onConnectionFailed(reason) {
                root.failed = nr.modelData.name;
                if (NetStatus.secured(nr.modelData))
                    root.askFor = nr.modelData.name;
            }
            function onConnectedChanged() {
                if (nr.modelData.connected && root.askFor === nr.modelData.name)
                    root.reset();
            }
        }

        ColumnLayout {
            visible: nr.asking
            Layout.fillWidth: true
            spacing: 6

            PanelTextField {
                id: pw
                placeholder: `Password for “${nr.modelData.name}”`
                password: true
                onCancelled: root.reset()
                onAccepted: join.clicked()
                onVisibleChanged: if (visible)
                    focusField()
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                PanelButton {
                    text: "Cancel"
                    onClicked: root.reset()
                }
                PanelButton {
                    id: join
                    primary: true
                    text: "Join"
                    enabled: pw.text.length >= 8 || !NetStatus.secured(nr.modelData)
                    onClicked: {
                        root.failed = "";
                        nr.modelData.connectWithPsk(pw.text);
                        root.askFor = "";
                    }
                }
            }
        }
    }
}
