pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The Transparency and Blur dials (Settings → Appearance, Window Rules, the
// Display panel), through `loft appearance` (cli/loft/transparency.py):
//
//   level      0 Solid … 0.5 the theme's own look … 1 Clear: windows (niri
//              opacity), terminals (background-opacity), GTK glass sidebars
//              and the shell's own glass, together
//   blur       0 Clear (niri's blur off; windows stay translucent) … 1 Frosted
//   terminals  / gtk: absolute overrides (Advanced); null = follow `level`
//
// Stored in appearance.json (the user layer); the theme's material facet is
// what they scale from. The window overrides (Advanced) are loft-niri's
// `window-glass` (WindowRules.setGlass), the shell glass override the
// Liquid Glass slider (Settings.appearance.glass).
//
// Dragging: the shell's glass previews at once (Theme.transparencyPreview);
// the rest is applied at most every `throttle` ms, one `loft` at a time, the
// latest values winning — so niri and the terminals reload a few times a
// second at most, never per frame.
Singleton {
    id: root

    readonly property var info: Theme.transparency
    readonly property var eff: info.effective ?? {}
    readonly property var themeVals: info.theme ?? {}
    readonly property bool reduced: info.reduced === true || Theme.reduceTransparency

    readonly property real level: Theme.transparencyLevel
    property real blurPreview: -1
    readonly property real blur: blurPreview >= 0 ? blurPreview : (eff.blurOn === false ? 0 : (eff.blur ?? 0.5))
    readonly property real terminals: eff.terminals ?? 0.85
    readonly property real gtk: eff.gtk ?? 0.63

    readonly property bool levelSet: info.level !== null && info.level !== undefined
    readonly property bool blurSet: info.blur !== null && info.blur !== undefined
    readonly property bool terminalsSet: info.terminals !== null && info.terminals !== undefined
    readonly property bool gtkSet: info.gtk !== null && info.gtk !== undefined
    readonly property bool windowsSet: WindowRules.userGlass.focused !== undefined || WindowRules.userGlass.unfocused !== undefined
    readonly property bool anySet: levelSet || blurSet || terminalsSet || gtkSet || windowsSet || Settings.appearance.glass >= 0

    property string error: ""
    property int throttle: 300

    // key → value (null = back to following); sent by the next flush.
    property var pending: ({})
    property bool again: false

    // "transparency" (= level) | "blur" | "terminals" | "gtk"; v: 0..1 or null.
    function set(key, v) {
        const p = Object.assign({}, pending);
        p[key] = v;
        pending = p;
        if (key === "transparency" || key === "level")
            Theme.transparencyPreview = v === null ? -1 : v;
        if (key === "blur")
            blurPreview = v === null ? -1 : v;
        if (!timer.running)
            timer.start();
    }

    function setLevel(v) {
        set("transparency", Math.round(v * 100) / 100);
    }
    function setBlur(v) {
        set("blur", Math.round(v * 100) / 100);
    }

    // Every dial and override back to the theme.
    function resetAll() {
        set("transparency", null);
        set("blur", null);
        set("terminals", null);
        set("gtk", null);
        Settings.appearance.glass = -1;
        if (windowsSet)
            WindowRules.setGlass({ focused: null, unfocused: null });
    }

    function flush() {
        const keys = Object.keys(pending);
        if (keys.length === 0)
            return;
        if (proc.running) {
            again = true;
            return;
        }
        proc.command = ["loft", "appearance", "set"].concat(keys.map(k => `${k}=${pending[k] === null ? "theme" : pending[k]}`));
        pending = {};
        error = "";
        proc.running = true;
    }

    Timer {
        id: timer
        interval: root.throttle
        onTriggered: root.flush()
    }

    // Previews end once theme.json shows the applied value (or after a beat).
    Timer {
        id: settle
        interval: 2500
        onTriggered: {
            Theme.transparencyPreview = -1;
            root.blurPreview = -1;
        }
    }
    onInfoChanged: {
        if (Object.keys(pending).length > 0 || proc.running)
            return;
        if (Theme.transparencyPreview >= 0 && Math.abs((info.level ?? 0.5) - Theme.transparencyPreview) < 0.005)
            Theme.transparencyPreview = -1;
        if (blurPreview >= 0 && Math.abs((eff.blurOn === false ? 0 : (eff.blur ?? 0.5)) - blurPreview) < 0.005)
            blurPreview = -1;
    }

    Process {
        id: proc
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "")
                root.error = text.trim()
        }
        onExited: code => {
            if (code !== 0 && root.error === "")
                root.error = `loft appearance exited with ${code}`;
            if (root.again || Object.keys(root.pending).length > 0) {
                root.again = false;
                root.flush();
            } else {
                settle.restart();
            }
        }
    }

    // `qs ipc call transparency …` (also `loft appearance …`, which the
    // shell itself runs).
    IpcHandler {
        target: "transparency"

        function status(): string {
            return JSON.stringify({ level: root.level, blur: root.blur, terminals: root.terminals, gtk: root.gtk, shellGlass: Theme.glass, info: root.info });
        }
        function setLevel(v: real): void {
            root.setLevel(v);
        }
        function setBlur(v: real): void {
            root.setBlur(v);
        }
        function reset(): void {
            root.resetAll();
        }
    }
}
