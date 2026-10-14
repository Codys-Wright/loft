pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Who is using a camera, for the bar's green dot (macOS's camera
// indicator): PipeWire video sources linked to a stream, and processes
// holding /dev/video* open directly (OBS, browsers via v4l2) — the latter
// by a read-only scan of /proc/<pid>/fd every few seconds while the camera
// indicator is on. Microphone use comes from Sound (capture streams).
Singleton {
    id: root

    readonly property bool enabled: Features.on("cameraIndicator")

    // [{ pid, name }] holding a video device.
    property var v4l2Users: []

    // PipeWire: app streams reading a Video/Source node.
    readonly property var pwUsers: {
        const out = [];
        for (const g of Pipewire.linkGroups.values) {
            const src = g.source;
            const dst = g.target;
            if (!src || !dst || (src.properties["media.class"] ?? "") !== "Video/Source")
                continue;
            const p = dst.properties;
            out.push({ pid: parseInt(p["application.process.id"] ?? "0"), name: p["application.name"] || p["node.name"] || "App" });
        }
        return out;
    }

    readonly property var cameraUsers: {
        const seen = {};
        const out = [];
        for (const u of pwUsers.concat(v4l2Users)) {
            const k = u.pid ? String(u.pid) : u.name;
            if (seen[k])
                continue;
            seen[k] = true;
            out.push(u);
        }
        return out;
    }
    readonly property bool cameraInUse: enabled && cameraUsers.length > 0

    Timer {
        running: root.enabled
        repeat: true
        triggeredOnStart: true
        interval: 4000
        onTriggered: if (!scan.running)
            scan.running = true
    }

    Process {
        id: scan
        command: ["sh", "-c", "find /proc -mindepth 3 -maxdepth 3 -path '/proc/[0-9]*/fd/*' -lname '/dev/video*' 2>/dev/null | cut -d/ -f3 | sort -u | while read p; do printf '%s %s\\n' \"$p\" \"$(cat /proc/$p/comm 2>/dev/null)\"; done"]
        stdout: StdioCollector {
            onStreamFinished: root.v4l2Users = text.split("\n").filter(l => l.trim() !== "").map(l => {
                    const i = l.indexOf(" ");
                    return { pid: parseInt(l.slice(0, i)), name: l.slice(i + 1) || "?" };
                })
        }
    }
}
