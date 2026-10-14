pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking

// Network state for the Wi-Fi control (menu bar + Control Center).
//
// Wi-Fi and wired links come from Quickshell's NetworkManager backend.
// Things it doesn't model — tun/WireGuard/VPN links such as Tailscale
// ("connected (externally)"), VPN profiles, addresses, router, DNS, the
// access point's channel and rate — come from read-only `nmcli` queries,
// refreshed on `nmcli monitor` events while the module is on.
Singleton {
    id: root

    readonly property bool enabled: Features.on("wifiControl")

    readonly property var devices: Networking.devices.values
    readonly property var wifiDevice: devices.find(d => d.type === DeviceType.Wifi) ?? null
    readonly property var wifiNetworks: wifiDevice ? wifiDevice.networks.values : []
    readonly property var wifiNetwork: wifiNetworks.find(n => n.connected) ?? null
    readonly property var wiredDevices: devices.filter(d => d.type === DeviceType.Wired)
    readonly property var wired: wiredDevices.find(d => d.connected) ?? null
    readonly property bool online: wifiNetwork !== null || wired !== null

    // nmcli view of every link: [{ device, type, state, connection }].
    property var links: []
    // NM profiles: [{ name, uuid, type, active, device }].
    property var profiles: []

    readonly property var vpnTypes: ["tun", "wireguard", "vpn", "tap"]
    // VPN-ish links and profiles, merged by name:
    // [{ name, device, state, connected, external, uuid }]. A tun link NM
    // doesn't manage (Tailscale) is "connected (externally)": shown, not toggled.
    readonly property var vpns: {
        const out = [];
        for (const l of links) {
            if (!vpnTypes.includes(l.type) || l.state.startsWith("unmanaged"))
                continue;
            out.push({
                name: l.connection || l.device,
                device: l.device,
                state: l.state,
                connected: l.state.startsWith("connected"),
                external: l.state.includes("externally"),
                uuid: profiles.find(p => p.name === l.connection)?.uuid ?? ""
            });
        }
        for (const p of profiles) {
            if (!["vpn", "wireguard"].includes(p.type) || out.some(v => v.name === p.name))
                continue;
            out.push({ name: p.name, device: p.device, state: p.active ? "connected" : "disconnected", connected: p.active, external: false, uuid: p.uuid });
        }
        return out;
    }
    readonly property bool vpnActive: vpns.some(v => v.connected)

    // Wi-Fi bars for a 0..1 signal.
    function bars(s) {
        return s >= 0.75 ? "󰤨" : s >= 0.5 ? "󰤥" : s >= 0.25 ? "󰤢" : s > 0.05 ? "󰤟" : "󰤯";
    }

    readonly property string icon: {
        if (wifiNetwork)
            return bars(wifiNetwork.signalStrength);
        if (wired)
            return "󰈀";
        if (wifiDevice && !Networking.wifiEnabled)
            return "󰤮";
        return wifiDevice ? "󰤯" : "󰲛";
    }

    function secured(n) {
        return n && n.security !== undefined && n.security !== WifiSecurityType.Open && n.security !== WifiSecurityType.Unknown;
    }

    function speedText(mbit) {
        if (!mbit)
            return "";
        return mbit >= 1000 ? `${mbit / 1000} Gb/s` : `${mbit} Mb/s`;
    }

    // ── nmcli ────────────────────────────────────────────────────────────
    // Split one `nmcli -t` line (":" separated, "\:" escaped).
    function fields(line) {
        const out = [];
        let cur = "";
        for (let i = 0; i < line.length; i++) {
            const c = line[i];
            if (c === "\\" && i + 1 < line.length) {
                cur += line[++i];
            } else if (c === ":") {
                out.push(cur);
                cur = "";
            } else
                cur += c;
        }
        out.push(cur);
        return out;
    }

    function refresh() {
        if (!linkProbe.running)
            linkProbe.running = true;
        if (!profileProbe.running)
            profileProbe.running = true;
    }

    onEnabledChanged: if (enabled)
        refresh()
    Component.onCompleted: if (enabled)
        refresh()

    Process {
        id: linkProbe
        command: ["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device"]
        stdout: StdioCollector {
            onStreamFinished: root.links = text.split("\n").filter(l => l !== "").map(l => {
                    const f = root.fields(l);
                    return { device: f[0], type: f[1], state: f[2] ?? "", connection: f[3] ?? "" };
                })
        }
    }

    Process {
        id: profileProbe
        command: ["nmcli", "-t", "-f", "NAME,UUID,TYPE,ACTIVE,DEVICE", "connection", "show"]
        stdout: StdioCollector {
            onStreamFinished: root.profiles = text.split("\n").filter(l => l !== "").map(l => {
                    const f = root.fields(l);
                    return { name: f[0], uuid: f[1], type: f[2], active: f[3] === "yes", device: f[4] ?? "" };
                })
        }
    }

    // Any NetworkManager change → re-read (debounced).
    Process {
        running: root.enabled
        command: ["nmcli", "monitor"]
        stdout: SplitParser {
            onRead: _ => debounce.restart()
        }
    }
    Timer {
        id: debounce
        interval: 400
        onTriggered: root.refresh()
    }

    // ── Details (⌥-click) ────────────────────────────────────────────────
    // iface → { ip, ip6, router, dns, mac }; ap → { channel, band, rate, bssid, signal }
    property var details: ({})
    property var apInfo: ({})

    function loadDetails(iface) {
        if (!iface)
            return;
        const p = detailsProc.createObject(root, { iface: iface });
        p.running = true;
    }

    function loadAp(iface) {
        if (!iface)
            return;
        apProc.command = ["nmcli", "-t", "-f", "IN-USE,SSID,BSSID,CHAN,FREQ,RATE,SIGNAL,SECURITY", "device", "wifi", "list", "ifname", iface, "--rescan", "no"];
        if (!apProc.running)
            apProc.running = true;
    }

    Component {
        id: detailsProc
        Process {
            id: p
            property string iface
            command: ["nmcli", "-t", "-f", "GENERAL.HWADDR,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS,IP6.ADDRESS", "device", "show", iface]
            stdout: StdioCollector {
                onStreamFinished: {
                    const d = { ip: [], ip6: [], router: "", dns: [], mac: "" };
                    for (const line of text.split("\n")) {
                        const i = line.indexOf(":");
                        if (i < 0)
                            continue;
                        const k = line.slice(0, i);
                        const v = line.slice(i + 1).replace(/\\:/g, ":");
                        if (k.startsWith("IP4.ADDRESS"))
                            d.ip.push(v);
                        else if (k.startsWith("IP6.ADDRESS") && !v.startsWith("fe80"))
                            d.ip6.push(v);
                        else if (k === "IP4.GATEWAY")
                            d.router = v;
                        else if (k.startsWith("IP4.DNS"))
                            d.dns.push(v);
                        else if (k === "GENERAL.HWADDR")
                            d.mac = v;
                    }
                    const m = Object.assign({}, root.details);
                    m[p.iface] = d;
                    root.details = m;
                    p.destroy();
                }
            }
        }
    }

    Process {
        id: apProc
        stdout: StdioCollector {
            onStreamFinished: {
                const m = {};
                for (const line of text.split("\n")) {
                    const f = root.fields(line);
                    if (f.length < 8)
                        continue;
                    const freq = parseInt(f[4]);
                    m[f[1]] = {
                        inUse: f[0] === "*",
                        bssid: f[2],
                        channel: f[3],
                        band: freq >= 5925 ? "6 GHz" : freq >= 4900 ? "5 GHz" : "2.4 GHz",
                        rate: f[5],
                        signal: parseInt(f[6]),
                        security: f[7]
                    };
                }
                root.apInfo = m;
            }
        }
    }

    // ── Actions ──────────────────────────────────────────────────────────
    // Hidden ("Other Network…") or any SSID by name, with an optional password.
    signal joinFinished(bool ok, string message)

    function join(ssid, password, hidden) {
        const cmd = ["nmcli", "device", "wifi", "connect", ssid];
        if (password)
            cmd.push("password", password);
        if (wifiDevice)
            cmd.push("ifname", wifiDevice.name);
        if (hidden)
            cmd.push("hidden", "yes");
        joinProc.command = cmd;
        joinProc.running = true;
    }

    Process {
        id: joinProc
        stderr: StdioCollector {
            id: joinErr
        }
        onExited: code => root.joinFinished(code === 0, code === 0 ? "" : (joinErr.text.trim() || `nmcli exited with ${code}`))
    }

    function setVpn(v, up) {
        if (!v.uuid || v.external)
            return;
        Quickshell.execDetached(["nmcli", "connection", up ? "up" : "down", "uuid", v.uuid]);
    }
}
