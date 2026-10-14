pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Screen recording (wf-recorder, wlr-screencopy) of the focused output into
// ~/Videos/Recordings. Shown as a live activity in the island.
// IPC: recorder toggle|start|stop|pause.
Singleton {
    id: root

    readonly property bool active: proc.running
    property bool paused: false
    property int elapsed: 0 // seconds, excluding pauses
    property string output: ""
    property bool withAudio: false

    readonly property string dir: `${Quickshell.env("HOME")}/Videos/Recordings`

    function start() {
        if (active)
            return;
        output = `${dir}/studio-${Qt.formatDateTime(new Date(), "yyyy-MM-dd_HH-mm-ss")}.mp4`;
        elapsed = 0;
        paused = false;
        const screen = Niri.focusedWorkspace?.output ?? "";
        proc.command = ["sh", "-c", `mkdir -p "${dir}" && exec wf-recorder ${screen ? `-o "${screen}"` : ""} ${withAudio ? "--audio" : ""} -f "${output}"`];
        proc.running = true;
    }

    function stop() {
        if (!active)
            return;
        if (paused)
            pause(); // resume so wf-recorder can finalize on SIGINT
        proc.signal(2); // SIGINT: wf-recorder finalizes the file
    }

    // SIGSTOP/SIGCONT freeze the recorder; the clock stops with it.
    function pause() {
        if (!active)
            return;
        proc.signal(paused ? 18 : 19);
        paused = !paused;
    }

    Process {
        id: proc
        onExited: (code, status) => {
            root.paused = false;
            if (root.output !== "")
                Notifications.show({
                    appName: "Screen Recording",
                    appIcon: "media-record",
                    summary: code === 0 || code === 130 ? "Recording saved" : "Recording failed",
                    body: root.output.replace(Quickshell.env("HOME"), "~"),
                    image: "",
                    actions: []
                });
        }
    }

    Timer {
        interval: 1000
        running: root.active && !root.paused
        repeat: true
        onTriggered: root.elapsed++
    }

    IpcHandler {
        target: "recorder"

        function toggle(): void {
            root.active ? root.stop() : root.start();
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
