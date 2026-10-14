pragma Singleton

import QtQuick
import Quickshell

// The Dynamic Island's expanded pages: which exist, their order and which are
// shown (Settings → Dynamic Island → Pages; Settings.island.pages). Pages
// that depend on something (a live activity, the camera, notifications)
// still only appear while it's there.
Singleton {
    id: root

    readonly property var all: [
        { id: "live", label: "Live Activities", icon: "󰐊", hint: "Recording, focus, timers and downloads while they run" },
        { id: "camera", label: "Camera", icon: "󰄀", hint: "While the camera mirror is on" },
        { id: "notifications", label: "Notifications", icon: "󰂚", hint: "When there are any" },
        { id: "calendar", label: "Calendar", icon: "󰃭", hint: "Today and tomorrow, with join buttons" },
        { id: "media", label: "Now Playing", icon: "󰎆", hint: "Art, transport and lyrics" },
        { id: "timers", label: "Timers", icon: "󰔛", hint: "Countdowns and stopwatches" },
        { id: "controls", label: "Controls", icon: "󰒓", hint: "Do Not Disturb, Keep Awake, microphones, recording" },
        { id: "system", label: "System", icon: "󰍛", hint: "Clock, CPU, GPU and memory" },
        { id: "usage", label: "Screen Time", icon: "󰄉", hint: "Today's top apps" },
        { id: "ai", label: "AI Agents", icon: "󰚩", hint: "Claude Code and Codex usage, sessions running now" }
    ]

    // [{ id, shown }] in order: the saved order, new pages where the default puts them.
    readonly property var order: {
        const saved = (Settings.island.pages ?? []).filter(p => p && all.some(a => a.id === p.id));
        const out = saved.map(p => ({ id: p.id, shown: p.shown !== false }));
        for (let i = 0; i < all.length; i++) {
            if (out.some(p => p.id === all[i].id))
                continue;
            let at = 0;
            for (let j = i - 1; j >= 0; j--) {
                const k = out.findIndex(p => p.id === all[j].id);
                if (k >= 0) {
                    at = k + 1;
                    break;
                }
            }
            out.splice(at, 0, { id: all[i].id, shown: true });
        }
        return out;
    }

    function info(id) {
        return all.find(a => a.id === id) ?? null;
    }

    function shown(id) {
        return order.find(p => p.id === id)?.shown ?? false;
    }

    function setShown(id, on) {
        Settings.island.pages = order.map(p => p.id === id ? { id: p.id, shown: on } : p);
    }

    function move(id, delta) {
        const o = order.slice();
        const i = o.findIndex(p => p.id === id);
        const j = i + delta;
        if (i < 0 || j < 0 || j >= o.length)
            return;
        const [p] = o.splice(i, 1);
        o.splice(j, 0, p);
        Settings.island.pages = o;
    }

    function reset() {
        Settings.island.pages = [];
    }
}
