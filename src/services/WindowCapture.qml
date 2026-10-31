pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// What the shell may capture (window thumbnails: the app switcher, the dock
// preview), from `loft dock capture`: { screencopy, toplevel, protocols,
// dmabuf, reason }.
//
// `toplevel`: one window at a time, through Quickshell's ScreencopyView on a
// Toplevel (components/WindowThumb.qml). Quickshell 0.3 captures a Toplevel
// only over hyprland-toplevel-export-v1 (v2: by wlr-foreign-toplevel
// handle), which niri-loft adds (nix/niri/toplevel-export.patch); stock
// niri 26.04 has none, so there the switcher shows icons and the dock
// preview falls back to cropping display stills (dock/WindowThumbs.qml).
// `screencopy`: a still of a whole display. Both are off where Quickshell's
// buffer code would end the shell (dmabuf v3 only: niri on a software
// renderer, e.g. headless test sessions without --gpu).
Singleton {
    id: root

    property var support: null
    readonly property bool canWindows: support?.toplevel === true
    readonly property bool canScreens: support?.screencopy === true

    Process {
        command: ["loft", "dock", "capture"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.support = JSON.parse(text);
                } catch (e) {
                    root.support = { screencopy: false, toplevel: false, reason: "probe failed" };
                }
            }
        }
    }

    // niri window id → Quickshell Toplevel. niri's wlr-foreign-toplevel
    // handles carry no window id, but niri-loft announces them in window-id
    // order (oldest first, also to a client that binds later) and Quickshell
    // keeps that order, so an app's windows sorted by id line up with its
    // Toplevels. Only evaluated while something shows a capture.
    readonly property var toplevels: {
        if (!canWindows)
            return {};
        const byApp = {};
        for (const t of ToplevelManager.toplevels.values) {
            if (!byApp[t.appId])
                byApp[t.appId] = [];
            byApp[t.appId].push(t);
        }
        const m = {};
        for (const w of Niri.windows.slice().sort((a, b) => a.id - b.id)) {
            const q = byApp[w.app_id ?? ""];
            if (q && q.length > 0)
                m[w.id] = q.shift();
        }
        return m;
    }

    function toplevel(id) {
        return toplevels[id] ?? null;
    }
}
