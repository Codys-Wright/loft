pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import qs.services

// Live (video) wallpapers: when they may play, the display-sized copies they
// play from, and what is playing now (for `perf status` / `loft doctor perf`).
//
// When a video plays (WallpaperView asks mayPlay(screen)): only the surface
// the screen shows (playVideo), and only while it can be seen. It holds its
// frame (paused: no decoding; after 10 s the decoder is dropped, see
// WallpaperView) while
//   - Settings → Wallpaper → Video wallpapers is "Still frame",
//   - the session is locked, or nobody has touched the machine for
//     `pauseWhenIdleMinutes` (the screens blank around then),
//   - on battery or in power saver (pauseOnBattery),
//   - an opaque window covers the whole screen: a fullscreen tiled window of
//     an app on the opaque list, or any app when window glass is off (a
//     translucent window shows the wallpaper through it), or with
//     pauseWhenMaximized any window filling the screen.
//
// Display-sized copies (`smallerCopies`): the originals are often 5K, 10-bit
// HEVC, cropped to cover each screen. Decoding more than the screen shows
// costs GPU memory and bandwidth (and, without zero-copy, the GUI thread's
// time), so each layer asks for a copy of exactly what it shows: the visible
// crop at the screen's pixel size, 8-bit (NV12) HEVC, made once in the
// background by `loft wallpaper video-variant` (NVENC when there is an
// NVIDIA GPU) and cached in ~/.cache/loft/wallpaper-video. The original plays
// until its copy exists; it is never touched.
Singleton {
    id: root

    readonly property var cfg: Settings.wallpaper
    readonly property bool stillOnly: cfg.video === "still"

    // ── When a video may play ────────────────────────────────────────────
    // Armed a moment after start: an IdleMonitor enabled while its timeout
    // is still the default 0 reports idle at once and stays so.
    property bool idleArmed: false
    Timer {
        interval: 1000
        running: true
        onTriggered: root.idleArmed = true
    }
    IdleMonitor {
        id: idleMonitor
        enabled: root.idleArmed && root.cfg.pauseWhenIdleMinutes > 0
        respectInhibitors: true
        timeout: Math.max(1, root.cfg.pauseWhenIdleMinutes) * 60
    }
    readonly property bool idle: idleMonitor.enabled && idleMonitor.isIdle
    readonly property bool onBattery: UPower.onBattery
    readonly property bool powerSaver: PowerProfiles.profile === PowerProfile.PowerSaver
    readonly property bool batteryPause: cfg.pauseOnBattery && (onBattery || powerSaver)

    // Why videos are held everywhere ("" = they may play).
    readonly property string globalReason: stillOnly ? "still frame only" : LockState.locked ? "locked" : idle ? "idle" : batteryPause ? (onBattery ? "on battery" : "power saver") : ""

    // Screens whose active workspace an opaque window covers: name → reason.
    readonly property var covered: {
        const out = {};
        if (Niri.overviewOpen)
            return out;
        const glass = WindowRules.enabled;
        for (const s of Quickshell.screens) {
            const ws = Niri.workspaces.find(w => w.output === s.name && w.is_active);
            if (!ws)
                continue;
            for (const w of Niri.windows) {
                const size = w.layout?.window_size;
                if (w.workspace_id !== ws.id || w.is_floating || !size)
                    continue;
                const full = size[0] >= s.width && size[1] >= s.height;
                if (full && (!glass || WindowRules.isOpaque(w.app_id ?? ""))) {
                    out[s.name] = "fullscreen window";
                    break;
                }
                if (cfg.pauseWhenMaximized && size[0] >= s.width * 0.9 && size[1] >= s.height * 0.8) {
                    out[s.name] = "maximized window";
                    break;
                }
            }
        }
        return out;
    }

    function holdReason(screenName) {
        return globalReason || (covered[screenName] ?? "");
    }
    function mayPlay(screenName) {
        return holdReason(screenName) === "";
    }

    // ── What is loaded / playing (WallpaperView's layers report) ─────────
    // id → { path, screen, playing, display, wanted }
    property var players: ({})
    property int _nextId: 1
    function newId() {
        return _nextId++;
    }
    function report(id, info) {
        if (!id || (info === null && !(id in players)))
            return;
        const p = Object.assign({}, players);
        if (info === null)
            delete p[id];
        else
            p[id] = info;
        players = p;
    }
    readonly property var playerList: Object.values(players)
    readonly property int loadedCount: playerList.length
    readonly property int playingCount: playerList.filter(p => p.playing).length

    // How Qt decodes video here: the loft-shell wrapper sets the device list
    // and says whether its QtMultimedia has the zero-copy VAAPI fix
    // (nix/qt/qtmultimedia-vaapi-separate-layers.patch).
    readonly property string hwDevices: Quickshell.env("QT_FFMPEG_DECODING_HW_DEVICE_TYPES") ?? "auto"
    readonly property bool zeroCopyQt: (Quickshell.env("LOFT_QT_VAAPI_ZERO_COPY") ?? "") === "1"
    readonly property string decodePath: hwDevices === "," || hwDevices === "" ? "software" : hwDevices === "vaapi" && zeroCopyQt ? "vaapi zero-copy" : `hw (${hwDevices}${zeroCopyQt ? ", zero-copy fix" : ", stock Qt: may copy frames back"})`

    // ── Display-sized copies ─────────────────────────────────────────────
    // key → path ("" = none: generating, failed, or not worth it)
    property var variants: ({})
    property var failed: ({})
    property var queue: []
    property string busyKey: ""

    // The copy of `video` showing the crop [x, y, w, h] (fractions of the
    // frame) at w × h pixels; "" until it exists. Pure (bindable); layers
    // call request() for the same arguments to have it made.
    function variantKey(video, crop, w, h) {
        const r = v => Math.round(v * 1000) / 1000;
        return [video, crop.map(r).join(","), Math.round(w), Math.round(h)].join("|");
    }
    function variant(video, crop, w, h) {
        if (!cfg.smallerCopies || !video || w < 16 || h < 16)
            return "";
        return variants[variantKey(video, crop, w, h)] ?? "";
    }
    function request(video, crop, w, h) {
        if (!cfg.smallerCopies || !video || w < 16 || h < 16)
            return;
        const key = variantKey(video, crop, w, h);
        if (variants[key] !== undefined || failed[key] || busyKey === key || queue.includes(key))
            return;
        queue = queue.concat([key]);
        pump();
    }
    function pump() {
        if (busyKey !== "" || queue.length === 0)
            return;
        busyKey = queue[0];
        queue = queue.slice(1);
        const [video, crop, w, h] = busyKey.split("|");
        const path = video.startsWith("file://") ? video.slice(7) : video;
        maker.command = ["nice", "-n", "15", "loft", "wallpaper", "video-variant", path, "--crop", crop, "--size", `${w}x${h}`, "--json"];
        maker.running = true;
    }
    Process {
        id: maker
        stdout: StdioCollector {
            id: makerOut
        }
        stderr: StdioCollector {
            id: makerErr
        }
        onExited: code => {
            const key = root.busyKey;
            let r = null;
            try {
                r = JSON.parse(makerOut.text);
            } catch (e) {}
            const v = Object.assign({}, root.variants);
            if (code === 0 && r?.path) {
                v[key] = r.useOriginal ? "" : "file://" + r.path;
                if (!r.cached)
                    console.info(`video wallpaper: made a ${r.width}x${r.height} copy of ${key.split("|")[0].split("/").pop()} (${r.encoder}, ${r.seconds}s)`);
            } else {
                const f = Object.assign({}, root.failed);
                f[key] = true;
                root.failed = f;
                console.warn(`video wallpaper: no display-sized copy (${code}): ${(makerErr.text || makerOut.text).trim().split("\n").pop()}`);
            }
            root.variants = v;
            root.busyKey = "";
            Qt.callLater(root.pump);
        }
    }

    // `qs ipc call videowallpapers stats`
    IpcHandler {
        target: "videowallpapers"

        function stats(): string {
            return JSON.stringify({
                mode: root.stillOnly ? "still" : "play",
                held: root.globalReason,
                covered: root.covered,
                decode: root.decodePath,
                loaded: root.loadedCount,
                playing: root.playingCount,
                players: root.playerList,
                copies: Object.keys(root.variants).filter(k => root.variants[k] !== "").length,
                making: root.busyKey !== "" ? root.queue.length + 1 : 0
            });
        }
    }
}
