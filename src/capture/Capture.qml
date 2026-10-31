pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// Capture and create (docs/FEATURES.md): the ⌘⇧5 selector, screenshots
// (area / window / screen / scrolling / workspace panorama), area + screen
// recording (Recorder),
// text from screen (OCR + QR), the color picker, and what follows a capture
// — the floating thumbnail, annotate (satty), pins, GIF export and the
// recording editor (trim + zooms).
//
// Area selection happens on a frozen frame: every output is grabbed with
// grim first, then RegionOverlay shows the frames full-screen with a pixel
// loupe, and the selection is cropped out of the frozen PNG (ffmpeg) — so
// what you select is exactly what you saw.
//
// Settings: <state>/overrides/capture.json (CapturePage).
// Scrolling capture: select an area, then scroll it yourself; `loft capture
// scroll` grabs it a few times a second and stitches the frames by their
// overlap (cli/loft/stitch.py), ScrollCaptureHud shows the growing image
// beside the area with Auto / Cancel / Done. Auto (only when pressed):
// loft-pointer moves the pointer into the area and turns the wheel until the
// content ends; touching the mouse or any key stops it (ScrollCaptureHud).
// Scrolling goes down or sideways (scrollAxis: y | x, "auto" until the
// first scroll decides; the HUD's ↕ / ↔ and Options → Scroll Direction).
// Workspace panorama: `loft capture panorama` (cli/loft/panorama.py) visits
// every column of the display's niri workspace through IPC, grabs each and
// composites them side by side on the wallpaper — wider than the display.
// The shell's own overlays (pins, the camera, the thumbnail) step aside
// meanwhile (panoramaRunning).
//
// IPC: capture toggle|area|screen|window|scrolling|scrollDone|scrollCancel|
//      scrollAuto|scrollStop|scrollAutoState|scrollAxis AXIS|scrollAxisState|
//      panorama [OUTPUT]|
//      recordArea|recordScreen|text|color|annotateLast|pinLast|gifLast|
//      trimLast|editLast|edit PATH|unpinAll
//      camera toggle|on|off
Singleton {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property bool dev: Quickshell.env("LOFT_DEV") === "1"
    readonly property string tmp: `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/loft-capture`

    // ── Settings ────────────────────────────────────────────────────────
    readonly property alias cfg: cfg
    readonly property string screenshotDir: expand(cfg.screenshotDir)
    readonly property string recordingDir: expand(cfg.recordingDir)

    function expand(p) {
        return p.startsWith("~") ? home + p.slice(1) : p;
    }

    function pretty(p) {
        return p.startsWith(home) ? "~" + p.slice(home.length) : p;
    }

    // ── State ───────────────────────────────────────────────────────────
    property bool selectorOpen: false
    // Selector choice: shot | scroll | panorama | record | text | color, and
    // its target.
    property string mode: "shot"
    property string target: "area"

    // A countdown (selector timer) is running: seconds left.
    property int countdown: 0
    property var pendingCapture: null

    // Area selection in progress: what it's for (shot | record | text |
    // color) and the frozen frame of each output (name → png path).
    property string selecting: ""
    property var frozen: ({})
    // Output the selection started on (keyboard focus / loupe).
    property string selectScreen: ""

    // The floating thumbnail: { path, kind: "image" | "video", poster }.
    property var thumbnail: null
    // Pinned captures (always-on-top windows): [{ id, path, screen }].
    property var pins: []
    property int pinSerial: 0
    // A recording in the editor (trim + zooms): { path, duration, width,
    // height }.
    property var trimming: null

    // Scrolling capture in progress: { screen, rect (screen-local logical),
    // out } — and what the helper reported: the stitched size, the kept
    // frames and where their rows go ([{path, sy, h, y}], for the preview).
    property var scrolling: null
    // The stitched image's size, and one frame's (the area's pixels).
    property int scrollWidth: 0
    property int scrollHeight: 0
    property int scrollFrameWidth: 0
    property int scrollFrameHeight: 0
    // y (down) | x (sideways) | auto (not decided yet: the first scroll
    // decides); segments are {path, sy, h, y} for y, {path, sx, w, x} for x.
    property string scrollAxis: "y"
    property int scrollFrames: 0
    property var scrollSegments: []
    property bool scrollFinishing: false
    // Auto Scroll: "" | starting | running (the pointer is in place, the
    // HUD guards it) | stopping; why it last stopped (end | stop | pointer |
    // timeout | limit | error | unavailable | done | cancel).
    property string scrollAuto: ""
    property string scrollAutoReason: ""
    // Briefly after the mouse stopped it, Auto ignores clicks: the click
    // was meant for the Stop button that just turned back into Auto.
    property bool scrollAutoCooling: false
    // Long-running post-processing (GIF export, trim) for the UI.
    property string busy: ""

    // Workspace panorama in progress: { screen, out }. Meanwhile the shell's
    // own overlays hide (they would land in the grabs).
    property var panorama: null
    readonly property bool panoramaRunning: panorama !== null
    property string lastPanoramaNotes: ""

    property bool cameraOn: false
    property string cameraScreen: ""
    onCameraOnChanged: if (cameraOn)
        cameraScreen = screenFocused?.name ?? ""
    // Published by CameraView: unavailable (no QtMultimedia) | none (no
    // device) | starting | live | error; the device and the choices.
    property string cameraState: "unavailable"
    property string cameraName: ""
    property string cameraError: ""
    property var cameraDevices: []

    // Last finished captures, for the IPC follow-ups.
    property string lastImage: ""
    property string lastVideo: ""

    readonly property var screenFocused: Quickshell.screens.find(s => s.name === (Niri.focusedWorkspace?.output ?? "")) ?? Quickshell.screens[0] ?? null

    function stamp() {
        return Qt.formatDateTime(new Date(), "yyyy-MM-dd_HH-mm-ss");
    }

    // ── Entry points ────────────────────────────────────────────────────
    function toggleSelector() {
        selectorOpen ? closeSelector() : openSelector();
    }

    function openSelector() {
        if (selecting !== "" || countdown > 0)
            return;
        mode = cfg.lastMode;
        target = cfg.lastTarget;
        selectorOpen = true;
    }

    function closeSelector() {
        selectorOpen = false;
    }

    // Run the selector's current choice (the Capture button / Enter).
    function captureSelected() {
        cfg.lastMode = mode;
        cfg.lastTarget = target;
        capture(mode, mode === "text" || mode === "color" || mode === "scroll" ? "area" : mode === "panorama" ? "screen" : target, cfg.timer);
    }

    // mode: shot | scroll | panorama | record | text | color; target: area |
    // window | screen (panorama: screen = the focused display, or an output
    // name).
    // Which capture kinds the enabled feature modules allow.
    function allowed(kind) {
        return kind === "color" ? Features.on("colorPicker") : kind === "text" ? Features.on("ocr") : Features.on("capture");
    }

    function capture(kind, where, delay) {
        if (!allowed(kind) || selecting !== "" || scrolling !== null || panorama !== null)
            return;
        if (kind === "record" && Recorder.active) {
            Recorder.stop();
            return;
        }
        selectorOpen = false;
        thumbnailHide.restart();
        pendingCapture = {
            kind: kind,
            where: where
        };
        countdown = delay > 0 ? delay : 0;
        if (countdown > 0)
            tick.restart();
        else
            // Let the selector / thumbnail unmap before grabbing the screen.
            settle.restart();
    }

    function cancel() {
        tick.stop();
        settle.stop();
        countdown = 0;
        pendingCapture = null;
        selecting = "";
        frozen = {};
    }

    Timer {
        id: tick
        interval: 1000
        repeat: true
        onTriggered: {
            root.countdown--;
            if (root.countdown <= 0) {
                stop();
                settle.restart();
            }
        }
    }

    Timer {
        id: settle
        interval: 180
        onTriggered: root.run()
    }

    Timer {
        id: thumbnailHide
        interval: 1
        onTriggered: root.thumbnail = null
    }

    function run() {
        const p = pendingCapture;
        pendingCapture = null;
        if (!p)
            return;
        if (p.kind === "panorama")
            startPanorama(p.where === "screen" ? (screenFocused?.name ?? "") : p.where);
        else if (p.where === "area")
            freeze(p.kind);
        else if (p.kind === "record")
            Recorder.start({
                output: screenFocused?.name ?? ""
            });
        else if (p.where === "window")
            shootWindow();
        else
            shootScreen();
    }

    // ── Screenshots ─────────────────────────────────────────────────────
    function newShotPath() {
        return `${screenshotDir}/Screenshot_${stamp()}.png`;
    }

    function shootScreen() {
        const out = newShotPath();
        const name = screenFocused?.name ?? "";
        Niri.shutter();
        exec(["sh", "-c", 'mkdir -p "$(dirname "$2")" && exec grim ${3:+-c} ${1:+-o "$1"} "$2"', "sh", name, out, cfg.showPointer ? "1" : ""], (code, _out, err) => code === 0 ? shotDone(out) : failed("Screenshot failed", err));
    }

    function shootWindow() {
        const w = Niri.focusedWindow;
        if (!w) {
            failed("No window to capture", "Focus a window first");
            return;
        }
        const out = newShotPath();
        Niri.shutter();
        // niri writes the file and copies it; ScreenshotCaptured(path) follows.
        exec(["mkdir", "-p", screenshotDir], () => Niri.action("ScreenshotWindow", {
                id: w.id,
                write_to_disk: true,
                show_pointer: cfg.showPointer,
                path: out
            }));
    }

    // A finished image capture of ours (niri's own come via screenshotTaken).
    function shotDone(path) {
        if (cfg.copyToClipboard)
            exec(["sh", "-c", 'wl-copy --type image/png < "$1"', "sh", path]);
        // The island's shutter flash + our thumbnail listen to this.
        Niri.screenshotTaken(path);
    }

    Connections {
        target: Niri
        function onScreenshotTaken(path) {
            if (path === "")
                return;
            root.lastImage = path;
            if (root.cfg.annotateAfter)
                root.annotate(path);
            else if (root.cfg.showThumbnail)
                root.thumbnail = {
                    path: path,
                    kind: "image",
                    poster: path
                };
        }
    }

    // ── Area selection on frozen frames ─────────────────────────────────
    function freeze(kind) {
        const shots = {};
        const cmds = [];
        for (const s of Quickshell.screens) {
            const f = `${tmp}/frozen-${s.name}-${Date.now()}.png`;
            shots[s.name] = f;
            cmds.push(`grim -o '${s.name.replace(/'/g, "")}' '${f}'`);
        }
        exec(["sh", "-c", `rm -f "$1"/frozen-*.png; mkdir -p "$1" && ${cmds.join(" && ")}`, "sh", tmp], (code, _out, err) => {
            if (code !== 0) {
                failed("Couldn't capture the screen", err);
                return;
            }
            root.frozen = shots;
            root.selectScreen = root.screenFocused?.name ?? "";
            root.selecting = kind;
        });
    }

    // From RegionOverlay: rect in the screen's logical coords, px = the same
    // rect in the frozen image's pixels; color = the picked pixel (#rrggbb).
    function selected(screen, rect, px, color) {
        const kind = selecting;
        const src = frozen[screen.name] ?? "";
        selecting = "";
        if (kind === "color") {
            pickedColor(color);
        } else if (kind === "record") {
            const geo = `${Math.round(screen.x + rect.x)},${Math.round(screen.y + rect.y)} ${Math.round(rect.width)}x${Math.round(rect.height)}`;
            Recorder.start({
                geometry: geo
            });
        } else if (kind === "scroll") {
            startScroll(screen, rect);
        } else if (kind === "text") {
            const out = `${tmp}/ocr-${Date.now()}.png`;
            crop(src, px, out, () => recognize(out));
        } else {
            const out = newShotPath();
            Niri.shutter();
            crop(src, px, out, () => root.shotDone(out));
        }
        frozen = {};
    }

    function crop(src, px, out, then) {
        // Even sizes aren't needed for PNG; clamp to at least 1 px.
        const w = Math.max(1, Math.round(px.width)), h = Math.max(1, Math.round(px.height));
        exec(["sh", "-c", 'mkdir -p "$(dirname "$2")" && ffmpeg -v error -y -i "$1" -vf "crop=$3:$4:$5:$6" -frames:v 1 -update 1 "$2"', "sh", src, out, `${w}`, `${h}`, `${Math.round(px.x)}`, `${Math.round(px.y)}`], (code, _o, err) => code === 0 ? then() : failed("Capture failed", err));
    }

    // ── Scrolling capture ───────────────────────────────────────────────
    function startScroll(screen, rect) {
        const r = Qt.rect(Math.round(rect.x), Math.round(rect.y), Math.round(rect.width), Math.round(rect.height));
        const geo = `${Math.round(screen.x + r.x)},${Math.round(screen.y + r.y)} ${r.width}x${r.height}`;
        scrollWidth = 0;
        scrollHeight = 0;
        scrollFrameWidth = 0;
        scrollFrameHeight = 0;
        scrollAxis = cfg.scrollDirection === "x" || cfg.scrollDirection === "y" ? cfg.scrollDirection : "auto";
        scrollFrames = 0;
        scrollSegments = [];
        scrollFinishing = false;
        scrollAuto = "";
        scrollAutoReason = "";
        scrolling = {
            screen: screen.name,
            rect: r,
            out: newShotPath()
        };
        scrollProc.command = ["loft", "capture", "scroll", "--geometry", geo, "--out", scrolling.out, "--work", `${tmp}/scroll-${Date.now()}`, "--axis", scrollAxis];
        scrollProc.running = true;
    }

    function scrollDone() {
        if (!scrolling || scrollFinishing)
            return;
        scrollFinishing = true;
        scrollProc.write("done\n");
    }

    function scrollCancel() {
        if (!scrolling)
            return;
        if (scrollProc.running)
            scrollProc.write("cancel\n");
        scrolling = null;
        scrollAuto = "";
    }

    // Auto Scroll, from the HUD's Auto button (gx, gy: where the pointer
    // was, global logical — it goes back there afterwards) or IPC.
    function scrollAutoStart(gx, gy) {
        if (!scrolling || scrollFinishing || scrollAuto !== "" || scrollAutoCooling || !scrollProc.running)
            return;
        scrollAuto = "starting";
        scrollAutoReason = "";
        const at = Number.isFinite(gx) && Number.isFinite(gy) ? ` ${Math.round(gx)} ${Math.round(gy)}` : "";
        scrollProc.write(`auto${at}\n`);
    }

    // Scroll direction for this capture (and the next ones): y | x | auto.
    // Anything already stitched the other way starts over from the last
    // frame.
    function scrollSetAxis(axis) {
        if (!scrolling || scrollFinishing || !["y", "x", "auto"].includes(axis))
            return;
        cfg.scrollDirection = axis;
        if (axis === scrollAxis)
            return;
        scrollAxis = axis;
        scrollProc.write(`axis ${axis}\n`);
    }

    // byPointer: the user moved the mouse (leave the pointer there).
    function scrollAutoStop(byPointer) {
        if (scrollAuto !== "starting" && scrollAuto !== "running")
            return;
        scrollAuto = "stopping";
        scrollProc.write(byPointer ? "abort\n" : "stop\n");
    }

    Timer {
        id: autoCooldown
        interval: 1200
        onTriggered: root.scrollAutoCooling = false
    }

    Process {
        id: scrollProc
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => {
                let e;
                try {
                    e = JSON.parse(line);
                } catch (_) {
                    return;
                }
                if (e.event === "frame") {
                    root.scrollAxis = e.axis ?? "y";
                    root.scrollWidth = e.width;
                    root.scrollHeight = e.height;
                    root.scrollFrameWidth = e.frameWidth ?? e.width;
                    root.scrollFrameHeight = e.frameHeight;
                    root.scrollFrames = e.frames;
                    root.scrollSegments = e.segments;
                } else if (e.event === "axis") {
                    root.scrollAxis = e.axis;
                } else if (e.event === "auto") {
                    if (e.state === "stopped") {
                        root.scrollAuto = "";
                        root.scrollAutoReason = e.reason ?? "";
                        if (e.reason === "pointer") {
                            root.scrollAutoCooling = true;
                            autoCooldown.restart();
                        }
                        if (e.reason === "error" || e.reason === "unavailable")
                            root.failed("Auto Scroll failed", e.message);
                    } else if (e.state === "stopping" || root.scrollAuto !== "stopping") {
                        root.scrollAuto = e.state;
                    }
                } else if (e.event === "done") {
                    root.scrollAuto = "";
                    root.scrolling = null;
                    root.shotDone(e.path);
                } else if (e.event === "error") {
                    root.scrollAuto = "";
                    root.scrolling = null;
                    root.failed("Scrolling capture failed", e.message);
                }
            }
        }
        stderr: StdioCollector {
            id: scrollErr
        }
        onExited: code => {
            root.scrollAuto = "";
            if (root.scrolling) {
                root.scrolling = null;
                if (code !== 0)
                    root.failed("Scrolling capture failed", scrollErr.text);
            }
        }
    }

    // ── Workspace panorama ──────────────────────────────────────────────
    // Exclusive zones on the display, which niri keeps windows out of (its
    // working area): the menu bar (Bar.qml: exclusiveZone = barHeight) and
    // an always-shown dock (Dock.qml: iconSize + 2 × pad + margin, not under
    // a fullscreen window). [left, right, top, bottom], logical px.
    function exclusiveInsets(screen) {
        const ins = [0, 0, 30, 0];
        if (Features.on("dock") && screen) {
            const d = DockData.profileFor(screen);
            if (d.enabled && d.autoHide === "never" && !Displays.fullscreenOn(screen)) {
                const zone = d.iconSize + 2 * 10 + 8;
                ins[d.position === "left" ? 0 : d.position === "right" ? 1 : 3] += zone;
            }
        }
        return ins;
    }

    function startPanorama(outputName) {
        const screen = Quickshell.screens.find(s => s.name === outputName) ?? screenFocused;
        if (!screen)
            return;
        thumbnail = null;
        selectorOpen = false;
        lastPanoramaNotes = "";
        panorama = {
            screen: screen.name,
            out: newShotPath()
        };
        const args = ["loft", "capture", "panorama", screen.name, "--out", panorama.out, "--insets", exclusiveInsets(screen).join(","), "--radius", `${Math.max(0, Theme.windowRadius)}`];
        const wall = cfg.panoramaBackground === "wallpaper" ? Vibes.wallpaperFor(screen.name) : "";
        if (wall) {
            const f = Vibes.focusFor(wall) ?? [0.5, 0.5];
            args.push("--wallpaper", wall, "--focus", `${f[0]},${f[1]}`);
        } else {
            args.push("--backdrop", `${Theme.bg}`);
        }
        // Let the selector and the thumbnail unmap first.
        panoProc.command = args;
        panoStart.restart();
    }

    Timer {
        id: panoStart
        interval: 120
        onTriggered: panoProc.running = true
    }

    Process {
        id: panoProc
        stdout: StdioCollector {
            id: panoOut
        }
        stderr: StdioCollector {
            id: panoErr
        }
        onExited: code => {
            root.panorama = null;
            let r = null;
            try {
                r = JSON.parse(panoOut.text.trim().split("\n").slice(-1)[0] || "null");
            } catch (_) {}
            if (code === 0 && r?.event === "done") {
                root.lastPanoramaNotes = (r.notes ?? []).join("; ");
                root.shotDone(r.path);
            } else if (r?.reason === "empty") {
                root.failed("Nothing to capture", "This desktop has no windows");
            } else {
                root.failed("Workspace capture failed", r?.message ?? panoErr.text);
            }
        }
    }

    // ── Text from screen (QR first, then OCR) ───────────────────────────
    function recognize(png) {
        exec(["sh", "-c", 'zbarimg -q --raw "$1" 2>/dev/null', "sh", png], (code, out) => {
            const qr = out.trim();
            if (code === 0 && qr !== "") {
                root.copied(qr, "QR code copied", "qr");
                root.exec(["rm", "-f", png]);
                return;
            }
            root.exec(["tesseract", png, "-", "-l", root.cfg.ocrLanguage || "eng"], (c, text, err) => {
                root.exec(["rm", "-f", png]);
                const t = text.replace(/\f/g, "").replace(/\n{3,}/g, "\n\n").trim();
                if (c !== 0)
                    root.failed("Text recognition failed", err);
                else if (t === "")
                    root.failed("No text found", "Try a larger or sharper selection");
                else
                    root.copied(t, "Text copied", "ocr");
            });
        });
    }

    // Last recognized text, for the banner's body and tests.
    property string lastText: ""

    function copied(text, summary, kind) {
        lastText = text;
        exec(["wl-copy", "--", text]);
        Notifications.show({
            appName: kind === "qr" ? "QR Code" : "Text from Screen",
            appIcon: kind === "qr" ? "view-barcode-qr" : "edit-select-text",
            summary: summary,
            body: text.replace(/\s+/g, " "),
            image: "",
            actions: []
        });
    }

    // ── Color picker ────────────────────────────────────────────────────
    readonly property var colorFormats: [
        {
            value: "hex",
            label: "HEX  #7aa2f7"
        },
        {
            value: "rgb",
            label: "RGB  rgb(122, 162, 247)"
        },
        {
            value: "hsl",
            label: "HSL  hsl(221, 89%, 72%)"
        },
        {
            value: "qml",
            label: "QML  Qt.rgba(0.478, …)"
        }
    ]

    function formatColor(hex, fmt) {
        const c = Qt.color(hex);
        const r = Math.round(c.r * 255), g = Math.round(c.g * 255), b = Math.round(c.b * 255);
        switch (fmt) {
        case "rgb":
            return `rgb(${r}, ${g}, ${b})`;
        case "hsl":
            {
                const max = Math.max(c.r, c.g, c.b), min = Math.min(c.r, c.g, c.b);
                const l = (max + min) / 2;
                const d = max - min;
                let h = 0, s = 0;
                if (d > 0) {
                    s = d / (1 - Math.abs(2 * l - 1));
                    if (max === c.r)
                        h = ((c.g - c.b) / d) % 6;
                    else if (max === c.g)
                        h = (c.b - c.r) / d + 2;
                    else
                        h = (c.r - c.g) / d + 4;
                    h = Math.round(h * 60);
                    if (h < 0)
                        h += 360;
                }
                return `hsl(${h}, ${Math.round(s * 100)}%, ${Math.round(l * 100)}%)`;
            }
        case "qml":
            return `Qt.rgba(${c.r.toFixed(3)}, ${c.g.toFixed(3)}, ${c.b.toFixed(3)}, 1)`;
        default:
            return hex.toLowerCase();
        }
    }

    property string lastColor: ""

    function pickedColor(hex) {
        if (!hex)
            return;
        lastColor = hex;
        cfg.recentColors = [hex].concat(cfg.recentColors.filter(c => c !== hex)).slice(0, 10);
        copyColor(hex);
    }

    function copyColor(hex) {
        const text = formatColor(hex, cfg.colorFormat);
        exec(["wl-copy", "--", text]);
        Notifications.show({
            appName: "Color Picker",
            appIcon: "color-select",
            summary: `${text} copied`,
            body: cfg.colorFormat === "hex" ? formatColor(hex, "rgb") : hex,
            image: "",
            actions: []
        });
    }

    // ── Follow-ups ──────────────────────────────────────────────────────
    function annotate(path) {
        thumbnail = null;
        // satty saves over the capture (Ctrl+S) and copies with wl-copy.
        Quickshell.execDetached(["satty", "--filename", path, "--output-filename", path, "--copy-command", "wl-copy", "--early-exit"]);
    }

    function pin(path) {
        thumbnail = null;
        pinSerial++;
        pins = pins.concat([
            {
                id: pinSerial,
                path: path,
                screen: screenFocused?.name ?? ""
            }
        ]);
    }

    function unpin(id) {
        pins = pins.filter(p => p.id !== id);
    }

    function open(path) {
        Quickshell.execDetached(["xdg-open", path]);
    }

    function trash(path) {
        thumbnail = null;
        exec(["sh", "-c", 'gio trash "$1" 2>/dev/null || rm -f "$1"', "sh", path]);
    }

    // A recording finished (Recorder): thumbnail with a poster frame.
    function recordingDone(path) {
        lastVideo = path;
        if (!cfg.showThumbnail)
            return;
        const poster = `${tmp}/poster-${Date.now()}.png`;
        exec(["sh", "-c", 'mkdir -p "$(dirname "$2")" && ffmpeg -v error -y -i "$1" -frames:v 1 -update 1 "$2"', "sh", path, poster], code => {
            root.thumbnail = {
                path: path,
                kind: "video",
                poster: code === 0 ? poster : ""
            };
        });
    }

    Connections {
        target: Recorder
        function onFinished(path, ok) {
            if (ok)
                root.recordingDone(path);
        }
    }

    function exportGif(path) {
        const out = path.replace(/\.[^./]+$/, "") + ".gif";
        busy = "Exporting GIF…";
        const fps = cfg.gifFps, width = cfg.gifWidth;
        exec(["ffmpeg", "-v", "error", "-y", "-i", path, "-vf", `fps=${fps},scale='min(${width},iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4`, "-loop", "0", out], (code, _o, err) => {
            root.busy = "";
            if (code !== 0) {
                root.failed("GIF export failed", err);
                return;
            }
            Notifications.show({
                appName: "Screen Recording",
                appIcon: "image-gif",
                summary: "GIF exported",
                body: root.pretty(out),
                image: "",
                actions: []
            });
        });
    }

    // Open the recording editor (CaptureTrim): trim, and zoom segments.
    function startTrim(path) {
        thumbnail = null;
        exec(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration", "-of", "json", path], (code, out) => {
            let d = 0, w = 0, h = 0;
            try {
                const j = JSON.parse(out);
                d = parseFloat(j.format.duration);
                w = j.streams[0]?.width ?? 0;
                h = j.streams[0]?.height ?? 0;
            } catch (_) {}
            if (code !== 0 || !(d > 0)) {
                root.failed("Can't read the recording", path);
                return;
            }
            root.trimming = {
                path: path,
                duration: d,
                width: w,
                height: h
            };
        });
    }

    // Auto zoom: segments where the recording shows local activity (the
    // pointer, clicks that change the UI, typing) — `loft capture zoom auto`.
    // cb(segments | null).
    property bool zoomAnalyzing: false
    function autoZoom(path, cb) {
        zoomAnalyzing = true;
        exec(["loft", "capture", "zoom", "auto", path], (code, out, err) => {
            root.zoomAnalyzing = false;
            let segs = null;
            try {
                segs = code === 0 ? JSON.parse(out).segments : null;
            } catch (_) {}
            if (segs === null)
                root.failed("Auto zoom failed", err);
            cb(segs);
        });
    }

    // Export the edit: zoom segments (source seconds) and the trim range go
    // into a new "<name>-zoomed.mp4"; without segments it's a plain trim.
    function exportEdit(path, start, end, duration, segments) {
        if (!segments || segments.length === 0) {
            trim(path, start, end);
            return;
        }
        trimming = null;
        busy = "Exporting zooms…";
        const args = ["loft", "capture", "zoom", "render", path, "--segments", JSON.stringify(segments)];
        if (start > 0.01)
            args.push("--start", start.toFixed(3));
        if (end < duration - 0.01)
            args.push("--end", end.toFixed(3));
        exec(args, (code, out, err) => {
            root.busy = "";
            let r = null;
            try {
                r = code === 0 ? JSON.parse(out) : null;
            } catch (_) {}
            if (!r) {
                root.failed("Export failed", err);
                return;
            }
            root.lastZoomExport = r.path;
            root.recordingDone(r.path);
        });
    }
    property string lastZoomExport: ""

    // Cut [start, end] seconds into "<name>-trimmed.<ext>" (re-encodes video
    // for a frame-exact start; audio tracks are kept).
    function trim(path, start, end) {
        trimming = null;
        const out = path.replace(/(\.[^./]+)$/, "-trimmed$1");
        busy = "Trimming…";
        exec(["ffmpeg", "-v", "error", "-y", "-ss", start.toFixed(3), "-to", end.toFixed(3), "-i", path, "-map", "0", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-c:a", "copy", out], (code, _o, err) => {
            root.busy = "";
            if (code !== 0) {
                root.failed("Trim failed", err);
                return;
            }
            root.recordingDone(out);
        });
    }

    function failed(summary, detail) {
        console.warn(`Capture: ${summary}: ${detail ?? ""}`);
        Notifications.show({
            appName: "Capture",
            appIcon: "dialog-warning",
            summary: summary,
            body: (detail ?? "").trim().split("\n").slice(-1)[0] ?? "",
            image: "",
            actions: []
        });
    }

    // ── Process helper ──────────────────────────────────────────────────
    // exec(argv, cb(code, stdout, stderr)) — one Process per job.
    function exec(argv, cb) {
        const job = jobComponent.createObject(root, {
            command: argv,
            callback: cb ?? null
        });
        job.running = true;
    }

    Component {
        id: jobComponent
        Process {
            id: job
            property var callback: null
            stdout: StdioCollector {
                id: out
            }
            stderr: StdioCollector {
                id: err
            }
            onExited: code => {
                if (job.callback)
                    job.callback(code, out.text, err.text);
                job.destroy();
            }
        }
    }

    // ── Recorder + settings plumbing ────────────────────────────────────
    Binding {
        target: Recorder
        property: "dir"
        value: root.recordingDir
    }
    Binding {
        target: Recorder
        property: "audio"
        value: root.cfg.audio
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

            property string screenshotDir: "~/Pictures/Screenshots"
            property string recordingDir: "~/Videos/Recordings"
            // Selector defaults (remembered).
            property string lastMode: "shot"
            property string lastTarget: "area"
            property int timer: 0 // seconds: 0, 3, 10
            property bool copyToClipboard: true
            property bool showThumbnail: true
            property bool annotateAfter: false
            property bool showPointer: false
            // Recording audio: none | system | mic | both (separate tracks).
            property string audio: "none"
            property int gifFps: 15
            property int gifWidth: 960
            property string ocrLanguage: "eng"
            // Color picker: hex | rgb | hsl | qml.
            property string colorFormat: "hex"
            // Scrolling capture direction: auto (the first scroll decides) |
            // y (down) | x (sideways).
            property string scrollDirection: "auto"
            // Workspace panorama background: wallpaper | plain (Theme.bg).
            property string panoramaBackground: "wallpaper"
            property list<string> recentColors: []
            // Camera mirror: circle | rounded; size in px; mirrored.
            property string cameraShape: "circle"
            property int cameraSize: 220
            property bool cameraMirror: true
            property string cameraDevice: "" // id; "" = system default
        }
    }

    Component.onCompleted: view.path = `${Settings.stateDir}/overrides/capture.json`

    Process {
        id: mkdir
        command: ["mkdir", "-p", `${Settings.stateDir}/overrides`]
        onExited: {
            view.writeAdapter();
            view.path = "";
            view.path = `${Settings.stateDir}/overrides/capture.json`;
        }
    }

    // ── IPC ─────────────────────────────────────────────────────────────
    IpcHandler {
        target: "capture"

        function toggle(): void {
            if (Features.on("capture"))
                root.toggleSelector();
        }
        function area(): void {
            root.capture("shot", "area", 0);
        }
        function screen(): void {
            root.capture("shot", "screen", 0);
        }
        function window(): void {
            root.capture("shot", "window", 0);
        }
        function scrolling(): void {
            root.capture("scroll", "area", 0);
        }
        function scrollDone(): void {
            root.scrollDone();
        }
        function scrollCancel(): void {
            root.scrollCancel();
        }
        function scrollHeight(): int {
            return root.scrollHeight;
        }
        // Auto Scroll without a place to put the pointer back.
        function scrollAuto(): void {
            root.scrollAutoStart(NaN, NaN);
        }
        function scrollStop(): void {
            root.scrollAutoStop(false);
        }
        function scrollAutoState(): string {
            return `${root.scrollAuto || "off"} ${root.scrollAutoReason}`.trim();
        }
        // y | x | auto, during a scrolling capture.
        function scrollAxis(axis: string): void {
            root.scrollSetAxis(axis);
        }
        function scrollAxisState(): string {
            return root.scrolling ? root.scrollAxis : "";
        }
        function scrollWidth(): int {
            return root.scrollWidth;
        }
        // One image of the whole niri workspace on a display ("" = the
        // focused one): every column side by side.
        function panorama(output: string): void {
            root.capture("panorama", output || "screen", 0);
        }
        function panoramaState(): string {
            return root.panorama ? "running" : `idle ${root.lastPanoramaNotes}`.trim();
        }
        function recordArea(): void {
            root.capture("record", "area", 0);
        }
        function recordScreen(): void {
            root.capture("record", "screen", 0);
        }
        function text(): void {
            root.capture("text", "area", 0);
        }
        function color(): void {
            root.capture("color", "area", 0);
        }
        function cancel(): void {
            root.cancel();
            panoStart.stop();
            root.scrollCancel();
            root.selectorOpen = false;
        }
        function annotateLast(): void {
            if (root.lastImage)
                root.annotate(root.lastImage);
        }
        function pinLast(): void {
            if (root.lastImage)
                root.pin(root.lastImage);
        }
        function gifLast(): void {
            if (root.lastVideo)
                root.exportGif(root.lastVideo);
        }
        function trimLast(): void {
            if (root.lastVideo)
                root.startTrim(root.lastVideo);
        }
        function editLast(): void {
            if (root.lastVideo)
                root.startTrim(root.lastVideo);
        }
        // Open any video in the recording editor (trim + zooms).
        function edit(path: string): void {
            root.startTrim(path);
        }
        function lastZoomExport(): string {
            return root.lastZoomExport;
        }
        function unpinAll(): void {
            root.pins = [];
        }
        function lastText(): string {
            return root.lastText;
        }
        function lastColor(): string {
            return root.lastColor;
        }

        // Tests (LOFT_DEV=1 only): finish the open area selection with a
        // fixed rect / pick a fixed pixel, since slurp-style dragging needs
        // real pointer input.
        function testSelect(): void {
            if (root.dev)
                root.testRequested("select");
        }
        function testPick(): void {
            if (root.dev)
                root.testRequested("pick");
        }
        function testHover(): void {
            if (root.dev)
                root.testRequested("hover");
        }
    }

    signal testRequested(string what)

    IpcHandler {
        target: "camera"

        function toggle(): void {
            root.cameraOn = !root.cameraOn && Features.on("camera");
        }
        function on(): void {
            root.cameraOn = Features.on("camera");
        }
        function off(): void {
            root.cameraOn = false;
        }
    }
}
