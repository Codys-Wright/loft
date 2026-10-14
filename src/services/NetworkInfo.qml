pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Network details for the System Monitor's Network page: local addresses
// (`ip -j addr`, refreshed while the page is shown) and an on-demand speed
// test (librespeed-cli; nothing runs until the button is pressed).
// Live traffic and totals come from SystemStats (/proc/net/dev).
Singleton {
    id: root

    // [{ iface, family: "inet" | "inet6", address, prefix, state }] — global scope only.
    property var addresses: []

    property bool speedRunning: false
    // { download, upload (Mbit/s), ping, jitter (ms), server, at (Date) } | null
    property var speedResult: null
    property string speedError: ""

    function refresh() {
        if (!addrProbe.running)
            addrProbe.running = true;
    }

    function addressesOf(iface) {
        return addresses.filter(a => a.iface === iface);
    }

    function runSpeedTest() {
        if (speedRunning)
            return;
        speedError = "";
        speedRunning = true;
        speedTest.running = true;
    }

    function cancelSpeedTest() {
        if (speedRunning)
            speedTest.signal(15);
    }

    Process {
        id: addrProbe
        command: ["ip", "-j", "addr"]
        stdout: StdioCollector {
            onStreamFinished: {
                let links = [];
                try {
                    links = JSON.parse(text);
                } catch (e) {
                    return;
                }
                const out = [];
                for (const l of links) {
                    if (l.ifname === "lo")
                        continue;
                    for (const a of l.addr_info ?? []) {
                        if (a.scope === "host")
                            continue;
                        out.push({
                            iface: l.ifname,
                            family: a.family,
                            address: a.local,
                            prefix: a.prefixlen,
                            scope: a.scope,
                            state: l.operstate
                        });
                    }
                }
                // IPv4 first, then global IPv6 before link-local.
                out.sort((a, b) => a.family.localeCompare(b.family) || (a.scope === "link") - (b.scope === "link"));
                root.addresses = out;
            }
        }
    }

    // stdout and stderr in one stream, ending with the exit code: the JSON
    // result is one line, anything else is an error message.
    Process {
        id: speedTest
        command: ["sh", "-c", "if ! command -v librespeed-cli >/dev/null; then echo 'librespeed-cli is not installed'; echo EXIT:127; exit; fi; librespeed-cli --json 2>&1 & pid=$!; trap 'kill $pid; wait $pid; echo EXIT:143; exit' TERM; wait $pid; echo EXIT:$?"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.speedRunning = false;
                const lines = text.trim().split("\n");
                const code = Number((lines.pop() ?? "").replace("EXIT:", ""));
                const json = lines.find(l => l.startsWith("[") || l.startsWith("{"));
                try {
                    const r = JSON.parse(json);
                    const x = Array.isArray(r) ? r[0] : r;
                    root.speedResult = {
                        download: Number(x.download),
                        upload: Number(x.upload),
                        ping: Number(x.ping),
                        jitter: Number(x.jitter),
                        server: x.server?.name ?? "",
                        at: new Date()
                    };
                } catch (e) {
                    const err = lines.filter(l => l.trim() !== "").pop() ?? "";
                    root.speedError = code === 143 ? "Cancelled" : err || `Speed test failed (exit ${code})`;
                }
            }
        }
    }
}
