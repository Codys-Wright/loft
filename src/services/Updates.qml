pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Flake updates (Utilities → Updates), NixOS's "App updates": the summary of
// what `nix flake update` would change, from `loft updates check`
// (cli/loft/updates.py: a scratch copy of the flake is updated, the real one
// is only read; nothing is built or switched). The result is cached in
// <state>/cache/updates.json, watched here; Refresh re-runs the check (about
// a minute: it fetches every input). "Update…" only shows the commands.
Singleton {
    id: root

    readonly property string file: `${Settings.stateDir}/cache/updates.json`

    property var summary: null // the cached result, or null
    property bool running: false
    property string stage: ""
    property string error: ""
    property real startedAt: 0

    readonly property var changed: (summary?.inputs ?? []).filter(i => i.changed)
    readonly property var unchanged: (summary?.inputs ?? []).filter(i => !i.changed && !i.follows)
    readonly property string commandText: (summary?.commands ?? []).join(" && ")

    function refresh() {
        if (running)
            return;
        error = "";
        stage = "starting";
        startedAt = Date.now();
        running = true;
        checker.running = true;
    }

    FileView {
        path: root.file
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                root.summary = JSON.parse(text());
            } catch (e) {
                root.summary = null;
            }
        }
        onLoadFailed: root.summary = null
    }

    Process {
        id: checker
        command: ["loft", "updates", "check"]
        stdout: SplitParser {
            onRead: line => {
                try {
                    const m = JSON.parse(line);
                    if (m.stage === "done") {
                        root.error = m.error ?? "";
                    } else if (m.stage) {
                        root.stage = m.stage;
                    }
                } catch (e) {}
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "" && root.error === "")
                root.error = text.trim().split("\n").pop()
        }
        onExited: (code, status) => {
            root.running = false;
            root.stage = "";
        }
    }

    function copyCommands() {
        if (commandText !== "")
            Quickshell.execDetached(["sh", "-c", 'printf %s "$1" | wl-copy >/dev/null 2>&1', "sh", commandText]);
    }

    function openUrl(url) {
        if (url)
            Quickshell.execDetached(["xdg-open", url]);
    }

    // "3 days ago", "Mar 4".
    function ago(seconds) {
        if (!seconds)
            return "";
        const d = (Date.now() / 1000 - seconds);
        if (d < 90)
            return "just now";
        if (d < 3600)
            return `${Math.round(d / 60)} min ago`;
        if (d < 86400 * 1.5)
            return `${Math.round(d / 3600)} h ago`;
        if (d < 86400 * 45)
            return `${Math.round(d / 86400)} days ago`;
        return Qt.formatDate(new Date(seconds * 1000), "MMM d, yyyy");
    }

    function shortRev(r) {
        return r ? String(r).slice(0, 7) : "—";
    }
}
