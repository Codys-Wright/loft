pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Focus (pomodoro) timer: a countdown shown as a live activity in the island.
// IPC: focus toggle|start|stop|pause.
Singleton {
    id: root

    property int duration: Settings.island.focusMinutes * 60
    property int remaining: 0
    property bool running: false
    property bool paused: false
    readonly property bool active: running
    readonly property real progress: duration > 0 ? 1 - remaining / duration : 0

    function start() {
        remaining = duration;
        paused = false;
        running = true;
    }

    // A timer of a given length (Focus control: 25 / 50 min …).
    function startFor(minutes) {
        duration = minutes * 60;
        start();
    }

    function stop() {
        running = false;
        paused = false;
        duration = Qt.binding(() => Settings.island.focusMinutes * 60);
    }

    function pause() {
        if (running)
            paused = !paused;
    }

    function format(s) {
        const m = Math.floor(s / 60), r = s % 60;
        return `${m}:${String(r).padStart(2, "0")}`;
    }

    Timer {
        interval: 1000
        running: root.running && !root.paused
        repeat: true
        onTriggered: {
            if (--root.remaining > 0)
                return;
            root.stop();
            Notifications.show({
                appName: "Focus",
                appIcon: "alarm-symbolic",
                summary: "Focus session complete",
                body: `${Settings.island.focusMinutes} minutes done — take a break.`,
                image: "",
                actions: []
            });
        }
    }

    IpcHandler {
        target: "focus"

        function toggle(): void {
            root.running ? root.stop() : root.start();
        }

        function start(): void {
            root.start();
        }

        function stop(): void {
            root.stop();
        }

        function pause(): void {
            root.pause();
        }
    }
}
