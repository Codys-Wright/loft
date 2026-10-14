pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Settings of the Clipboard & files and Scratchpad modules (clipboard
// history, auto-clear, clean URL, shelf, snippets, scratchpad), editable in
// Settings → Clipboard. Runtime overrides like Settings.qml, but in their own
// file — <state>/overrides/clipboard.json — so modules don't share one adapter.
Singleton {
    id: root

    readonly property string stateDir: Settings.stateDir
    readonly property string file: `${stateDir}/overrides/clipboard.json`

    readonly property alias history: cfg.history
    readonly property alias autoClear: cfg.autoClear
    readonly property alias paste: cfg.paste
    readonly property alias shelf: cfg.shelf
    readonly property alias scratchpad: cfg.scratchpad
    property alias cleanUrls: cfg.cleanUrls

    // "~/x" → "$HOME/x".
    function expand(path) {
        return path.startsWith("~/") ? Quickshell.env("HOME") + path.slice(1) : path;
    }

    FileView {
        id: view
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onAdapterUpdated: writeAdapter()
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound)
                mkdir.running = true;
        }

        JsonAdapter {
            id: cfg

            property JsonObject history: JsonObject {
                // Run our own `wl-paste --watch cliphist store`. Turn off when
                // something else already records into the same cliphist db.
                property bool record: true
                property int maxItems: 750
            }

            property JsonObject autoClear: JsonObject {
                // Clear the system clipboard this long after the last copy
                // (0 = never). History is kept.
                property int minutes: 0
                // …and when the screen locks.
                property bool onLock: false
            }

            property JsonObject paste: JsonObject {
                // Enter in the history pastes into the focused app (else: copy only).
                property bool onSelect: true
                // Terminals paste with Ctrl+Shift+V; matched against the
                // focused window's app-id (regex).
                property string terminals: "^(foot|footclient|kitty|com\\.mitchellh\\.ghostty|Alacritty|org\\.wezfurlong\\.wezterm|org\\.kde\\.konsole|org\\.gnome\\.Console|xterm)$"
            }

            // Strip tracking parameters (utm_*, fbclid, …) from copied URLs.
            property bool cleanUrls: false

            property JsonObject shelf: JsonObject {
                property string edge: "right" // right | left
                // Slide out when a drag reaches the screen edge.
                property bool revealOnDrag: true
            }

            property JsonObject scratchpad: JsonObject {
                property string exportDir: "~/Documents/Scratchpad"
            }
        }
    }

    Component.onCompleted: view.path = file

    Process {
        id: mkdir
        command: ["mkdir", "-p", `${root.stateDir}/overrides`]
        onExited: {
            view.writeAdapter();
            view.path = "";
            view.path = root.file;
        }
    }
}
