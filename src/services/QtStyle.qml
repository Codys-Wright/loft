pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Settings → Appearance → "Theme all Qt apps": the global Qt style
// (cli/loft/qtglobal.py, programs.loft.qt.global). Status from `loft qt
// global status --json`; the switch runs `loft qt global on|off`, which
// applies / reverts at once while the shell runs. Following theme changes is
// the CLI's `qt` hook, not this.
Singleton {
    id: root

    property var status: null
    property bool busy: false
    property string error: ""

    // Only with programs.loft.qt (its qt.json): Kvantum is installed then.
    readonly property bool configured: status?.configured ?? false
    readonly property bool enabled: status?.enabled ?? false
    readonly property bool applied: status?.applied ?? false

    function refresh() {
        if (!statusProc.running)
            statusProc.running = true;
    }

    function setEnabled(on) {
        if (busy)
            return;
        busy = true;
        error = "";
        actionProc.command = ["loft", "qt", "global", on ? "on" : "off"];
        actionProc.running = true;
    }

    Component.onCompleted: refresh()

    // A theme change re-applies it (the `qt` hook): show the new values.
    Connections {
        target: Theme
        function onNameChanged() {
            root.refresh();
        }
    }

    Process {
        id: statusProc
        command: ["loft", "qt", "global", "status", "--json"]
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
        id: actionProc
        stderr: StdioCollector {
            id: actionErr
        }
        onExited: (code, status) => {
            root.busy = false;
            if (code !== 0)
                root.error = (actionErr.text.trim().split("\n").pop() || `loft qt global failed (${code})`).replace(/^loft qt global: /, "");
            root.refresh();
        }
    }
}
