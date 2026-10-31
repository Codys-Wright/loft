pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Fan control (System Monitor → Disks & Sensors, issue #7): `loft fans
// status` (cli/loft/fans.py) every 3 s while that page is open — every hwmon
// pwm output, writable or not, its setting, what the root loft-fans service
// last applied, and the temperatures a curve can follow. Changes go through
// `loft fans manual|curve|auto`, which runs the privileged helper through
// pkexec (programs.loft.fanControl in the NixOS module); the shell itself
// never writes /sys. Without the module every fan shows read-only.
Singleton {
    id: root

    readonly property bool active: SystemStats.monitorOpen && SystemStats.monitorSection === "disks"

    property var status: null
    readonly property bool enabled: status?.enabled ?? false
    readonly property bool daemon: status?.daemon ?? false
    readonly property var fans: status?.fans ?? []
    readonly property var temps: status?.temps ?? []
    readonly property real minPercent: status?.minPercent ?? 25
    readonly property bool allowStop: status?.allowStop ?? false
    readonly property real criticalTemp: status?.criticalTemp ?? 90
    property string error: ""
    property bool busy: false

    // The default temperature for a new curve / the manual critical guard:
    // the CPU's (Tctl / Package), else the first sensor.
    readonly property string defaultSource: (temps.find(t => t.cpu) ?? temps[0])?.id ?? ""

    // Starting points for a new curve (°C → %).
    readonly property var presets: ({
            quiet: [[40, 25], [60, 35], [75, 60], [85, 100]],
            balanced: [[35, 30], [55, 45], [70, 70], [82, 100]],
            performance: [[30, 45], [50, 60], [65, 85], [75, 100]]
        })

    onActiveChanged: if (active)
        refresh()

    function refresh() {
        if (!probe.running)
            probe.running = true;
    }

    function tempLabel(id) {
        const t = temps.find(x => x.id === id);
        return t ? `${t.chip} · ${t.label}` : id;
    }

    // The status' stable key for a temperature → its id this boot.
    function tempId(key) {
        return temps.find(t => t.key === key)?.id ?? "";
    }

    function setAuto(fan) {
        run(["loft", "fans", "auto", fan.id]);
    }

    function setManual(fan, percent, stop) {
        const src = tempId(fan.setting.source ?? "") || defaultSource;
        run(["loft", "fans", "manual", fan.id, String(Math.round(percent))].concat(src ? ["--source", src] : []).concat(stop ? ["--allow-stop"] : []));
    }

    function setCurve(fan, source, points, stop) {
        const pts = points.map(p => `${Math.round(p[0])}:${Math.round(p[1])}`).join(",");
        run(["loft", "fans", "curve", fan.id, source, pts].concat(stop ? ["--allow-stop"] : []));
    }

    function run(argv) {
        error = "";
        busy = true;
        setter.command = argv;
        setter.running = true;
    }

    Process {
        id: probe
        command: ["loft", "fans", "status", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.status = JSON.parse(text);
                } catch (e) {
                    root.status = null;
                }
            }
        }
    }

    Process {
        id: setter
        stderr: StdioCollector {
            onStreamFinished: root.error = text.trim().replace(/^loft: /, "")
        }
        onExited: {
            root.busy = false;
            root.refresh();
        }
    }

    Timer {
        interval: 3000
        repeat: true
        running: root.active
        onTriggered: root.refresh()
    }
}
