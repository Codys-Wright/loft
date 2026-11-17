pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Screen recording of an output, a region or (KWin) a window into
// ~/Videos/Recordings (the Capture module re-points `dir`). Shown as a live
// activity in the island. niri: wf-recorder (wlr-screencopy). KWin, which
// has no wlr-screencopy: `loft-kwin record` (KWin's zkde_screencast →
// PipeWire → GStreamer, the same H.264 MP4; docs/KWIN.md §4.8).
//
// Audio: none | system (the default sink's monitor) | mic (the default
// source) | both — system goes into the video by wf-recorder, the mic is
// recorded alongside by ffmpeg and muxed in as a second audio track when
// the recording stops (wf-recorder takes a single audio device).
// IPC: recorder toggle|start|stop|pause.
Singleton {
    id: root

    readonly property bool active: proc.running
    property bool paused: false
    property int elapsed: 0 // seconds, excluding pauses
    property string output: ""
    // Older switch: true records the microphone when `audio` is "none".
    property bool withAudio: false
    property string audio: "none"

    property string dir: `${Quickshell.env("HOME")}/Videos/Recordings`

    // A recording finished (and was muxed): its path, and whether it worked.
    signal finished(string path, bool ok)

    readonly property string audioMode: audio !== "none" ? audio : withAudio ? "mic" : "none"
    property string micFile: ""

    // The running recording is loft-kwin's (pauses with SIGTSTP, which it
    // passes on; wf-recorder takes SIGSTOP itself).
    property bool viaKWin: false

    // opts: { output: name } or { geometry: "x,y WxH" (logical, like slurp),
    // scale: device pixels per logical pixel (KWin; default 1) } or
    // { window: KWin uuid } (KWin only); default = the focused output.
    function start(opts) {
        if (active)
            return;
        output = `${dir}/Recording_${Qt.formatDateTime(new Date(), "yyyy-MM-dd_HH-mm-ss")}.mp4`;
        elapsed = 0;
        paused = false;
        const o = opts ?? {};
        const screen = o.output ?? Compositor.focusedWorkspace?.output ?? "";
        viaKWin = Compositor.backend === "kwin";
        const args = viaKWin ? kwinArgs(o, screen) : ["wf-recorder", "-y"];
        if (!viaKWin) {
            if (o.geometry)
                args.push("-g", o.geometry);
            else if (screen)
                args.push("-o", screen);
            if (audioMode === "system" || audioMode === "both")
                args.push("--audio=@DEFAULT_MONITOR@");
            else if (audioMode === "mic")
                args.push("--audio");
            args.push("-f", output);
        }
        micFile = audioMode === "both" ? output.replace(/\.mp4$/, ".mic.wav") : "";
        proc.command = ["sh", "-c", 'mkdir -p "$1" && shift && exec "$@"', "sh", dir].concat(args);
        proc.running = true;
        if (micFile !== "") {
            mic.command = ["ffmpeg", "-v", "error", "-y", "-f", "pulse", "-i", "default", "-ac", "2", micFile];
            mic.running = true;
        }
    }

    // `loft-kwin record screen|area|window … FILE [--scale S] [--audio SRC]`.
    function kwinArgs(o, screen) {
        const args = [KWin.bin, "record"];
        const g = /^(-?\d+),(-?\d+) (\d+)x(\d+)$/.exec(o.geometry ?? "");
        if (o.window)
            args.push("window", o.window, output);
        else if (g)
            args.push("area", g[1], g[2], g[3], g[4], output, "--scale", String(o.scale ?? 1));
        else
            args.push("screen", screen || (Quickshell.screens[0]?.name ?? ""), output);
        if (audioMode === "system" || audioMode === "both")
            args.push("--audio", "@DEFAULT_MONITOR@");
        else if (audioMode === "mic")
            args.push("--audio", "default");
        return args;
    }

    function stop() {
        if (!active)
            return;
        if (paused)
            pause(); // resume so the recorder can finalize on SIGINT
        proc.signal(2); // SIGINT: wf-recorder finalizes the file
        if (mic.running)
            mic.signal(2);
    }

    // SIGSTOP/SIGCONT freeze the recorder; the clock stops with it.
    // (loft-kwin: SIGTSTP, it stops its encoder.)
    function pause() {
        if (!active)
            return;
        proc.signal(paused ? 18 : viaKWin ? 20 : 19);
        if (mic.running)
            mic.signal(paused ? 18 : 19);
        paused = !paused;
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
            root.paused = false;
            if (root.output === "")
                return;
            const ok = code === 0 || code === 130;
            if (ok && root.micFile !== "") {
                muxWhenReady.start();
            } else {
                if (mic.running)
                    mic.signal(2);
                root.done(ok);
            }
        }
    }

    // The microphone track for audio "both".
    Process {
        id: mic
    }

    // Wait for the mic recorder to close its file, then add it as track 2.
    Timer {
        id: muxWhenReady
        interval: 100
        repeat: true
        onTriggered: {
            if (mic.running)
                return;
            stop();
            const v = root.output;
            mux.command = ["sh", "-c", 'if ffmpeg -v error -y -i "$1" -i "$2" -map 0:v -map "0:a?" -map 1:a -c:v copy -c:a aac -metadata:s:a:0 title=System -metadata:s:a:1 title=Microphone "$3"; then mv "$3" "$1" && rm -f "$2"; else rm -f "$3"; exit 1; fi', "sh", v, root.micFile, v.replace(/\.mp4$/, ".muxing.mp4")];
            mux.running = true;
        }
    }

    Process {
        id: mux
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
