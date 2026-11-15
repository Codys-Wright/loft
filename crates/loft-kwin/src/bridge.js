// loft-bridge: the KWin side of Loft's KWin backend (crates/loft-kwin).
//
// Loaded by `loft-kwin` through org.kde.KWin /Scripting. A KWin script can
// only talk outward, over D-Bus (callDBus), so:
//   - state: on every change, the whole snapshot goes to
//     dev.loft.KWinBridge.Push(json) (loft-kwin turns it into the niri-shaped
//     records the shell uses);
//   - actions: the script long-polls dev.loft.KWinBridge.NextCommands(),
//     which loft-kwin answers when the shell sent something (or empty after
//     a while), applies them, and polls again.
// docs/KWIN.md §3.

const SVC = "dev.loft.KWinBridge";
const PATH = "/Bridge";
const IFACE = "dev.loft.KWinBridge";
const debug = false;

function rect(r) {
    return r ? [r.x, r.y, r.width, r.height] : [0, 0, 0, 0];
}

// The windows a dock and a switcher should know about.
function tracked(w) {
    return !!w && (w.normalWindow || w.dialog) && !w.skipTaskbar;
}

function windowRecord(w) {
    return {
        uuid: "" + w.internalId,
        title: w.caption || "",
        app_id: w.desktopFileName || w.resourceClass || "",
        pid: w.pid || 0,
        desktops: w.onAllDesktops ? [] : (w.desktops || []).map(d => d.id),
        output: w.output ? w.output.name : "",
        geometry: rect(w.frameGeometry),
        minimized: !!w.minimized,
        fullscreen: !!w.fullScreen,
        maximized: w.maximizeMode === 3,
        keep_above: !!w.keepAbove,
        urgent: !!w.demandsAttention,
        activities: w.activities || []
    };
}

function snapshot() {
    const active = workspace.activeWindow;
    return {
        windows: workspace.windowList().filter(tracked).map(windowRecord),
        desktops: workspace.desktops.map(d => ({ id: d.id, name: d.name })),
        current_desktop: workspace.currentDesktop ? workspace.currentDesktop.id : "",
        screens: workspace.screens.map(s => ({ name: s.name, geometry: rect(s.geometry) })),
        active_screen: workspace.activeScreen ? workspace.activeScreen.name : "",
        active_window: tracked(active) ? "" + active.internalId : "",
        activities: workspace.activities || [],
        current_activity: workspace.currentActivity || ""
    };
}

function push() {
    callDBus(SVC, PATH, IFACE, "Push", JSON.stringify(snapshot()));
}

// ── Change tracking ──────────────────────────────────────────────────────
// Geometry only when a move/resize ends (not every frame of a drag).
const windowSignals = ["captionChanged", "desktopsChanged", "outputChanged", "minimizedChanged",
    "fullScreenChanged", "maximizedChanged", "demandsAttentionChanged", "keepAboveChanged",
    "activitiesChanged", "skipTaskbarChanged", "interactiveMoveResizeFinished"];

function watchWindow(w) {
    // Programmatic moves and resizes (ours, KWin's placement) count; a drag
    // only when it ends (interactiveMoveResizeFinished above).
    try {
        w.frameGeometryChanged.connect(() => {
            if (!w.move && !w.resize)
                push();
        });
    } catch (e) {}
    for (const s of windowSignals) {
        try {
            if (w[s])
                w[s].connect(push);
        } catch (e) {
            // A signal this KWin doesn't have: skip it.
        }
    }
}

function watchDesktop(d) {
    try {
        d.nameChanged.connect(push);
    } catch (e) {}
}

workspace.windowList().forEach(watchWindow);
workspace.desktops.forEach(watchDesktop);

workspace.windowAdded.connect(w => {
    watchWindow(w);
    push();
});
workspace.windowRemoved.connect(push);
workspace.windowActivated.connect(push);
for (const s of ["currentDesktopChanged", "screensChanged", "currentActivityChanged", "activitiesChanged"]) {
    try {
        workspace[s].connect(push);
    } catch (e) {}
}
workspace.desktopsChanged.connect(() => {
    workspace.desktops.forEach(watchDesktop);
    push();
});

// ── Actions ──────────────────────────────────────────────────────────────
function windowById(uuid) {
    return workspace.windowList().find(w => ("" + w.internalId) === uuid) || null;
}

function desktopById(id) {
    return workspace.desktops.find(d => d.id === id) || null;
}

function screenByName(name) {
    return workspace.screens.find(s => s.name === name) || null;
}

function area(w) {
    return workspace.clientArea(KWin.MaximizeArea, w.output, workspace.currentDesktop);
}

function setGeometry(w, x, y, width, height) {
    if (w.maximizeMode !== 0)
        w.setMaximize(false, false);
    if (w.fullScreen)
        w.fullScreen = false;
    // A plain {x, y, width, height} object (editing the frameGeometry copy
    // does nothing). The move applies at once; a resize when the client
    // acks it, reported through frameGeometryChanged.
    w.frameGeometry = { x: Math.round(x), y: Math.round(y), width: Math.round(width), height: Math.round(height) };
    if (debug)
        print("loft-bridge: geometry " + JSON.stringify(rect(w.frameGeometry)) + " asked " + JSON.stringify([x, y, width, height]));
}

function apply(c) {
    const w = c.window ? windowById(c.window) : null;
    switch (c.cmd) {
    case "focusWindow":
        if (!w)
            return;
        if (w.minimized)
            w.minimized = false;
        if (!w.onAllDesktops && w.desktops.length > 0 && w.desktops.indexOf(workspace.currentDesktop) < 0)
            workspace.currentDesktop = w.desktops[0];
        workspace.activeWindow = w;
        return;
    case "closeWindow":
        if (w)
            w.closeWindow();
        return;
    case "focusDesktop": {
        const d = desktopById(c.desktop);
        if (d)
            workspace.currentDesktop = d;
        return;
    }
    case "focusDesktopRelative": {
        const all = workspace.desktops;
        const i = all.indexOf(workspace.currentDesktop) + (c.delta > 0 ? 1 : -1);
        if (i >= 0 && i < all.length)
            workspace.currentDesktop = all[i];
        return;
    }
    case "moveToDesktop": {
        const d = desktopById(c.desktop);
        if (!w || !d)
            return;
        w.desktops = [d];
        if (c.focus) {
            workspace.currentDesktop = d;
            workspace.activeWindow = w;
        }
        return;
    }
    case "moveToOutput": {
        const s = screenByName(c.output);
        if (w && s)
            workspace.sendClientToScreen(w, s);
        return;
    }
    case "setMinimized":
        if (w)
            w.minimized = !!c.value;
        return;
    case "toggleFullscreen":
        if (w)
            w.fullScreen = !w.fullScreen;
        return;
    case "toggleMaximize":
        if (w) {
            const on = w.maximizeMode === 3;
            w.setMaximize(!on, !on);
        }
        return;
    case "toggleKeepAbove":
        if (w)
            w.keepAbove = !w.keepAbove;
        return;
    case "center":
        if (w) {
            const a = area(w);
            const f = w.frameGeometry;
            setGeometry(w, a.x + (a.width - f.width) / 2, a.y + (a.height - f.height) / 2, f.width, f.height);
        }
        return;
    case "geometryPercent":
        // Any of x, y, width, height in % of the output's working area.
        if (w) {
            const a = area(w);
            const f = w.frameGeometry;
            const width = c.width !== undefined && c.width !== null ? a.width * c.width / 100 : f.width;
            const height = c.height !== undefined && c.height !== null ? a.height * c.height / 100 : f.height;
            const x = c.x !== undefined && c.x !== null ? a.x + a.width * c.x / 100 : f.x;
            const y = c.y !== undefined && c.y !== null ? a.y + a.height * c.y / 100 : f.y;
            setGeometry(w, x, y, width, height);
        }
        return;
    case "setActivity":
        if (workspace.activities.indexOf(c.activity) >= 0)
            workspace.currentActivity = c.activity;
        return;
    case "refresh":
        push();
        return;
    }
    print("loft-bridge: unknown command " + JSON.stringify(c));
}

function poll() {
    callDBus(SVC, PATH, IFACE, "NextCommands", reply => {
        try {
            JSON.parse(reply).forEach(apply);
        } catch (e) {
            print("loft-bridge: " + e);
        }
        poll();
    });
}

push();
poll();
