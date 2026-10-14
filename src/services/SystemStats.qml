pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// CPU and memory usage from /proc (no polling processes). Only samples while
// something reads it (`active`), e.g. the island's system page is visible.
Singleton {
    id: root

    property bool active: false
    property real cpu: 0 // 0..1
    property real memory: 0 // 0..1
    property real memoryUsedGiB: 0
    property real memoryTotalGiB: 0

    property var lastCpu: null

    Timer {
        interval: 1500
        running: root.active
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            stat.reload();
            meminfo.reload();
        }
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
}
