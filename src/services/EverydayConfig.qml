pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Settings of the everyday window and power modules — Keep Awake, Cleaning
// Mode, Quit on close, Quit protection and Arrange — editable in Settings →
// Everyday. Runtime overrides like Settings.qml, in their own file
// (<state>/overrides/everyday.json) so modules don't share one adapter.
Singleton {
    id: root

    readonly property string stateDir: Settings.stateDir
    readonly property string file: `${stateDir}/overrides/everyday.json`

    readonly property alias keepAwake: cfg.keepAwake
    readonly property alias cleaning: cfg.cleaning
    readonly property alias quit: cfg.quit

    // List helpers for the per-app lists (quit.onClose, quit.protect,
    // keepAwake.apps): JsonAdapter lists only notify on reassignment.
    function has(list, appId) {
        return Array.from(list ?? []).includes(appId);
    }

    function toggled(list, appId, on) {
        const l = Array.from(list ?? []).filter(x => x !== appId);
        if (on)
            l.push(appId);
        return l;
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

            property JsonObject keepAwake: JsonObject {
                // The Control Center / bar toggle keeps awake for this long
                // (minutes; 0 = until turned off).
                property int defaultMinutes: 0
                // Rules: stay awake while any of these hold.
                // App ids (niri app-id): while one of them has a window.
                property list<string> apps: []
                property bool onAC: false
                property bool externalDisplay: false
                // Also block suspend (systemd-logind sleep inhibitor), not
                // only the screen blanking / idle lock.
                property bool blockSleep: true
                // Laptops: keep running with the lid closed while awake
                // (logind handle-lid-switch inhibitor).
                property bool lidClosed: false
            }

            property JsonObject cleaning: JsonObject {
                // Ends by itself after this many seconds (0 = only by hand).
                property int seconds: 60
                // Hold Esc this long to leave.
                property int holdSeconds: 3
            }

            property JsonObject quit: JsonObject {
                // App ids quit (SIGTERM) when their last window closes.
                property list<string> onClose: []
                // Seconds to wait after the last window closes.
                property int graceSeconds: 2
                // App ids that need ⌘Q held to quit.
                property list<string> protect: []
                // Every app needs ⌘Q held (protect is then ignored).
                property bool protectAll: false
                // How long to hold, in ms.
                property int holdMs: 1000
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
