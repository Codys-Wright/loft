pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// When idle: lock after, displays off after, suspend after, the lock's grace
// and lock before sleep (Settings → Lock Screen → When Idle; Settings.idle).
//
// Under niri, swayidle does the lock and displays-off with programs.loft.idle
// (nix/modules/home.nix); these settings aren't read there yet. Under KWin,
// idle is Plasma's (kscreenlocker in KWin, PowerDevil), so the shell writes
// the effective values into kscreenlockerrc / powerdevilrc at start and on
// every change (`loft idle apply`, cli/loft/kdeidle.py), and both reload
// live. Loft's unit gives KDE's own values back when it stops (`loft idle
// revert`, docs/KWIN.md §4.20).
Singleton {
    id: root

    readonly property bool kde: Compositor.backend === "kwin"
    readonly property var cfg: Settings.idle

    // `loft idle status --json`: { settings, kde, matches, applied }
    property var status: null
    property string error: ""
    readonly property var effective: status?.settings ?? null
    readonly property var kdeValues: status?.kde ?? null
    readonly property bool matches: status?.matches ?? false

    // What the shell passes: Settings.idle as it is now (not yet on disk).
    readonly property string given: JSON.stringify({
        lockAfter: cfg.lockAfter,
        screenOffAfter: cfg.screenOffAfter,
        suspendAfter: cfg.suspendAfter,
        lockGrace: cfg.lockGrace,
        lockOnResume: cfg.lockOnResume
    })
    onGivenChanged: schedule()
    onKdeChanged: schedule()
    Component.onCompleted: schedule()

    function schedule() {
        if (kde)
            debounce.restart();
        else
            refresh();
    }

    function refresh() {
        if (statusProc.running)
            return;
        statusProc.command = ["loft", "idle", "status", "--json", "--settings", given];
        statusProc.running = true;
    }

    function set(key, value) {
        cfg[key] = value;
    }

    // "5 min", "30 s", "1 h 30 min", "Never".
    function format(seconds) {
        if (!(seconds > 0))
            return "Never";
        if (seconds < 60)
            return `${seconds} s`;
        const m = Math.round(seconds / 60);
        if (m < 60)
            return `${m} min`;
        return m % 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : `${m / 60} h`;
    }

    Timer {
        id: debounce
        interval: 400
        onTriggered: {
            if (applyProc.running) {
                restart();
                return;
            }
            root.error = "";
            applyProc.command = ["loft", "idle", "apply", "--settings", root.given];
            applyProc.running = true;
        }
    }

    Process {
        id: applyProc
        stdout: SplitParser {
            onRead: line => {
                if (/not running|not told/.test(line))
                    console.warn(`Idle: ${line}`);
            }
        }
        stderr: StdioCollector {
            id: applyErr
        }
        onExited: code => {
            if (code !== 0) {
                root.error = applyErr.text.trim().split("\n").pop() || `loft idle apply failed (${code})`;
                console.warn(`Idle: ${root.error}`);
            }
            root.refresh();
        }
    }

    Process {
        id: statusProc
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
}
