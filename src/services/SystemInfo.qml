pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// This computer, for the system menu's About This Computer and its Log Out
// label: host, OS, kernel, CPU, GPU, memory, uptime, the user's name.
// Read once at startup (one small shell script over /etc and /proc) and
// again whenever About opens (uptime moves).
Singleton {
    id: root

    property string host: ""
    property string os: "" // "NixOS 26.11 (Xantusia)"
    property string osVersion: "" // "26.11.20261001.abcdef0"
    property string kernel: ""
    property string cpu: ""
    property int cores: 0
    property string gpu: ""
    property real memoryGiB: 0
    property real uptime: 0 // seconds
    property string user: Quickshell.env("USER") || ""
    property string fullName: "" // the account's GECOS name, if any
    // Suspend may not come back on NVIDIA (Spotlight's Sleep says the same).
    property bool nvidia: false

    readonly property string displayName: fullName || user

    // [[label, value]] for About This Computer and Settings → About
    // (empty values left out).
    readonly property var details: [["Host", host], ["OS", os], ["Version", osVersion], ["Kernel", kernel], ["Processor", cpu + (cores > 0 ? ` (${cores} threads)` : "")], ["Graphics", gpu], ["Memory", memoryGiB > 0 ? `${Math.round(memoryGiB)} GB` : ""], ["Uptime", uptime > 0 ? formatUptime(uptime) : ""], ["User", fullName && fullName !== user ? `${fullName} (${user})` : user]].filter(r => r[1] !== "")

    function refresh() {
        probe.running = true;
    }

    function formatUptime(s) {
        const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
        const parts = [];
        if (d > 0)
            parts.push(`${d} day${d === 1 ? "" : "s"}`);
        if (h > 0)
            parts.push(`${h} hour${h === 1 ? "" : "s"}`);
        if (d === 0)
            parts.push(`${m} minute${m === 1 ? "" : "s"}`);
        return parts.join(", ");
    }

    Component.onCompleted: refresh()

    Process {
        id: probe
        command: ["sh", "-c", `
. /etc/os-release 2>/dev/null
echo "host=$(cat /proc/sys/kernel/hostname 2>/dev/null)"
echo "os=\${PRETTY_NAME:-\${NAME:-Linux}}"
echo "osVersion=\${BUILD_ID:-\${VERSION_ID:-}}"
echo "kernel=$(uname -r)"
echo "cpu=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -n1)"
echo "cores=$(nproc 2>/dev/null)"
gpu=""
if command -v nvidia-smi >/dev/null 2>&1; then gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1); fi
if [ -z "$gpu" ] && command -v lspci >/dev/null 2>&1; then gpu=$(lspci 2>/dev/null | sed -n 's/^[^ ]* \\(VGA compatible controller\\|3D controller\\|Display controller\\): //p' | head -n1); fi
echo "gpu=$gpu"
echo "nvidia=$([ -e /proc/driver/nvidia ] && echo 1 || echo 0)"
echo "mem=$(sed -n 's/^MemTotal: *\\([0-9]*\\) kB/\\1/p' /proc/meminfo)"
echo "uptime=$(cut -d' ' -f1 /proc/uptime)"
echo "fullName=$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f5 | cut -d, -f1)"
`]
        stdout: StdioCollector {
            onStreamFinished: {
                const v = {};
                for (const line of text.split("\n")) {
                    const i = line.indexOf("=");
                    if (i > 0)
                        v[line.slice(0, i)] = line.slice(i + 1).trim();
                }
                root.host = v.host ?? "";
                root.os = v.os ?? "";
                root.osVersion = v.osVersion ?? "";
                root.kernel = v.kernel ?? "";
                root.cpu = (v.cpu ?? "").replace(/\s+/g, " ");
                root.cores = Number(v.cores) || 0;
                root.gpu = v.gpu ?? "";
                root.nvidia = v.nvidia === "1";
                root.memoryGiB = (Number(v.mem) || 0) / 1048576;
                root.uptime = Number(v.uptime) || 0;
                root.fullName = v.fullName ?? "";
            }
        }
    }
}
