pragma Singleton

import QtQml
import QtQuick
import Quickshell
import Quickshell.Io

// How bright the wallpaper is, per screen: under the menu bar (so the
// transparent bar picks light or dark text, Theme.barTextFor) and overall
// (what glass surfaces show through, Theme.glassBackdrop).
//
// The image the screen shows (Vibes.wallpaperFor) is scaled and cropped the
// way the wallpaper layer does it (fill, centered), then ffmpeg averages the
// strip under the bar and the whole screen into 16 columns each. Sampled
// once per (image, screen size) and cached; the gradient fallback is read
// from the theme. No ffmpeg: unknown, and the bar follows the theme.
Singleton {
    id: root

    // Menu bar height the strip is measured for (Bar.qml's barHeight).
    property int barHeight: 30

    // screen name → { top: color, mean: color, topLuminance, meanLuminance, columns: [color] }
    property var tones: ({})
    // "<path>|<w>x<h>" → the same, so switching back costs nothing.
    property var cache: ({})

    function firstScreen() {
        return Quickshell.screens.length > 0 ? Quickshell.screens[0].name : "";
    }

    function toneOf(screen) {
        return tones[screen || firstScreen()] ?? null;
    }

    // Relative luminance (0..1) of the strip under the bar; -1 = unknown.
    function barLuminance(screen) {
        return toneOf(screen)?.topLuminance ?? -1;
    }

    // Mean color of the whole wallpaper, or null when unknown.
    function meanColor(screen) {
        return toneOf(screen)?.mean ?? null;
    }

    function luminance(c) {
        const lin = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
    }

    function setTone(screen, tone) {
        const t = Object.assign({}, tones);
        t[screen] = tone;
        tones = t;
    }

    function toneFromColors(top, mean, columns) {
        return {
            top: top,
            mean: mean,
            topLuminance: luminance(top),
            meanLuminance: luminance(mean),
            columns: columns
        };
    }

    // ── sampling ────────────────────────────────────────────────────────
    property var queue: []
    property var job: null

    function request(screen, path, w, h) {
        if (w <= 0 || h <= 0)
            return;
        if (!path) {
            // The gradient fallback (background/Wallpaper.qml): top stop
            // under the bar, the middle stop as the overall color.
            const g = Theme.wallpaperGradient;
            const top = Qt.color(g[0] ?? Theme.bg);
            setTone(screen, toneFromColors(top, Qt.color(g[1] ?? g[0] ?? Theme.bg), [top]));
            return;
        }
        const file = path.startsWith("file://") ? path.slice(7) : path;
        const key = `${file}|${w}x${h}`;
        if (cache[key]) {
            setTone(screen, cache[key]);
            return;
        }
        queue = queue.filter(j => j.screen !== screen).concat([
            {
                screen,
                file,
                key,
                w,
                h
            }
        ]);
        next();
    }

    function next() {
        if (job !== null || queue.length === 0)
            return;
        job = queue[0];
        queue = queue.slice(1);
        // A 320 px wide stand-in for the screen keeps it cheap.
        const sw = 320;
        const sh = Math.max(2, Math.round(sw * job.h / job.w));
        const bh = Math.max(1, Math.round(root.barHeight * sw / job.w));
        sampler.command = ["sh", "-c", 'ffmpeg -v error -nostdin -i "$1" -frames:v 1 -filter_complex "[0:v]scale=$2:$3:force_original_aspect_ratio=increase,crop=$2:$3,split[a][b];[a]crop=$2:$4:0:0,scale=16:1:flags=area[top];[b]scale=16:1:flags=area[all];[top][all]vstack,format=rgb24" -f rawvideo - | od -An -v -tu1', "sh", job.file, String(sw), String(sh), String(bh)];
        sampler.running = true;
    }

    function finish(text) {
        const j = job;
        job = null;
        const v = text.trim().split(/\s+/).filter(s => s !== "").map(Number);
        if (j && v.length >= 96) {
            const px = i => Qt.rgba(v[i * 3] / 255, v[i * 3 + 1] / 255, v[i * 3 + 2] / 255, 1);
            const avg = list => {
                let r = 0, g = 0, b = 0;
                for (const c of list) {
                    r += c.r;
                    g += c.g;
                    b += c.b;
                }
                return Qt.rgba(r / list.length, g / list.length, b / list.length, 1);
            };
            const columns = [];
            for (let i = 0; i < 16; i++)
                columns.push(px(i));
            const all = [];
            for (let i = 16; i < 32; i++)
                all.push(px(i));
            const tone = toneFromColors(avg(columns), avg(all), columns);
            const c = Object.assign({}, cache);
            c[j.key] = tone;
            cache = c;
            setTone(j.screen, tone);
        } else if (j) {
            console.warn(`WallpaperTone: could not sample ${j.file}`);
        }
        next();
    }

    Process {
        id: sampler
        stdout: StdioCollector {
            onStreamFinished: root.finish(text)
        }
    }

    // One watcher per screen: re-sample when its wallpaper or size changes.
    Instantiator {
        model: Quickshell.screens
        delegate: QtObject {
            required property ShellScreen modelData
            readonly property string source: Vibes.wallpaperFor(modelData.name)
            readonly property string key: `${source}|${modelData.width}x${modelData.height}|${Theme.wallpaperGradient}`
            onKeyChanged: root.request(modelData.name, source, modelData.width, modelData.height)
            Component.onCompleted: root.request(modelData.name, source, modelData.width, modelData.height)
        }
    }
}
