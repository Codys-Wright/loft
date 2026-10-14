pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Cleaning Mode: wipe the keyboard and screens without typing into apps or
// firing shortcuts. everyday/CleaningMode.qml shows it as an
// ext-session-lock (one dark surface per display), so niri routes every key
// and click to it and runs no binds except allow-when-locked ones (see
// docs/FEATURES.md). Leave by holding Esc, when the timer runs out, or over
// IPC from elsewhere (ssh):
//
//   qs ipc call cleaning start | stop | toggle | status
Singleton {
    id: root

    // Kept across hot reloads: the new lock takes the old one over.
    property alias active: persist.active
    // ms since the epoch when it ends by itself (0 = only by hand).
    property alias endsAt: persist.endsAt
    property alias startedAt: persist.startedAt

    PersistentProperties {
        id: persist
        reloadableId: "cleaning"
        property bool active: false
        property real endsAt: 0
        property real startedAt: 0
    }

    // Hold-to-exit progress 0..1 (the surfaces drive it).
    property real holdProgress: 0

    function start() {
        if (active || !Features.on("cleaningMode") || LockState.locked)
            return;
        const s = EverydayConfig.cleaning.seconds;
        startedAt = Date.now();
        endsAt = s > 0 ? startedAt + s * 1000 : 0;
        holdProgress = 0;
        active = true;
    }

    function stop() {
        active = false;
        endsAt = 0;
        holdProgress = 0;
    }

    function toggle() {
        active ? stop() : start();
    }

    IpcHandler {
        target: "cleaning"

        function start(): void {
            root.start();
        }
        function stop(): void {
            root.stop();
        }
        function toggle(): void {
            root.toggle();
        }
        function status(): string {
            if (!root.active)
                return "off";
            return root.endsAt > 0 ? `on ${Math.max(0, Math.ceil((root.endsAt - Date.now()) / 1000))}s` : "on";
        }
    }
}
