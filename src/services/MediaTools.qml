pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Media tools (Utilities → Media Tools): a batch of files (dropped on the
// page, picked from recent media, sent by the dock's Quick Actions, the
// "Media Tools" desktop entry / Spotlight or `loft media open`) and one
// operation — compress, convert, gif, watermark, audio — run by
// `loft media run` (cli/loft/media.py: ffmpeg + ImageMagick), whose JSON
// lines drive the progress. Outputs land next to the originals unless an
// output folder is set; nothing is overwritten.
Singleton {
    id: root

    readonly property var ops: [
        {
            id: "compress",
            label: "Compress Video",
            icon: "󰕧",
            kinds: ["video"]
        },
        {
            id: "convert",
            label: "Convert Images",
            icon: "󰋩",
            kinds: ["image"]
        },
        {
            id: "gif",
            label: "Make GIF",
            icon: "󰵸",
            kinds: ["video"]
        },
        {
            id: "watermark",
            label: "Add Watermark",
            icon: "󰏬",
            kinds: ["image", "video"]
        },
        {
            id: "audio",
            label: "Extract Audio",
            icon: "󰎈",
            kinds: ["video", "audio"]
        }
    ]

    property var files: [] // probed: { path, name, kind, bytes, duration, width, height, ops }
    property string op: "compress"
    property var recent: []
    property var caps: ({})

    // Options (per session).
    property string preset: "balanced" // compress
    property string format: "webp" // convert
    property int quality: 82
    property int maxSize: 0 // 0 = keep
    property int fps: 15 // gif
    property int gifWidth: 640
    property real gifSeconds: 0 // 0 = whole clip
    property string wmText: "© " + new Date().getFullYear()
    property string wmImage: ""
    property string wmPosition: "bottom-right"
    property real wmOpacity: 0.6
    property string audioFormat: "m4a"
    property string outDir: "" // "" = next to each original

    // Running.
    property bool running: false
    property real overall: 0
    property int current: -1
    property var results: [] // { file, output, inBytes, outBytes, error }
    property string error: ""

    readonly property var opInfo: ops.find(o => o.id === op) ?? ops[0]
    readonly property var applicable: files.filter(f => opInfo.kinds.includes(f.kind))
    readonly property bool ready: !running && applicable.length > 0 && (op !== "watermark" || wmText !== "" || wmImage !== "")

    function opLabel(id) {
        return ops.find(o => o.id === id)?.label ?? id;
    }

    // Paths or file:// URLs; `withOp` switches the operation.
    function add(paths, withOp) {
        const clean = paths.map(p => String(p).trim()).filter(p => p !== "").map(p => p.startsWith("file://") ? decodeURIComponent(p.slice(7)) : p);
        const have = new Set(files.map(f => f.path));
        const fresh = clean.filter(p => !have.has(p));
        if (withOp && ops.some(o => o.id === withOp))
            op = withOp;
        if (fresh.length === 0) {
            pickOp();
            return;
        }
        prober.command = ["loft", "media", "probe"].concat(fresh);
        prober.running = true;
    }

    // Pick an operation that fits the files when the current one doesn't.
    function pickOp() {
        if (files.length === 0 || applicable.length > 0)
            return;
        const kinds = new Set(files.map(f => f.kind));
        const fit = ops.find(o => o.kinds.some(k => kinds.has(k)));
        if (fit)
            op = fit.id;
    }

    function remove(path) {
        files = files.filter(f => f.path !== path);
    }

    function clearFiles() {
        files = [];
        results = [];
        error = "";
        overall = 0;
    }

    // Open the window on Media Tools with these files.
    function openWith(paths, withOp) {
        Utilities.show("media");
        if (paths.length > 0) {
            if (!running) {
                results = [];
                overall = 0;
            }
            add(paths, withOp);
        } else if (withOp) {
            op = withOp;
        }
    }

    Process {
        id: prober
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const got = JSON.parse(text).filter(f => !f.missing);
                    const have = new Set(root.files.map(f => f.path));
                    root.files = root.files.concat(got.filter(f => !have.has(f.path)));
                    root.pickOp();
                } catch (e) {
                    root.error = "Couldn't read those files.";
                }
            }
        }
    }

    function loadRecent() {
        recentProc.running = true;
        if (Object.keys(caps).length === 0)
            capsProc.running = true;
    }

    Process {
        id: recentProc
        command: ["loft", "media", "recent", "--limit", "8"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.recent = JSON.parse(text);
                } catch (e) {
                    root.recent = [];
                }
            }
        }
    }

    Process {
        id: capsProc
        command: ["loft", "media", "caps"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.caps = JSON.parse(text);
                } catch (e) {}
            }
        }
    }

    function argv() {
        const a = ["loft", "media", "run", op].concat(applicable.map(f => f.path));
        if (outDir !== "")
            a.push("--out", outDir);
        if (op === "compress")
            a.push("--preset", preset);
        if (op === "convert") {
            a.push("--format", format, "--quality", String(quality));
            if (maxSize > 0)
                a.push("--max-size", String(maxSize));
        }
        if (op === "gif") {
            a.push("--fps", String(fps), "--width", String(gifWidth));
            if (gifSeconds > 0)
                a.push("--seconds", String(gifSeconds));
        }
        if (op === "watermark") {
            if (wmImage !== "")
                a.push("--image", wmImage);
            else
                a.push("--text", wmText);
            a.push("--position", wmPosition, "--opacity", wmOpacity.toFixed(2));
        }
        if (op === "audio")
            a.push("--format", audioFormat);
        return a;
    }

    function start() {
        if (!ready)
            return;
        results = [];
        error = "";
        overall = 0;
        current = 0;
        running = true;
        runner.command = argv();
        runner.running = true;
    }

    function cancel() {
        if (runner.running)
            runner.signal(15);
    }

    Process {
        id: runner
        stdout: SplitParser {
            onRead: line => {
                let m;
                try {
                    m = JSON.parse(line);
                } catch (e) {
                    return;
                }
                if (m.event === "start") {
                    root.current = m.index;
                } else if (m.event === "progress") {
                    root.overall = m.overall;
                } else if (m.event === "done") {
                    root.overall = m.overall;
                    root.results = root.results.concat([{
                            file: m.file,
                            output: m.output,
                            inBytes: m.inBytes,
                            outBytes: m.outBytes
                        }]);
                } else if (m.event === "error") {
                    root.results = root.results.concat([{
                            file: m.file,
                            error: m.message
                        }]);
                }
            }
        }
        onExited: (code, status) => {
            root.running = false;
            root.current = -1;
            if (root.results.length === 0 && code !== 0)
                root.error = "Stopped.";
            root.loadRecent();
        }
    }

    function reveal(path) {
        Quickshell.execDetached(["loft", "dock", "show", path]);
    }

    function openFile(path) {
        Quickshell.execDetached(["xdg-open", path]);
    }

    IpcHandler {
        target: "media"

        // op: "" or compress|convert|gif|watermark|audio; paths: newline-separated.
        function open(op: string, paths: string): void {
            root.openWith(paths.split("\n").filter(p => p !== ""), op);
        }
        function status(): string {
            return JSON.stringify({
                files: root.files.map(f => f.path),
                op: root.op,
                running: root.running,
                overall: root.overall,
                results: root.results
            });
        }
    }
}
