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
//   - overview: KWin has no signal for an effect starting, so a timer asks
//     `workspace.isEffectActive` (in-process, cheap) and pushes on a change.
// docs/KWIN.md §3, §4.9.

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
            serial: s.serialNumber || "",
            scale: s.scale || 1
        })),
        active_screen: workspace.activeScreen ? workspace.activeScreen.name : "",
        active_window: tracked(active) ? "" + active.internalId : "",
        activities: workspace.activities || [],
        current_activity: workspace.currentActivity || "",
        overview: overviewActive()
    };
}

// KWin's Overview (its Grid View too, the same effect) or Present Windows
// (windowview): what niri's overview is to the shell.
const overviewEffects = ["overview", "windowview"];

function overviewActive() {
    try {
        return overviewEffects.some(e => workspace.isEffectActive(e));
    } catch (e) {
        return false; // a KWin without isEffectActive (< 6.0)
    }
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
    placeExpected(w);
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
// A window held in an interactive move comes along to the Activity switched
// to (any way: KDE's shortcuts, Loft's Spaces), like macOS's Spaces. KWin
// carries it across virtual desktops itself, but not Activities: the move
// goes on with the window hidden on its old Activity and the drop leaves it
// there (measured, KWin 6.8.2; "FIXME" in Workspace::
// updateWindowVisibilityOnDesktopChange). Windows on every Activity ([]) are
// already there. docs/KWIN.md §4.16.
const carried = {};

function carryMovingWindow() {
    const now = workspace.currentActivity;
    if (!now)
        return;
    for (const w of workspace.windowList()) {
        if (!w.move || w.activities.length === 0 || w.activities.indexOf(now) >= 0)
            continue;
        w.activities = [now];
        // The switch focused the new Activity's last window (or none), and
        // focusing during the move doesn't stick: the window in hand gets
        // the focus back when it's dropped, as on macOS.
        const id = "" + w.internalId;
        if (carried[id])
            continue;
        carried[id] = true;
        const dropped = () => {
            w.interactiveMoveResizeFinished.disconnect(dropped);
            delete carried[id];
            workspace.activeWindow = w;
        };
        w.interactiveMoveResizeFinished.connect(dropped);
    }
}
try {
    workspace.currentActivityChanged.connect(carryMovingWindow);
} catch (e) {}
// Settings → Displays re-reads KScreen when a screen moves, resizes or
// rescales (KWin.qml displayLayoutChanged).
function watchScreen(s) {
    for (const sig of ["geometryChanged", "scaleChanged"]) {
        try {
            s[sig].connect(push);
        } catch (e) {}
    }
}
workspace.screens.forEach(watchScreen);
try {
    workspace.screensChanged.connect(() => workspace.screens.forEach(watchScreen));
} catch (e) {}

workspace.desktopsChanged.connect(() => {
    workspace.desktops.forEach(watchDesktop);
    push();
});

let overviewWas = overviewActive();
const overviewTimer = new QTimer();
overviewTimer.interval = 100;
overviewTimer.timeout.connect(() => {
    const now = overviewActive();
    if (now !== overviewWas) {
        overviewWas = now;
        push();
    }
});
overviewTimer.start();

// ── A Space's apps, as they appear (docs/KWIN.md §4.15) ─────────────────
// loft-kwin's openSpace started them and sent one `expectWindow` each: the
// first new window of that pid (else matching the app id / title) goes to
// the Space's Activity and its role's display, then is maximized or made
// fullscreen if the app asks. A rule lapses after `ttl` ms.
let expected = [];

function compile(src, flags) {
    if (!src)
        return null;
    try {
        return new RegExp(src, flags || "");
    } catch (e) {
        print("loft-bridge: bad pattern " + src + ": " + e);
        return null;
    }
}

function expectMatches(r, w) {
    if (r.pid && w.pid === r.pid)
        return true;
    const id = w.desktopFileName || w.resourceClass || "";
    if (!r.appId && !r.title)
        return false;
    return (!r.appId || r.appId.test(id)) && (!r.title || r.title.test(w.caption || ""));
}

function placeExpected(w) {
    if (!tracked(w) || expected.length === 0)
        return;
    const now = Date.now();
    expected = expected.filter(r => r.until > now);
    // A pid match first, so two apps with the same id take their own windows.
    let i = expected.findIndex(r => r.pid && w.pid === r.pid);
    if (i < 0)
        i = expected.findIndex(r => expectMatches(r, w));
    if (i < 0)
        return;
    const r = expected.splice(i, 1)[0];
    if (r.activity && workspace.activities.indexOf(r.activity) >= 0)
        w.activities = [r.activity];
    const s = r.output ? screenByName(r.output) : null;
    if (s && w.output !== s)
        workspace.sendClientToScreen(w, s);
    if (r.open === "maximized")
        w.setMaximize(true, true);
    else if (r.open === "fullscreen")
        w.fullScreen = true;
    if (debug)
        print("loft-bridge: " + r.app + " → " + (r.output || "?") + " on " + r.activity);
}

function expectWindow(c) {
    expected.push({
        app: c.app || "",
        pid: c.pid || 0,
        appId: compile(c.appId, c.appIdFlags),
        title: compile(c.title, ""),
        activity: c.activity || "",
        output: c.output || "",
        open: c.open || "",
        until: Date.now() + (c.ttl || 20000)
    });
    // Its window may be there already (an app quicker than the command).
    const w = workspace.windowList().find(x => tracked(x) && c.pid && x.pid === c.pid);
    if (w) {
        placeExpected(w);
        push();
    }
}

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

// A command without a window acts on the active one (Spotlight's window
// commands, `loft-kwin send '{"cmd":"toggleMaximize"}'`).
function apply(c) {
    const w = c.window ? windowById(c.window) : (tracked(workspace.activeWindow) ? workspace.activeWindow : null);
    switch (c.cmd) {
    case "focusWindow":
        if (!w)
            return;
        if (w.minimized)
            w.minimized = false;
        // A window of another Activity (Space): switch to it first.
        if (w.activities && w.activities.length > 0 && w.activities.indexOf(workspace.currentActivity) < 0)
            workspace.currentActivity = w.activities[0];
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
    case "moveToNextOutput": {
        // The next screen in KWin's order, wrapping (niri's monitor-next).
        const all = workspace.screens;
        if (w && all.length > 1)
            workspace.sendClientToScreen(w, all[(all.indexOf(w.output) + 1) % all.length]);
        return;
    }
    case "moveToDesktopRelative": {
        // niri's move-window-to-workspace-down/up: no wrapping, follows it.
        const all = workspace.desktops;
        const here = w && !w.onAllDesktops && w.desktops.length > 0 ? w.desktops[0] : workspace.currentDesktop;
        const d = all[all.indexOf(here) + (c.delta > 0 ? 1 : -1)];
        if (!w || !d)
            return;
        w.desktops = [d];
        if (c.focus !== false) {
            workspace.currentDesktop = d;
            workspace.activeWindow = w;
        }
        return;
    }
    case "focusOutput": {
        // The topmost window on that screen (on this desktop) takes focus.
        const s = screenByName(c.output);
        const top = s ? workspace.stackingOrder.filter(x => tracked(x) && !x.minimized && x.output === s
            && (x.onAllDesktops || x.desktops.indexOf(workspace.currentDesktop) >= 0)).pop() : null;
        if (top)
            workspace.activeWindow = top;
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
    case "setWindowActivities":
        // Spaces under KWin (docs/KWIN.md §4.2): [] = every Activity.
        if (w) {
            const asked = c.activities || [];
            const known = asked.filter(a => workspace.activities.indexOf(a) >= 0);
            if (asked.length > 0 && known.length === 0)
                return;
            w.activities = known;
            if (c.follow && known.length > 0) {
                workspace.currentActivity = known[0];
                workspace.activeWindow = w;
            }
        }
        return;
    case "expectWindow":
        expectWindow(c);
        return;
    case "titleBar":
        titleBar(c);
        return;
    case "windowMenu":
        // KWin's Window Operations Menu key (Alt+F3, loft-keys.js): Loft's
        // window menu for the active window, under its green bead.
        if (w)
            menuEvent(w, beadAnchor(w), "tileMenu");
        else
            workspace.slotWindowOperations();
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
    menuEvent(w, { x: c.x, y: c.y }, c.action);
}

// Under the green bead of Loft's decoration (kdecoration/tahoe.h: 14 px
// beads 23 px apart, the first 13 px in, centred in a 40 px bar), where a
// held green opens the menu; a window without a title bar: near its corner.
function beadAnchor(w) {
    return w.noBorder ? { x: 16, y: 16 } : { x: 13 + 2 * 23, y: 27 };
}

// Ask the shell for Loft's window menu at a frame-local point.
function menuEvent(w, at, kind) {
    // The menu's anchor, output-local like niri's WindowActionsMenuRequested.
    const f = w.frameGeometry;
    const gx = f.x + at.x;
    const gy = f.y + at.y;
    const s = workspace.screenAt({ x: gx, y: gy }) || w.output;
    const g = s ? s.geometry : { x: 0, y: 0 };
    callDBus(SVC, PATH, IFACE, "Event", JSON.stringify({
        WindowActionsMenuRequested: {
            window: "" + w.internalId,
            output: s ? s.name : "",
            x: gx - g.x,
            y: gy - g.y,
            kind: kind
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
