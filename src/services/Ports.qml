pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Port manager (Utilities → Ports): listening TCP / bound UDP sockets from
// `loft ports list` (cli/loft/ports.py), refreshed every 3 s while the page
// is on screen. Stop sends SIGTERM to one of your own processes (the CLI
// refuses anything else and re-checks the port), then watches it: still
// alive after 3 s → `stuck` offers Force Quit (SIGKILL).
Singleton {
    id: root

    readonly property bool active: Utilities.open && Utilities.section === "ports"

    property var ports: []
    property bool loaded: false
    property string error: ""
    property string notice: ""
    // Filters (kept for the session).
    property bool devOnly: false
    property bool showUdp: false
    property bool showOthers: true // root's / other users' sockets
    property string query: ""

    // { row, phase: "confirm" | "stopping" | "stuck" } — the stop flow.
    property var pending: null

    readonly property var filtered: ports.filter(p => {
        if (devOnly && !p.dev)
            return false;
        if (!showUdp && p.proto === "udp")
            return false;
        if (!showOthers && !p.mine)
            return false;
        if (query === "")
            return true;
        const q = query.toLowerCase();
        const pr = p.process ?? {};
        return String(p.port).includes(q) || (pr.name ?? "").toLowerCase().includes(q) || (pr.project?.name ?? "").toLowerCase().includes(q) || (pr.command ?? "").toLowerCase().includes(q);
    })
    readonly property int devCount: ports.filter(p => p.dev).length

    function refresh() {
        if (!lister.running)
            lister.running = true;
    }

    onActiveChanged: if (active)
        refresh()

    Timer {
        interval: 3000
        repeat: true
        running: root.active && root.pending === null
        onTriggered: root.refresh()
    }

    Process {
        id: lister
        command: ["loft", "ports", "list", "--probe"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.ports = JSON.parse(text).ports ?? [];
                    root.error = "";
                } catch (e) {
                    root.error = "Couldn't read the port list.";
                }
                root.loaded = true;
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "")
                root.error = text.trim().split("\n").pop()
        }
    }

    // ── Stop ────────────────────────────────────────────────────────────
    function ask(row) {
        notice = "";
        pending = {
            row: row,
            phase: "confirm"
        };
    }

    function cancel() {
        pending = null;
    }

    function stop(force) {
        if (!pending)
            return;
        const r = pending.row;
        pending = {
            row: r,
            phase: "stopping",
            force: force
        };
        stopper.command = ["loft", "ports", "stop", String(r.pid), "--port", String(r.port)].concat(force ? ["--force"] : []);
        stopper.running = true;
    }

    Process {
        id: stopper
        stdout: StdioCollector {
            onStreamFinished: {
                let res = null;
                try {
                    res = JSON.parse(text);
                } catch (e) {}
                if (!res || !res.ok) {
                    root.notice = res?.error ?? "Couldn't stop it.";
                    root.pending = null;
                    root.refresh();
                    return;
                }
                checkAlive.restart();
            }
        }
    }

    // Did it go? Check a few times over 3 s.
    property int checks: 0
    Timer {
        id: checkAlive
        interval: 500
        onTriggered: {
            if (!root.pending)
                return;
            aliveProc.command = ["loft", "ports", "alive", String(root.pending.row.pid)];
            aliveProc.running = true;
        }
    }

    Process {
        id: aliveProc
        stdout: StdioCollector {
            onStreamFinished: {
                if (!root.pending)
                    return;
                let alive = true;
                try {
                    alive = JSON.parse(text).alive;
                } catch (e) {}
                const p = root.pending;
                if (!alive) {
                    root.notice = `Stopped ${p.row.process?.name ?? "process"} (port ${p.row.port}).`;
                    root.pending = null;
                    root.checks = 0;
                    root.refresh();
                } else if (++root.checks >= 6 && !p.force) {
                    root.checks = 0;
                    root.pending = {
                        row: p.row,
                        phase: "stuck"
                    };
                } else if (root.checks >= 6) {
                    root.notice = `${p.row.process?.name ?? "It"} didn't exit.`;
                    root.checks = 0;
                    root.pending = null;
                } else {
                    checkAlive.restart();
                }
            }
        }
    }

    function openUrl(url) {
        if (url)
            Quickshell.execDetached(["xdg-open", url]);
    }

    function openFolder(path) {
        if (path)
            Quickshell.execDetached(["xdg-open", path]);
    }
}
