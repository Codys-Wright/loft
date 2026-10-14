pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// System load and temperatures, read from /proc and /sys.
//
// Two rates: a slow background sample (cheap file reads) feeds the island's
// overheat/overload alerts; while something shows details (`detailed`, e.g.
// the island's system page) it samples faster and also queries the GPU
// (nvidia-smi on NVIDIA, sysfs gpu_busy_percent on AMD).
Singleton {
    id: root

    property bool detailed: false

    property real cpu: 0 // 0..1
    property real cpuTemp: 0 // °C
    property real memory: 0 // 0..1
    property real memoryUsedGiB: 0
    property real memoryTotalGiB: 0
    property real gpu: -1 // 0..1, -1 = unknown
    property real gpuTemp: -1

    // Alert thresholds (Settings.island). Zen 4 runs to 95 °C by design.
    readonly property real maxTemp: Settings.island.maxTemp
    readonly property real maxLoad: Settings.island.maxLoad
    readonly property bool overheating: cpuTemp > maxTemp || gpuTemp > maxTemp
    readonly property bool overloaded: cpu > maxLoad || memory > maxLoad

    property var lastCpu: null
    // hwmon temp input for the CPU package, found once at startup.
    property string cpuTempPath: ""

    Timer {
        interval: root.detailed ? 1500 : 5000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            stat.reload();
            meminfo.reload();
            if (root.cpuTempPath !== "")
                cpuTempFile.reload();
            if (root.detailed)
                gpuProbe.running = true;
        }
    }

    // Find the CPU sensor: k10temp/zenpower (AMD) or coretemp (Intel).
    Process {
        running: true
        command: ["sh", "-c", "for h in /sys/class/hwmon/hwmon*; do case $(cat $h/name) in k10temp|zenpower|coretemp) echo $h/temp1_input; exit;; esac; done"]
        stdout: StdioCollector {
            onStreamFinished: root.cpuTempPath = text.trim()
        }
    }

    FileView {
        id: cpuTempFile
        path: root.cpuTempPath
        onLoaded: root.cpuTemp = Number(text()) / 1000
    }

    FileView {
        id: stat
        path: "/proc/stat"
        onLoaded: {
            const f = text().split("\n")[0].trim().split(/\s+/).slice(1).map(Number);
            const idle = f[3] + (f[4] ?? 0);
            const total = f.reduce((a, b) => a + b, 0);
            if (root.lastCpu) {
                const dt = total - root.lastCpu.total;
                if (dt > 0)
                    root.cpu = 1 - (idle - root.lastCpu.idle) / dt;
            }
            root.lastCpu = { idle: idle, total: total };
        }
    }

    FileView {
        id: meminfo
        path: "/proc/meminfo"
        onLoaded: {
            const kb = key => Number((text().match(new RegExp(`^${key}:\\s+(\\d+)`, "m")) ?? [0, 0])[1]);
            const total = kb("MemTotal");
            const avail = kb("MemAvailable");
            if (total > 0) {
                root.memory = (total - avail) / total;
                root.memoryUsedGiB = (total - avail) / 1048576;
                root.memoryTotalGiB = total / 1048576;
            }
        }
    }

    // GPU: NVIDIA via nvidia-smi, else the first AMD/Intel sysfs busy counter.
    Process {
        id: gpuProbe
        command: ["sh", "-c", "if command -v nvidia-smi >/dev/null; then nvidia-smi --query-gpu=utilization.gpu,temperature.gpu --format=csv,noheader,nounits | head -n1; else for f in /sys/class/drm/card*/device/gpu_busy_percent; do [ -r \"$f\" ] && echo \"$(cat $f), -1\" && exit; done; fi"]
        stdout: StdioCollector {
            onStreamFinished: {
                const [use, temp] = text.trim().split(",").map(s => Number(s.trim()));
                root.gpu = isNaN(use) ? -1 : use / 100;
                root.gpuTemp = isNaN(temp) ? -1 : temp;
            }
        }
    }
}
