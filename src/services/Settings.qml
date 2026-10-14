pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Shell settings, editable at runtime (PLAN §4.1).
//
// The values below are the product defaults (layer 1). Runtime changes —
// from the settings app, the wallpaper picker, the Control Center — are
// written to $STUDIO_STATE_DIR/overrides/shell.json (layer 3), which is also
// read back here, so they persist. `studio save` will promote them into the
// consumer's Nix defaults (layer 2, not wired yet).
Singleton {
    id: root

    readonly property string stateDir: Quickshell.env("STUDIO_STATE_DIR") || `${Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"}/studio-linux`
    readonly property string file: `${stateDir}/overrides/shell.json`

    readonly property alias dock: settings.dock
    readonly property alias island: settings.island
    readonly property alias wallpaper: settings.wallpaper
    readonly property alias appearance: settings.appearance

    FileView {
        id: view
        watchChanges: true
        // A missing overrides file just means "all defaults".
        printErrors: false
        onFileChanged: reload()
        // Writes from the shell persist immediately.
        onAdapterUpdated: writeAdapter()
        // First run: create the file (and its directory) with the defaults.
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) {
                mkdir.running = true;
            }
        }

        JsonAdapter {
            id: settings

            property JsonObject dock: JsonObject {
                // Desktop-entry ids / niri app-ids, left to right.
                property list<string> pinned: ["org.gnome.Nautilus", "firefox", "kitty", "com.mitchellh.ghostty", "obsidian"]
                property real iconSize: 48
                property real magnification: 1.3
            }

            property JsonObject island: JsonObject {
                // Alert border when a temperature (°C) or load (0..1) exceeds these.
                property real maxTemp: 95
                property real maxLoad: 0.92
                property int focusMinutes: 25
            }

            property JsonObject wallpaper: JsonObject {
                // An image path; empty = the theme's wallpaper.
                property string path: ""
                // Where the picker looks for images.
                property string directory: "~/Pictures/Wallpapers"
            }

            property JsonObject appearance: JsonObject {
                // Runtime overrides on top of the theme (-1 / "" = theme value).
                property real glassOpacity: -1
                property int blur: -1 // -1 theme, 0 off, 1 on
            }
        }
    }

    // Set imperatively so it can be re-pointed after first-run creation.
    Component.onCompleted: view.path = file

    Process {
        id: mkdir
        command: ["mkdir", "-p", `${root.stateDir}/overrides`]
        onExited: {
            view.writeAdapter();
            // The watch can't attach to a file that didn't exist; re-point
            // the view now that it does, so later edits are picked up.
            view.path = "";
            view.path = root.file;
        }
    }
}
