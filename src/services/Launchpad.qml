pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Launchpad (src/launchpad/LaunchpadWindow.qml): every installed app in a grid,
// on one screen at a time. The dock's second icon toggles it on its own
// screen; ⌘⇧A, the Launchpad key and IPC on the focused one.
// IPC: launchpad toggle | open | close
Singleton {
    id: root

    // The screen it is open on; "" = closed.
    property string output: ""
    readonly property bool open: output !== ""

    function focusedOutput() {
        return Niri.focusedWorkspace?.output ?? Quickshell.screens[0]?.name ?? "";
    }

    function toggle(screenName) {
        const s = screenName || focusedOutput();
        output = output === s ? "" : s;
    }

    function close() {
        output = "";
    }

    // Look up every app's icon in the background, a few at a time, once the
    // shell has settled: Apps.iconSources (icon theme, heuristic desktop
    // entry) is synchronous and cached, and doing it for a screenful of
    // apps held the first opening back by over a second.
    // At most ~8 ms of lookups per tick (at least one app): a themed name
    // that misses walks every theme directory (20–90 ms), and 8 apps per
    // tick held the GUI thread up to 270 ms at a time when most names
    // missed (#16).
    property int warmed: 0
    Timer {
        interval: root.warmed === 0 ? 5000 : 50
        running: root.warmed < Apps.entries.length
        repeat: true
        onTriggered: {
            const all = Apps.entries;
            const t0 = Date.now();
            let i = root.warmed;
            while (i < all.length && Date.now() - t0 < 8) {
                if (all[i]?.id)
                    Apps.iconSources(all[i].id);
                i++;
            }
            root.warmed = i;
        }
    }
    Connections {
        target: Apps
        function onEntriesChanged() {
            root.warmed = 0;
        }
    }

    IpcHandler {
        target: "launchpad"

        function toggle(): void {
            root.toggle("");
        }
        function open(): void {
            root.output = root.focusedOutput();
        }
        function close(): void {
            root.close();
        }
    }
}
