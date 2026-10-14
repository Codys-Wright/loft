pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Settings → Appearance → Spotify: Loft's Spicetify install
// (cli/loft/spotify.py, programs.loft.spotify). Status comes from
// `loft spotify status --json`; the switch, the scheme menu and Re-apply run
// `loft spotify follow|scheme|reapply`. Recoloring on theme changes is the
// CLI's `spotify` reload hook, not this.
Singleton {
    id: root

    property var status: null // the last status, or null before the first read
    property bool busy: false
    property string error: ""
    property string note: ""

    readonly property bool configured: status?.configured ?? false
    readonly property bool setUp: status?.setUp ?? false
    readonly property bool follow: status?.follow ?? true
    readonly property string activeScheme: status?.activeScheme ?? ""
    readonly property string version: status?.installed?.version ?? status?.version ?? ""
    readonly property string pending: status?.pending ?? ""
    readonly property bool running: status?.running ?? false
    readonly property var schemes: status?.schemes ?? []
    readonly property var themeSchemes: status?.themeSchemes ?? []

    function refresh() {
        if (!statusProc.running)
            statusProc.running = true;
    }

    function setFollow(on) {
        run(["follow", on ? "on" : "off"]);
    }

    function setScheme(name) {
        run(["scheme", name]);
    }

    function reapply() {
        run(["reapply"], "Re-applied. Spotify picks up new extensions on its next start.");
    }

    function run(args, okNote) {
        if (busy)
            return;
        busy = true;
        error = "";
        note = "";
        actionProc.okNote = okNote ?? "";
        actionProc.command = ["loft", "spotify"].concat(args);
        actionProc.running = true;
    }

    Process {
        id: statusProc
        command: ["loft", "spotify", "status", "--json"]
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
        property string okNote: ""
        stderr: StdioCollector {
            id: actionErr
        }
        onExited: (code, status) => {
            root.busy = false;
            if (code !== 0)
                root.error = (actionErr.text.trim().split("\n").pop() || `loft spotify failed (${code})`).replace(/^loft: /, "");
            else
                root.note = okNote;
            root.refresh();
        }
    }

    // A theme change recolors Spotify (the hook); refresh what we show.
    Connections {
        target: Theme
        function onNameChanged() {
            root.refresh();
        }
    }
}
