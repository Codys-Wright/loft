pragma Singleton

import QtQuick
import Quickshell

// Quit on close (opt-in per app, EverydayConfig.quit.onClose): when an
// app's last window closes, its process gets SIGTERM after a short grace —
// for apps that otherwise linger in the tray or the background.
//
// Watches niri's window list. A closed window of a listed app whose
// process (pid) has no window left is checked again after the grace; if
// the pid still has no window, it's terminated. Never: the shell's own
// windows, a pid shared with other apps' windows, or Xwayland /
// xwayland-satellite (every X11 window reports that pid).
Singleton {
    id: root

    readonly property bool enabled: Features.on("quitOnClose")
    readonly property var apps: Array.from(EverydayConfig.quit.onClose ?? [])

    function isOn(appId) {
        return apps.includes(appId);
    }

    function set(appId, on) {
        EverydayConfig.quit.onClose = EverydayConfig.toggled(EverydayConfig.quit.onClose, appId, on);
    }

    // A check item for the dock's Options ▸ (MenuState's item shape).
    function menuItem(appId) {
        const on = isOn(appId);
        return { key: "quit-on-close", label: "Quit When Last Window Closes", enabled: Apps.own[appId] === undefined, toggle: "check", checked: on, run: () => root.set(appId, !on) };
    }

    // id → { app_id, pid } as of the last change.
    property var last: ({})
    // pid → { appId, at } waiting for the grace to run out.
    property var pending: ({})

    Connections {
        target: Niri
        function onWindowMapChanged() {
            root.diff();
        }
    }

    function diff() {
        const now = {};
        for (const w of Niri.windows)
            now[w.id] = { app_id: w.app_id, pid: w.pid };
        if (enabled && apps.length > 0) {
            for (const id in last) {
                if (now[id])
                    continue;
                const g = last[id];
                if (!g.pid || !apps.includes(g.app_id) || Apps.own[g.app_id] !== undefined)
                    continue;
                if (Niri.windows.some(w => w.pid === g.pid))
                    continue;
                const p = Object.assign({}, pending);
                p[g.pid] = { appId: g.app_id, at: Date.now() };
                pending = p;
            }
        }
        last = now;
    }

    Timer {
        running: Object.keys(root.pending).length > 0
        interval: 250
        repeat: true
        onTriggered: {
            const grace = Math.max(0, EverydayConfig.quit.graceSeconds) * 1000;
            const p = Object.assign({}, root.pending);
            for (const pid in p) {
                if (Date.now() - p[pid].at < grace)
                    continue;
                const n = Number(pid);
                delete p[pid];
                // A window came back (a dialog closed into the main window, …).
                if (Niri.windows.some(w => w.pid === n))
                    continue;
                root.terminate(n);
            }
            root.pending = p;
        }
    }

    function terminate(pid) {
        if (pid <= 1)
            return;
        Quickshell.execDetached(["sh", "-c", 'c=$(cat /proc/$1/comm 2>/dev/null) || exit 0; case "$c" in Xwayland|xwayland-sat*|quickshell|qs|niri*) exit 0;; esac; kill -TERM "$1"', "loft-quit-on-close", String(pid)]);
    }
}
