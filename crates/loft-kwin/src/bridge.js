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
        screens: workspace.screens.map(s => ({
            name: s.name,
            geometry: rect(s.geometry),
            manufacturer: s.manufacturer || "",
            model: s.model || "",
            serial: s.serialNumber || ""
        })),
        active_screen: workspace.activeScreen ? workspace.activeScreen.name : "",
        active_window: tracked(active) ? "" + active.internalId : "",
        activities: workspace.activities || [],
        current_activity: workspace.currentActivity || ""
    };
}

function push() {
    callDBus(SVC, PATH, IFACE, "Push", JSON.stringify(snapshot()));
}

// The geometry last asked for, per window, until KWin has applied it: a
// resize lands when the client acks it, so frameGeometry is stale meanwhile,
// and Arrange's presets come as several commands in a row (width, height,
// move), each relative to the one before.
const asked = {};

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
workspace.windowRemoved.connect(w => {
    delete asked["" + w.internalId];
    push();
});
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

function frameOf(w) {
    const a = asked["" + w.internalId];
    if (a && Date.now() - a.at < 1000)
        return a.rect;
    const f = w.frameGeometry;
    return { x: f.x, y: f.y, width: f.width, height: f.height };
}

function setGeometry(w, x, y, width, height) {
    if (w.maximizeMode !== 0)
        w.setMaximize(false, false);
    if (w.fullScreen)
        w.fullScreen = false;
    // A plain {x, y, width, height} object (editing the frameGeometry copy
    // does nothing). The move applies at once; a resize when the client
    // acks it, reported through frameGeometryChanged.
    const r = { x: Math.round(x), y: Math.round(y), width: Math.round(width), height: Math.round(height) };
    asked["" + w.internalId] = { rect: r, at: Date.now() };
    w.frameGeometry = r;
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
            const f = frameOf(w);
            setGeometry(w, a.x + (a.width - f.width) / 2, a.y + (a.height - f.height) / 2, f.width, f.height);
        }
        return;
    case "geometryPercent":
        // Any of x, y, width, height in % of the output's working area.
        if (w) {
            const a = area(w);
            const f = frameOf(w);
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
    case "titleBar":
        titleBar(c);
        return;
    case "refresh":
        push();
        return;
    }
    print("loft-bridge: unknown command " + JSON.stringify(c));
}

// ── Title bar (Loft's decoration, through loft-kwin's TitleBar) ──────────
// The decoration doesn't know its window: it's the topmost one under the
// pointer whose frame is the decoration's size (the press went to it).
function windowUnderPointer(width, height) {
    const p = workspace.cursorPos;
    const stack = workspace.stackingOrder;
    let loose = null;
    for (let i = stack.length - 1; i >= 0; --i) {
        const w = stack[i];
        if (!w || w.deleted || w.minimized || !w.frameGeometry)
            continue;
        const f = w.frameGeometry;
        if (p.x < f.x || p.y < f.y || p.x >= f.x + f.width || p.y >= f.y + f.height)
            continue;
        if (Math.abs(f.width - width) <= 1 && Math.abs(f.height - height) <= 1)
            return w;
        if (!loose && tracked(w))
            loose = w;
    }
    return loose;
}

function titleBar(c) {
    const w = windowUnderPointer(c.width, c.height);
    if (!w) {
        print("loft-bridge: no window under the pointer for " + c.action);
        return;
    }
    if (c.action === "fullscreen") {
        w.fullScreen = !w.fullScreen;
        return;
    }
    // The menu's anchor, output-local like niri's WindowActionsMenuRequested.
    const f = w.frameGeometry;
    const gx = f.x + c.x;
    const gy = f.y + c.y;
    const s = workspace.screenAt({ x: gx, y: gy }) || w.output;
    const g = s ? s.geometry : { x: 0, y: 0 };
    callDBus(SVC, PATH, IFACE, "Event", JSON.stringify({
        WindowActionsMenuRequested: {
            window: "" + w.internalId,
            output: s ? s.name : "",
            x: gx - g.x,
            y: gy - g.y,
            kind: c.action
        }
    }));
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
