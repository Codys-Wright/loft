pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Shell settings, editable at runtime (PLAN §4.1).
//
// The values below are the product defaults (layer 1). Runtime changes —
// from the settings app, the wallpaper picker, the Control Center — are
// written to $LOFT_STATE_DIR/overrides/shell.json (layer 3), which is also
// read back here, so they persist. `loft save` will promote them into the
// consumer's Nix defaults (layer 2, not wired yet).
Singleton {
    id: root

    readonly property string stateDir: Quickshell.env("LOFT_STATE_DIR") || `${Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"}/loft`
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
    // The desktop's right-click menu (desktopmenu/DesktopMenu.qml):
    // { items: [{ id, shown }] } in menu order; absent = the default menu.
    property alias desktopMenu: settings.desktopMenu
    readonly property alias lock: settings.lock
    // Per-theme choices, keyed by theme name (Vibes.qml reads and writes
    // them): { "<theme>": { wallpaper, rotate, perWorkspace, lockDesign,
    // displays, workspaces, sameAll, auto, autoSeed, sets, activeSet } }
    // (the wallpaper keys: cli/loft/wallsets.py).
    // A key a theme doesn't have falls back to the global value above it.
    property alias perTheme: settings.perTheme
    // Where each image is cropped, per display role (Vibes.focusFor):
    // { "<image path>": { "<role>" | "*": [fx, fy] } } (cli/loft/wallsets.py).
    property alias wallpaperFraming: settings.wallpaperFraming
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
                // bottom | left | right
                property string position: "bottom"
                // Bounce an app's icon until its first window opens.
                property bool bounce: true
                // A dot under apps with open windows.
                property bool indicators: true
                // The recent-apps section (feature dockRecents): how many.
                property int recentCount: 3
                // Docked folders (feature dockStacks), left of the Trash:
                // { path ("xdg:DOWNLOAD", "~/Documents/Loft", /abs),
                //   sort: added|name|modified|kind, display: stack|folder,
                //   view: auto|fan|grid|list }
                property var folders: [
                    { path: "xdg:DOWNLOAD", sort: "added", display: "stack", view: "auto" }
                ]
                property bool trash: true
                // Hide until the pointer touches the screen edge: "never",
                // "always", "whenWindows" (only while the display's workspace
                // has windows). Default for displays without their own choice.
                property var autoHide: "never"
                // Per display, keyed by niri identity ("Make Model Serial"):
                // { enabled, autoHide, position }. Missing keys fall back to
                // the values above; an ultrawide (≥ 2.2:1) defaults to "whenWindows".
                property var displays: ({})
                // Window previews (feature dockPreview): open on "hover"
                // (after previewDelay ms) or on "click" (an app with several
                // windows); previewThumbnails = snapshots where niri allows
                // (off by default until the capture is verified on a GPU desktop).
                property string preview: "hover"
                property int previewDelay: 450
                property bool previewThumbnails: false
            }

            // Which display carries the dock and the bar's status area (see
            // Displays.qml). niri identity ("Make Model Serial") or connector
            // name; "" = automatic (largest display / the one to its right).
            property JsonObject displays: JsonObject {
                property string main: ""
                property string fallback: ""
            }

            property JsonObject island: JsonObject {
                // attached: hangs from the top edge like a notch (flush,
                // square top with concave shoulders, rounded bottom) |
                // floating: a pill with a gap above it.
                property string style: "attached"
                // black: a solid near-black fill like the real notch |
                // glass: the Liquid Glass material.
                property string fill: "black"
                // Volume, brightness and sound announcements widen the
                // collapsed island (Hud.qml); off = the pill above the dock.
                property bool hud: true
                // Alert border when a temperature (°C) or load (0..1) exceeds these.
                // 100 °C: desktop CPUs (Tjmax 100) are designed to boost up to it.
                property real maxTemp: 100
                property real maxLoad: 0.92
                property int focusMinutes: 25
                // Expanded pages in order, [{ id, shown }]; [] = the default
                // order (IslandPages.qml). Missing ids slot in.
                property var pages: []
                // Calendar: auto (khal / vdirsyncer, else Evolution Data
                // Server) | khal | vdirsyncer | eds | none, plus ICS files /
                // URLs (always read).
                property string calendarSource: "auto"
                property var calendarIcs: []
                // The next event takes the collapsed pill this long before it starts.
                property int eventSoonMinutes: 15
                property bool timerSound: true
                // Downloads in progress as a live activity; "" = the XDG download dir.
                property bool downloads: true
                property string downloadsDir: ""
                // Read Chromium-family browsers' History db (a private copy,
                // total_bytes only) for "% done"; off = size and speed only.
                property bool downloadsBrowserHistory: true
                // AI agents page (Claude Code / Codex usage from their local
                // logs, counts only) and the running-agents mark in the pill.
                property bool ai: true
                property bool aiIndicator: true
                // Synced lyrics from lrclib.net (sends artist + title there).
                property bool lyrics: false
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
                // On a niri with per-workspace layers (niri-loft): each
                // workspace's wallpaper slides with it and shows behind it in
                // the overview (WorkspaceWallpapers). Off: swap on switch.
                property bool moveWithWorkspaces: true
                // Live (video) wallpapers (VideoWallpapers): "play", or
                // "still" = only ever their still frame.
                property string video: "play"
                // Hold the video (paused, no decoding) while a window fills
                // the screen (not only fullscreen opaque ones), on battery /
                // in power saver, after N idle minutes (0 = never).
                property bool pauseWhenMaximized: false
                property bool pauseOnBattery: true
                property real pauseWhenIdleMinutes: 5
                // Play display-sized 8-bit copies (made once, cached).
                property bool smallerCopies: true
            }

            property var features: ({})
            property var desktopMenu: ({})
            property JsonObject lock: JsonObject {
                // A lock design directory, "builtin", or "" = the theme's default.
                property string design: ""
            }

            property var perTheme: ({})

            property var wallpaperFraming: ({})

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
                property bool alertDisk: false
                property real diskThreshold: 0.9 // any mounted fs, 0..1
                property bool alertBattery: true
                // The shell's own watchdog (Perf): a notification, once per
                // session, when it stays slow (lag or CPU) for 30 s.
                property bool perfHint: false
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
