pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Screen recording of an output, a region or (KWin) a window into
// ~/Videos/Recordings (the Capture module re-points `dir`). Shown as a live
// activity in the island. niri: wf-recorder (wlr-screencopy). KWin, which
// has no wlr-screencopy: `loft-kwin record` (KWin's zkde_screencast →
// PipeWire → GStreamer, the same H.264 MP4; docs/KWIN.md §4.10).
//
// Audio: none | system (the default sink's monitor) | mic (the default
// source) | both — system goes into the video by the recorder, the mic is
// recorded alongside by ffmpeg and muxed in as a second audio track when
// the recording stops (wf-recorder takes a single audio device).
//
// Pause is a cut, as on macOS: neither recorder can leave a stretch out
// (SIGSTOP held the last frame for the whole pause, both under niri and
// KWin), so each stretch between pauses is its own part
// (Recording_….part1.mp4, part2, …, plus .mic1.wav … for "both"), and
// `loft capture join` makes the one file when the recording stops.
// IPC: recorder toggle|start|stop|pause.
Singleton {
    id: root

    // A recording is on (also while paused, between parts, and until its
    // last part is written).
    property bool active: false
    property bool paused: false
    property int elapsed: 0 // seconds, excluding pauses
    property string output: ""
    // Older switch: true records the microphone when `audio` is "none".
    property bool withAudio: false
    property string audio: "none"

    property string dir: `${Quickshell.env("HOME")}/Videos/Recordings`

    // A recording finished (and was joined): its path, and whether it worked.
    signal finished(string path, bool ok)

    readonly property string audioMode: audio !== "none" ? audio : withAudio ? "mic" : "none"
    property string micFile: ""

    // The running recording is loft-kwin's.
    property bool viaKWin: false

    // The parts so far: [{ video, mic }] (mic "" without one), and what
    // start() was asked, for the next part.
    property var parts: []
    property var opts: ({})
    property string screen: ""
    // The last part's recorder failed (exit other than 0 / SIGINT).
    property bool failed: false
    property bool stopping: false
    // Resumed while the paused part was still being written.
    property bool resumeWanted: false

    // opts: { output: name } or { geometry: "x,y WxH" (logical, like slurp),
    // scale: device pixels per logical pixel (KWin; default 1) } or
    // { window: KWin uuid } (KWin only); default = the focused output.
    function start(o) {
        if (active)
            return;
        output = `${dir}/Recording_${Qt.formatDateTime(new Date(), "yyyy-MM-dd_HH-mm-ss")}.mp4`;
        elapsed = 0;
        paused = false;
        failed = false;
        stopping = false;
        resumeWanted = false;
        parts = [];
        opts = o ?? {};
        screen = opts.output ?? Compositor.focusedWorkspace?.output ?? "";
        viaKWin = Compositor.backend === "kwin";
        active = true;
        startPart();
    }

    // Record the next part.
    function startPart() {
        const n = parts.length + 1;
        const file = output.replace(/\.mp4$/, `.part${n}.mp4`);
        micFile = audioMode === "both" ? output.replace(/\.mp4$/, `.mic${n}.wav`) : "";
        parts = parts.concat([{ video: file, mic: micFile }]);
        const args = viaKWin ? kwinArgs(opts, screen, file) : wfArgs(opts, screen, file);
        proc.command = ["sh", "-c", 'mkdir -p "$1" && shift && exec "$@"', "sh", dir].concat(args);
        proc.running = true;
        if (micFile !== "") {
            mic.command = ["ffmpeg", "-v", "error", "-y", "-f", "pulse", "-i", "default", "-ac", "2", micFile];
            mic.running = true;
        }
    }

    function wfArgs(o, screen, file) {
        const args = ["wf-recorder", "-y"];
        if (o.geometry)
            args.push("-g", o.geometry);
        else if (screen)
            args.push("-o", screen);
        if (audioMode === "system" || audioMode === "both")
            args.push("--audio=@DEFAULT_MONITOR@");
        else if (audioMode === "mic")
            args.push("--audio");
        args.push("-f", file);
        return args;
    }

    // `loft-kwin record screen|area|window … FILE [--scale S] [--audio SRC]`.
    function kwinArgs(o, screen, file) {
        const args = [KWin.bin, "record"];
        const g = /^(-?\d+),(-?\d+) (\d+)x(\d+)$/.exec(o.geometry ?? "");
        if (o.window)
            args.push("window", o.window, file);
        else if (g)
            args.push("area", g[1], g[2], g[3], g[4], file, "--scale", String(o.scale ?? 1));
        else
            args.push("screen", screen || (Quickshell.screens[0]?.name ?? ""), file);
        if (audioMode === "system" || audioMode === "both")
            args.push("--audio", "@DEFAULT_MONITOR@");
        else if (audioMode === "mic")
            args.push("--audio", "default");
        return args;
    }

    // SIGINT: the recorder finalizes its part.
    function endPart() {
        if (proc.running)
            proc.signal(2);
        if (mic.running)
            mic.signal(2);
    }

    function stop() {
        if (!active || stopping)
            return;
        stopping = true;
        if (proc.running)
            endPart();
        else
            finish(); // paused: every part is written
    }

    // Pause ends the part; resume starts the next one (once the last is
    // written: proc's onExited).
    function pause() {
        if (!active || stopping)
            return;
        paused = !paused;
        if (paused) {
            resumeWanted = false;
            endPart();
        } else if (proc.running)
            resumeWanted = true;
        else
            startPart();
    }

    // Join the parts into `output` (also when there is just one: it is
    // renamed, its mic muxed in).
    function finish() {
        const list = parts.map(p => p.mic !== "" ? `${p.video}:${p.mic}` : p.video);
        active = false;
        paused = false;
        join.command = ["loft", "capture", "join", output].concat(list);
        join.running = true;
    }

    function done(ok) {
        Notifications.show({
            appName: "Screen Recording",
            appIcon: "media-record",
            summary: ok ? "Recording saved" : "Recording failed",
            body: output.replace(Quickshell.env("HOME"), "~"),
            image: "",
            actions: []
        });
        finished(output, ok);
    }

    Process {
        id: proc
        onExited: (code, status) => {
            if (!root.active)
                return;
            root.failed = !(code === 0 || code === 130);
            if (root.stopping || root.failed) {
                // Stopped, or the recorder gave up (a window closed, an
                // error): what's recorded so far is the recording.
                root.stopping = true;
                if (mic.running)
                    mic.signal(2);
                joinWhenReady.start();
            } else if (root.resumeWanted) {
                // Resumed before this part was written.
                root.resumeWanted = false;
                if (!root.paused)
                    root.startPart();
            } else if (!root.paused) {
                // It ended by itself (KWin closed the window's stream).
                root.stopping = true;
                if (mic.running)
                    mic.signal(2);
                joinWhenReady.start();
            }
        }
    }

    // The microphone track for audio "both".
    Process {
        id: mic
    }

    // Wait for the mic recorder to close its file, then join.
    Timer {
        id: joinWhenReady
        interval: 100
        repeat: true
        onTriggered: {
            if (mic.running)
                return;
            stop();
            root.finish();
        }
    }

    Process {
        id: join
        onExited: code => root.done(code === 0)
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
