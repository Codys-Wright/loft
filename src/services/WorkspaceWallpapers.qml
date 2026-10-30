pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "wswallpapers.js" as Plan

// Per-workspace wallpaper surfaces: which ones exist, at what decode size.
//
// A patched niri (nix/niri/workspace-layers.patch, package niri-loft) can
// bind a background layer surface to one workspace with the layer rule
// `place-within-workspace` (niri/workspace-wallpapers.kdl binds
// `loft:wallpaper@<ref>` to workspace <ref>). It then draws that surface
// behind its own workspace only: it slides with the workspace during a
// switch and sits behind it in the overview. niri never draws a bound
// surface whose workspace is off screen; this service makes sure only the
// ones that can come on screen exist at all:
//
//   - the active workspace and one neighbor each way, at full size (a
//     switch or a swipe slides a neighbor in; niri announces the switch only
//     as it starts, so neighbors are kept warm rather than loaded on demand);
//   - while the overview is open, every workspace its zoom puts on screen
//     plus one more each way, the extra ones decoded at the overview's zoom;
//   - a surface no longer wanted stays `graceMs` (a quick switch back finds
//     it), then it is destroyed: unmapped, its buffers and image freed.
//
// <ref> is the workspace's name, or its 1-based index on its output for
// unnamed ones (the same keys Vibes.wallpaperAt / wallsets.js use).
//
// `supported` needs both halves: the session included the layer rule
// (LOFT_NIRI_WORKSPACE_LAYERS=1, set by loft-session / loft-dev /
// programs.loft for a niri that has the patch) and the running compositor
// reports the feature in its version string (`niri msg version`). Otherwise
// Wallpaper.qml keeps swapping one surface per screen on activation.
// Settings → Wallpaper → "Wallpapers move with workspaces" turns it off, and
// so does a performance mode (PerformanceMode: one surface per screen).
Singleton {
    id: root

    readonly property bool configured: (Quickshell.env("LOFT_NIRI_WORKSPACE_LAYERS") ?? "") === "1"
    property bool compositorHasIt: false
    property string compositorVersion: ""
    readonly property bool supported: configured && compositorHasIt
    readonly property bool active: supported && Settings.wallpaper.moveWithWorkspaces && !PerformanceMode.on && Niri.available && Vibes.fakeLayout === null
    // Tests / measurements: every workspace gets a surface (the naive way).
    readonly property bool all: (Quickshell.env("LOFT_WS_WALLPAPERS_ALL") ?? "") === "1"

    // niri's `overview { zoom }` (default 0.5); LOFT_NIRI_OVERVIEW_ZOOM overrides.
    readonly property real overviewZoom: {
        const z = parseFloat(Quickshell.env("LOFT_NIRI_OVERVIEW_ZOOM") ?? "");
        return z > 0 && z <= 1 ? z : 0.5;
    }
    // Workspaces the overview shows on each side of the active one (wswallpapers.js).
    readonly property int overviewRadius: Plan.overviewRadius(overviewZoom)
    readonly property int graceMs: 1500

    // key "<screen>|<ref>" → { screen, ref, scale, until } (until: 0 = wanted,
    // else the time it goes).
    property var live: ({})
    // Keys whose image is up (WorkspaceWallpaper reports it), and the
    // screens whose active workspace has been covered once.
    property var ready: ({})
    property var covered: ({})

    readonly property var keys: Object.keys(live).sort()

    function refOf(ws) {
        return Plan.refOf(ws);
    }

    function update() {
        const want = active ? Plan.plan(Niri.workspaces, Quickshell.screens.map(s => s.name), {
            overview: Niri.overviewOpen,
            zoom: overviewZoom,
            all: all,
            live: live
        }) : {};
        const r = Plan.step(live, want, Date.now(), graceMs);
        if (r.changed)
            live = r.live;
        prune.running = r.pending;
        const ready2 = {};
        for (const k in ready)
            if (live[k])
                ready2[k] = true;
        if (Object.keys(ready2).length !== Object.keys(ready).length)
            ready = ready2;
        if (!active && Object.keys(covered).length > 0)
            covered = {};
    }

    function entry(key) {
        return live[key] ?? null;
    }

    function setReady(key, on) {
        if (!!ready[key] === on)
            return;
        const r = Object.assign({}, ready);
        if (on)
            r[key] = true;
        else
            delete r[key];
        ready = r;
        const e = live[key];
        if (on && e && !covered[e.screen]) {
            const ws = Niri.workspaces.find(w => w.output === e.screen && w.is_active);
            if (ws && refOf(ws) === e.ref) {
                const c = Object.assign({}, covered);
                c[e.screen] = true;
                covered = c;
            }
        }
    }

    // The screen's per-workspace surfaces have taken over (Wallpaper.qml
    // then unmaps the per-screen one).
    function isCovered(screen) {
        return !!covered[screen];
    }

    // The workspace a surface is for (null once it is gone).
    function workspaceFor(screen, ref) {
        return Niri.workspaces.find(w => w.output === screen && refOf(w) === ref) ?? null;
    }

    onActiveChanged: update()
    Component.onCompleted: update()
    Connections {
        target: Niri
        function onWorkspaceMapChanged() {
            root.update();
        }
        function onOverviewOpenChanged() {
            root.update();
        }
    }
    Connections {
        target: Quickshell
        function onScreensChanged() {
            root.update();
        }
    }

    Timer {
        id: prune
        interval: 250
        repeat: true
        onTriggered: root.update()
    }

    // `niri msg version` asks the running compositor (not the niri on PATH).
    Process {
        id: probe
        running: root.configured
        command: ["niri", "msg", "version"]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = text.match(/Compositor version: (.*)/);
                root.compositorVersion = m ? m[1].trim() : "";
                root.compositorHasIt = root.compositorVersion.includes("workspace-layers");
            }
        }
    }

    // Measurements: surfaces and decoded image bytes, now.
    property var stats: ({})
    function report(key, bytes) {
        const s = Object.assign({}, stats);
        if (bytes === null)
            delete s[key];
        else
            s[key] = bytes;
        stats = s;
    }

    IpcHandler {
        target: "wswallpapers"

        // {supported, active, compositor, surfaces, perScreen, decodedMB, keys}
        function stats(): string {
            const per = {};
            let bytes = 0;
            let baseBytes = 0;
            for (const k of root.keys) {
                const screen = k.split("|")[0];
                per[screen] = (per[screen] ?? 0) + 1;
                bytes += root.stats[k] ?? 0;
            }
            for (const [k, b] of Object.entries(root.stats))
                if (k.startsWith("base|"))
                    baseBytes += b;
            return JSON.stringify({
                supported: root.supported,
                active: root.active,
                compositor: root.compositorVersion,
                overview: Niri.overviewOpen,
                surfaces: root.keys.length,
                perScreen: per,
                decodedMB: Math.round(bytes / 1048576 * 10) / 10,
                baseDecodedMB: Math.round(baseBytes / 1048576 * 10) / 10,
                keys: root.keys.map(k => `${k}@${root.live[k].scale}${root.live[k].until ? "~" : ""}`)
            });
        }
    }
}
