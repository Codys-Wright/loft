pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Settings → Keyboard & Mouse under KWin (docs/KWIN.md §4.12). niri's values
// come from NiriSettings instead; this is only read under KWin.
//
//   key repeat   kcminputrc [Keyboard] (RepeatDelay ms, RepeatRate per
//                second); KWin applies it as soon as it's written with --notify
//   layouts      kxkbrc [Layout], through `loft-kwin input set`, which tells
//                KWin's KConfigWatcher so the keymap changes at once
//   mouse,       KWin's InputDevice D-Bus per libinput device (live, and KWin
//   trackpad     records it in kcminputrc [Libinput][vendor][product][name]);
//                `loft-kwin input set` sends a niri-named change to every
//                device of that kind that supports it
//
// mouse / touchpad: { devices: [name], supported: [niri key], values: {key: v} }
// (the first device's values: niri has one per section, KDE one per device).
Singleton {
    id: root

    readonly property bool wanted: Compositor.backend === "kwin"
    property int repeatDelay: 600
    property int repeatRate: 25
    property bool loaded: false

    property string xkbLayout: ""
    property string xkbVariant: ""
    property string xkbOptions: ""
    // false: KWin has no libinput devices (a nested KWin), so no mouse or
    // trackpad settings to show.
    property bool libinput: false
    property var mouse: ({ devices: [], supported: [], values: {} })
    property var touchpad: ({ devices: [], supported: [], values: {} })
    property string error: ""
    property var queue: []

    function section(id) {
        return id === "touchpad" ? touchpad : mouse;
    }

    function supports(id, key) {
        return (section(id).supported ?? []).indexOf(key) >= 0;
    }

    function value(id, key) {
        return section(id).values?.[key];
    }

    function setRepeat(delay, rate) {
        repeatDelay = delay;
        repeatRate = rate;
        writer.command = ["sh", "-c", 'kwriteconfig6 --notify --file kcminputrc --group Keyboard --key KeyRepeat repeat'
            + ' && kwriteconfig6 --notify --file kcminputrc --group Keyboard --key RepeatDelay "$1"'
            + ' && kwriteconfig6 --notify --file kcminputrc --group Keyboard --key RepeatRate "$2"', "sh", String(delay), String(rate)];
        writer.running = true;
    }

    // field: layout | variant | options (niri's xkb names).
    function setXkb(field, v) {
        if (field === "layout")
            xkbLayout = v;
        else if (field === "variant")
            xkbVariant = v;
        else if (field === "options")
            xkbOptions = v;
        const kb = {};
        kb[field] = v;
        apply({ keyboard: kb });
    }

    // id: mouse | touchpad; key: niri's (accel-speed, natural-scroll, tap, …).
    function setDevice(id, key, v) {
        const s = Object.assign({}, section(id));
        s.values = Object.assign({}, s.values ?? {});
        s.values[key] = v;
        if (id === "touchpad")
            touchpad = s;
        else
            mouse = s;
        const change = {};
        change[id] = {};
        change[id][key] = v;
        apply(change);
    }

    function apply(batch) {
        queue = queue.concat([batch]);
        if (!setter.running)
            next();
    }

    function next() {
        if (queue.length === 0)
            return;
        const [b, ...rest] = queue;
        queue = rest;
        setter.command = ["loft-kwin", "input", "set", JSON.stringify(b)];
        setter.running = true;
    }

    function reload() {
        if (!wanted)
            return;
        reader.running = true;
        if (!state.running)
            state.running = true;
    }

    Component.onCompleted: reload()

    // A layout list changed elsewhere (System Settings, `loft-kwin input set`):
    // KWin's org.kde.keyboard says so through the bridge.
    Connections {
        target: Compositor
        enabled: root.wanted
        function onKeyboardLayoutsChanged() {
            if (!setter.running && root.queue.length === 0)
                root.reload();
        }
    }

    Process {
        id: reader
        // KDE's defaults when kcminputrc says nothing: 600 ms, 25/s.
        command: ["sh", "-c", 'echo "$(kreadconfig6 --file kcminputrc --group Keyboard --key RepeatDelay --default 600) '
            + '$(kreadconfig6 --file kcminputrc --group Keyboard --key RepeatRate --default 25)"']
        stdout: StdioCollector {
            onStreamFinished: {
                const [d, r] = text.trim().split(/\s+/).map(Number);
                if (d > 0)
                    root.repeatDelay = Math.round(d);
                if (r > 0)
                    root.repeatRate = Math.round(r);
                root.loaded = true;
            }
        }
    }

    Process {
        id: state
        command: ["loft-kwin", "input"]
        stdout: StdioCollector {
            onStreamFinished: {
                let r = null;
                try {
                    r = JSON.parse(text);
                } catch (e) {
                    console.warn(`KdeInput: bad loft-kwin input: ${e}`);
                    return;
                }
                if (!r.ok) {
                    root.error = r.error ?? "loft-kwin input failed";
                    return;
                }
                root.xkbLayout = r.keyboard?.layout ?? "";
                root.xkbVariant = r.keyboard?.variant ?? "";
                root.xkbOptions = r.keyboard?.options ?? "";
                root.libinput = r.libinput === true;
                root.mouse = r.mouse ?? root.mouse;
                root.touchpad = r.touchpad ?? root.touchpad;
            }
        }
    }

    Process {
        id: setter
        stdout: StdioCollector {
            onStreamFinished: {
                let r = null;
                try {
                    r = JSON.parse(text);
                } catch (e) {
                    r = { ok: false, error: text.trim() || `${e}` };
                }
                root.error = r.ok ? "" : (r.error ?? "loft-kwin input set failed");
            }
        }
        onExited: code => {
            if (code !== 0 && root.error === "")
                root.error = `loft-kwin input exited with ${code}`;
            if (root.queue.length > 0)
                root.next();
            else
                root.reload();
        }
    }

    Process {
        id: writer
        onExited: code => {
            if (code !== 0)
                console.warn(`KdeInput: kwriteconfig6 failed (${code})`);
        }
    }
}
