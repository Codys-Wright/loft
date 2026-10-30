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
    property int warmed: 0
    Timer {
        interval: root.warmed === 0 ? 5000 : 30
        running: root.warmed < Apps.entries.length
        repeat: true
        onTriggered: {
            const all = Apps.entries;
            const end = Math.min(all.length, root.warmed + 8);
            for (let i = root.warmed; i < end; i++)
                if (all[i]?.id)
                    Apps.iconSources(all[i].id);
            root.warmed = end;
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
