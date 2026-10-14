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
    readonly property alias displays: settings.displays
    readonly property alias island: settings.island
    readonly property alias wallpaper: settings.wallpaper
    readonly property alias appearance: settings.appearance
    readonly property alias system: settings.system
    readonly property alias sound: settings.sound
    // Feature id → on/off (Features.qml); absent = the module's default.
    property alias features: settings.features
    readonly property alias lock: settings.lock
    // Per-theme choices, keyed by theme name (Vibes.qml reads and writes
    // them): { "<theme>": { wallpaper, rotate, perWorkspace, lockDesign } }.
    // A key a theme doesn't have falls back to the global value above it.
    property alias perTheme: settings.perTheme
    // Menu bar module (AppMenu.pref): key → value; absent = the default.
    property alias menubar: settings.menubar
    // Control Center layout and the menu bar's status items (Controls.qml).
    property alias controlCenter: settings.controlCenter

    FileView {
        id: view
        watchChanges: true
        // A missing overrides file just means "all defaults".
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.migrate()
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

            // Which display carries the dock and the bar's status area (see
            // Displays.qml). niri identity ("Make Model Serial") or connector
            // name; "" = automatic (largest display / the one to its right).
            property JsonObject displays: JsonObject {
                property string main: ""
                property string fallback: ""
            }

            property JsonObject island: JsonObject {
                // Alert border when a temperature (°C) or load (0..1) exceeds these.
                property real maxTemp: 95
                property real maxLoad: 0.92
                property int focusMinutes: 25
            }

            property JsonObject wallpaper: JsonObject {
                // An image path; empty = the theme's wallpaper. (Global
                // fallback: the pickers store their choice per theme.)
                property string path: ""
                // Where the picker looks for images.
                property string directory: "~/Pictures/Wallpapers"
                // Cycle through the theme's collection every N minutes (0 = off).
                property real rotate: 0
                // A different wallpaper of the collection per niri workspace.
                property bool perWorkspace: false
            }

            property var features: ({})
            property JsonObject lock: JsonObject {
                // A lock design directory, "builtin", or "" = the theme's default.
                property string design: ""
            }

            property var perTheme: ({})

            property var menubar: ({})

            property var controlCenter: ({})

            property JsonObject appearance: JsonObject {
                // Runtime overrides on top of the theme (-1 / "" = theme value).
                // The Liquid Glass slider, 0 ultraclear … 1 fully tinted
                // (-1 = the theme's glass.opacity).
                property real glass: -1
                // Before the slider: a plain glass-opacity override. Read once
                // and moved into `glass` (same scale), then reset.
                property real glassOpacity: -1
                property int blur: -1 // -1 theme, 0 off, 1 on
                // Flat opaque fills and no blur, everywhere.
                property bool reduceTransparency: false
                // Menu bar: -1 theme (bar.background / bar.adaptiveText), 0 off, 1 on.
                property int barBackground: -1
                property int barAdaptiveText: -1
            }

            // System module (Settings → System): bar readouts and alerts.
            property JsonObject system: JsonObject {
                // Bar readouts, left to right: cpu, memory, cpuTemp, gpu, network, battery.
                property list<string> readouts: ["cpu", "memory"]
                // Alerts (notifications) — each needs the condition to hold
                // for a while, and re-arms only after it clears (hysteresis).
                property bool alertCpu: true
                property real cpuThreshold: 0.9 // 0..1
                property int cpuSeconds: 60
                property bool alertTemp: true // above Settings.island.maxTemp
                property bool alertMemory: true
                property real memoryPressure: 20 // PSI "some" avg10, %
                property bool alertDisk: true
                property real diskThreshold: 0.9 // any mounted fs, 0..1
                property bool alertBattery: true
                property int batteryThreshold: 15 // %
            }

            property JsonObject sound: JsonObject {
                // Mixer favorites (application names), top to bottom.
                property list<string> pinned: []
                // Per-app volume goes up to 150 % when on.
                property bool boost: true
                // Live level meters open small capture streams on the real
                // graph while the mixer is visible — off unless asked for.
                property bool meters: false
                // Lower the new output when headphones / a Bluetooth sink disappear.
                property bool safeOnUnplug: true
                property real safeVolume: 0.3
                // Bar mic icon while an app records or the mics are muted.
                property bool micIndicator: true
            }
        }
    }

    // Settings written by older versions.
    function migrate() {
        // appearance.glassOpacity → the Liquid Glass slider (same 0..1 scale).
        if (settings.appearance.glassOpacity >= 0) {
            if (settings.appearance.glass < 0)
                settings.appearance.glass = settings.appearance.glassOpacity;
            settings.appearance.glassOpacity = -1;
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
