pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Live KWin state + actions: the KWin backend of services/Compositor.qml
// (docs/KWIN.md §3). `loft-kwin` (crates/loft-kwin) loads the loft-bridge
// KWin script and relays its snapshots as niri-shaped records, so this file
// has the same surface as Niri.qml. Only runs in a KWin session.
Singleton {
    id: root

    readonly property bool wanted: Compositor.session === "kwin"
    // A state arrived from the bridge (and it's still running).
    property bool available: false

    property var workspaceMap: ({})
    property var windowMap: ({})

    readonly property var workspaces: Object.values(workspaceMap).sort((a, b) => (a.output ?? "").localeCompare(b.output ?? "") || a.idx - b.idx)
    readonly property var windows: Object.values(windowMap).sort((a, b) => a.id - b.id)
    readonly property var focusedWindow: windows.find(w => w.is_focused) ?? null
    readonly property var focusedWorkspace: workspaces.find(w => w.is_focused) ?? null
    // KWin's Overview / Grid View / Present Windows effect is running
    // (loft-bridge asks KWin, docs/KWIN.md §4.9): wallpapers and the bar
    // react as they do to niri's overview.
    property bool overviewOpen: false
    property var keyboardLayouts: ({ names: [], current_idx: 0 })
    property var activities: []
    property string currentActivity: ""
    // Spaces are the user's KDE Activities (docs/KWIN.md §4.2):
    // kactivitymanagerd's [{ id, name, icon, key, position }] in the order of
    // their "Switch to activity" keys (Meta+1…9, 0), else KDE's own order;
    // loft-kwin sends it again on every change. editActivity changes them
    // in KDE (crates/loft-kwin/src/manage.rs).
    property var activityList: []
    property bool activitiesLoaded: false
    property string activitiesError: ""
    // [{ name, geometry, identity ("Make Model Serial", niri's), model }]
    property var displays: []

    // What KWin offers, for Compositor.capabilities (menus hide the rest).
    readonly property var capabilities: ({
            columns: false,
            floating: false,
            minimize: true,
            overview: true,
            // loft-kwin shot (KWin's ScreenShot2).
            windowScreenshot: true,
            // Window stills for the dock preview and the switcher, through
            // the same ScreenShot2 (KWinThumbs, docs/KWIN.md §4.8).
            windowThumbnails: true,
            // loft-kwin record window (KWin's zkde_screencast stream_window).
            windowRecording: true,
            workspaceNames: true,
            perOutputWorkspaces: false,
            // Loft's decoration: right-click / held green → the window
            // menu (windowActionsMenuRequested). Minimize is KWin's own.
            titleBarEvents: true,
            configReload: false,
            // KWin puts its title bar (Loft's decoration) on the shell's own
            // windows too: WindowChrome leaves out its traffic lights.
            serverDecorations: true,
            // Spaces are KDE Activities, one per Space (Spaces.qml).
            spaces: true,
            // Loft's shortcuts report press, repeat and release
            // (shortcutKey; docs/KWIN.md §4.13): the quit guard's hold.
            shortcutKeys: true
        })

    signal outputsChanged
    // A screen moved, was resized or rescaled (KScreen re-reads its outputs).
    signal displayLayoutChanged
    // Loft's decoration asked for the window menu (right-click on the bar,
    // or green held): x, y logical within the output, as niri's event.
    signal windowActionsMenuRequested(int id, string output, real x, real y)
    // A window screenshot of ours finished (screenshotWindow), path written.
    signal screenshotTaken(string path)
    // One of Loft's global shortcuts (kglobalaccel `loft-<id>`) was pressed,
    // repeated (held) or released: id without `loft-` and a `-N` twin suffix
    // ("quit", "quit-2"), state "pressed" | "repeated" | "released".
    signal shortcutKey(string id, string state)
    // id → Date.now() of its last press, and whether it is still held.
    property var shortcutPressedAt: ({})
    property var shortcutDown: ({})
    // openSpace's report: { space, activity, apps: [{ app, display, window,
    // spawn }], notes }.
    signal spaceOpened(var report)
    // closeSpace's report: { space, activity, dryRun, windows: [{ app,
    // window, app_id, title }], notes }.
    signal spaceClosed(var report)
    // editActivity's answer: { op, ok, id, name, error, notes }.
    signal activityEdited(var report)
    // After a rename: Loft settings and window rules that named the old
    // name, relinked ({ id, old, name, docs, rules, notes }).
    signal activityLinksFixed(var report)
    property string outputKey: ""
    property string layoutKey: ""

    // loft-kwin: the daemon below, and `loft-kwin shot …` for screenshots.
    readonly property string bin: Quickshell.env("LOFT_KWIN_BIN") || "loft-kwin"

    // argv for a screenshot of one output by name ("" = every output), at
    // its native resolution, into `path` (PNG). Capture.qml's grim, here.
    function screenshotArgv(output, path, showPointer) {
        const a = output ? [bin, "shot", "screen", output, path] : [bin, "shot", "workspace", path];
        return showPointer ? a.concat(["--pointer"]) : a;
    }

    function workspacesOn(output) {
        return workspaces.filter(w => w.output === output);
    }

    function windowsOn(workspaceId) {
        return windows.filter(w => w.workspace_id === workspaceId);
    }

    // ── Talking to loft-kwin ──────────────────────────────────────────────
    function send(cmd) {
        if (proc.running)
            proc.write(JSON.stringify(cmd) + "\n");
    }

    function uuid(id) {
        return windowMap[id]?.kwin_uuid ?? "";
    }

    function desktopOf(workspaceId) {
        return workspaceMap[workspaceId]?.kwin_desktop ?? "";
    }

    function windowCmd(cmd, id, extra) {
        const u = uuid(id);
        if (u !== "")
            send(Object.assign({ cmd: cmd, window: u }, extra ?? {}));
    }

    function handle(line) {
        let msg;
        try {
            msg = JSON.parse(line);
        } catch (e) {
            console.warn(`KWin: bad line from loft-kwin: ${e}`);
            return;
        }
        if (msg.State) {
            const s = msg.State;
            const ws = {};
            for (const w of s.workspaces ?? [])
                ws[w.id] = w;
            const wins = {};
            for (const w of s.windows ?? [])
                wins[w.id] = w;
            workspaceMap = ws;
            windowMap = wins;
            activities = s.activities ?? [];
            displays = s.outputs ?? [];
            currentActivity = s.current_activity ?? "";
            overviewOpen = s.overview_open === true;
            available = true;
            const key = (s.outputs ?? []).map(o => o.name).sort().join(",");
            if (key !== outputKey) {
                outputKey = key;
                outputsChanged();
            }
            const layout = (s.outputs ?? []).map(o => `${o.name}:${o.geometry}:${o.scale ?? 1}`).sort().join(",");
            if (layout !== layoutKey) {
                layoutKey = layout;
                displayLayoutChanged();
            }
        } else if (msg.Activities) {
            activityList = msg.Activities.activities ?? [];
            activitiesError = msg.Activities.error ?? "";
            if (activitiesError)
                console.warn(`KWin: activities: ${activitiesError}`);
            if (msg.Activities.current)
                currentActivity = msg.Activities.current;
            activitiesLoaded = true;
        } else if (msg.ActivityEdit) {
            if (!msg.ActivityEdit.ok)
                console.warn(`KWin: activity ${msg.ActivityEdit.op}: ${msg.ActivityEdit.error}`);
            activityEdited(msg.ActivityEdit);
        } else if (msg.ActivityLinks) {
            activityLinksFixed(msg.ActivityLinks);
        } else if (msg.SpaceOpened) {
            spaceOpened(msg.SpaceOpened);
        } else if (msg.SpaceClosed) {
            spaceClosed(msg.SpaceClosed);
        } else if (msg.WindowActionsMenuRequested) {
            const e = msg.WindowActionsMenuRequested;
            const w = windows.find(x => x.kwin_uuid === e.window);
            if (w)
                windowActionsMenuRequested(w.id, e.output ?? "", e.x, e.y);
        } else if (msg.KeepAwake) {
            keepAwake = msg.KeepAwake;
            if (msg.KeepAwake.error)
                console.warn(`KWin: keep awake: ${msg.KeepAwake.error}`);
        } else if (msg.KeyboardLayouts) {
            keyboardLayouts = msg.KeyboardLayouts;
        } else if (msg.Shortcut) {
            const id = String(msg.Shortcut.name ?? "").replace(/^loft-/, "").replace(/-\d+$/, "");
            const st = msg.Shortcut.state;
            if (st === "pressed")
                shortcutPressedAt[id] = Date.now();
            if (st === "pressed" || st === "released")
                shortcutDown[id] = st === "pressed";
            shortcutKey(id, st);
        } else if (msg.Error) {
            console.warn(`KWin: ${msg.Error}`);
        }
    }

    // ── Actions (Compositor's names) ──────────────────────────────────────
    function spawn(command) {
        Quickshell.execDetached(command);
    }

    function focusWindow(id) {
        windowCmd("focusWindow", id);
    }

    function focusWorkspace(id) {
        const d = desktopOf(id);
        if (d !== "")
            send({ cmd: "focusDesktop", desktop: d });
    }

    function focusWorkspaceRelative(delta) {
        send({ cmd: "focusDesktopRelative", delta: delta });
    }

    function closeWindow(id) {
        windowCmd("closeWindow", id);
    }

    function moveWindowToWorkspace(windowId, workspaceId, focus) {
        const ws = workspaceMap[workspaceId];
        const w = windowMap[windowId];
        if (!ws || !w)
            return;
        // A workspace is a desktop on one output: the output may change too.
        if (ws.output && ws.output !== workspaceMap[w.workspace_id]?.output)
            windowCmd("moveToOutput", windowId, { output: ws.output });
        windowCmd("moveToDesktop", windowId, { desktop: ws.kwin_desktop, focus: focus === true });
    }

    function moveWindowToWorkspaceIndex(windowId, index, focus) {
        const w = windowMap[windowId];
        const output = workspaceMap[w?.workspace_id]?.output ?? focusedWorkspace?.output;
        const ws = workspacesOn(output).find(x => x.idx === index);
        if (ws)
            moveWindowToWorkspace(windowId, ws.id, focus);
    }

    function moveFocusedWindowToWorkspaceRelative(delta, focus) {
        const w = focusedWindow;
        const here = workspaceMap[w?.workspace_id];
        if (!w || !here)
            return;
        const ws = workspacesOn(here.output).find(x => x.idx === here.idx + (delta > 0 ? 1 : -1));
        if (ws)
            moveWindowToWorkspace(w.id, ws.id, focus);
    }

    function moveWindowToOutput(id, output) {
        windowCmd("moveToOutput", id, { output: output });
    }

    function moveFocusedWindowToNextOutput() {
        const w = focusedWindow;
        if (!w)
            return;
        const outputs = [...new Set(workspaces.map(x => x.output))].sort();
        const here = workspaceMap[w.workspace_id]?.output;
        if (outputs.length > 1)
            moveWindowToOutput(w.id, outputs[(outputs.indexOf(here) + 1) % outputs.length]);
    }

    // KWin windows all float; there's no tiling to toggle (capabilities.floating).
    function toggleFloating(id) {
    }

    function setFloating(id, floating) {
    }

    function setMinimized(id, minimized) {
        windowCmd("setMinimized", id, { value: minimized });
    }

    function toggleFullscreen(id) {
        windowCmd("toggleFullscreen", id);
    }

    function maximizeToEdges(id) {
        windowCmd("toggleMaximize", id);
    }

    function centerWindow(id) {
        windowCmd("center", id);
    }

    function setWindowWidthPercent(id, percent) {
        windowCmd("geometryPercent", id, { width: percent });
    }

    function setWindowHeightPercent(id, percent) {
        windowCmd("geometryPercent", id, { height: percent });
    }

    function resetWindowHeight(id) {
    }

    function moveFloatingWindowPercent(id, x, y) {
        windowCmd("geometryPercent", id, { x: x, y: y });
    }

    function setWorkspaceName(workspaceId, name) {
        const d = desktopOf(workspaceId);
        if (d !== "")
            send({ cmd: "setDesktopName", desktop: d, name: name });
    }

    function unsetWorkspaceName(workspaceId) {
        const ws = workspaceMap[workspaceId];
        if (ws)
            send({ cmd: "setDesktopName", desktop: ws.kwin_desktop, name: `Desktop ${ws.idx}` });
    }

    function switchKeyboardLayout(index) {
        send({ cmd: "switchLayout", index: index });
    }

    function toggleOverview() {
        send({ cmd: "toggleOverview" });
    }

    // Like niri's screenshot-window: writes `path`, copies it, then
    // screenshotTaken(path).
    function screenshotWindow(id, path, showPointer) {
        const w = windowMap[id];
        if (!w?.kwin_uuid || shot.running)
            return;
        shot.path = path;
        shot.command = ["sh", "-c", '"$@" && wl-copy --type image/png < "$5"', "sh", bin, "shot", "window", w.kwin_uuid, path].concat(showPointer ? ["--pointer"] : []);
        shot.running = true;
    }

    // Keep Awake (KeepAwake.qml): loft-kwin holds a PowerDevil inhibition
    // while `why` isn't "" (sent again when loft-kwin restarts).
    property string keepAwakeWhy: ""
    // loft-kwin's answer: { held, cookie?, error? }
    property var keepAwake: ({ held: false })
    function setKeepAwake(why) {
        keepAwakeWhy = why;
        send({ cmd: "keepAwake", why: why });
    }

    function setActivity(activity) {
        send({ cmd: "setActivity", activity: activity });
    }

    // Create, rename, re-icon, reorder or remove a KDE Activity:
    // { op: "create", name, icon } | { op: "rename", activity, name } |
    // { op: "icon", activity, icon } | { op: "reorder", order: [ids] } |
    // { op: "remove", activity }. Answered with activityEdited.
    function editActivity(edit) {
        send(Object.assign({ cmd: "activity" }, edit));
    }

    // Ask for the Activities again (answered with an Activities line).
    function refreshActivities() {
        send({ cmd: "activities" });
    }

    // A space's apps (`loft-niri space specs`) into its Activity: loft-kwin
    // finds the open ones, moves them to their displays, starts the rest
    // (crates/loft-kwin/src/spinup.rs). focus: switch to the Activity first.
    function openSpace(space, activity, apps, notes, focus) {
        send({ cmd: "openSpace", space: space, activity: activity, apps: apps, notes: notes ?? [], focus: focus === true });
    }

    // Close the windows of a space's Activity that are its apps (the same
    // matching as openSpace); dryRun: only report which.
    function closeSpace(space, activity, apps, dryRun) {
        send({ cmd: "closeSpace", space: space, activity: activity, apps: apps, dryRun: dryRun === true });
    }

    // Put a window on these activities ([] = all); follow: switch there too.
    function setWindowActivities(id, activities, follow) {
        windowCmd("setWindowActivities", id, { activities: activities, follow: follow === true });
    }

    // Scrolling-layout columns: niri only (capabilities.columns).
    function maximizeColumn(id) {
        if (id !== undefined && id !== null)
            maximizeToEdges(id);
    }

    function setColumnWidthPercent(id, percent) {
    }

    function expandColumn(id) {
    }

    function centerVisibleColumns(id) {
    }

    function expelWindowFromColumn(id) {
    }

    function consumeOrExpelWindowLeft(id) {
    }

    Component.onCompleted: if (wanted)
        proc.running = true

    Process {
        id: proc
        command: [root.bin]
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => root.handle(line)
        }
        stderr: SplitParser {
            onRead: line => console.warn(`loft-kwin: ${line}`)
        }
        onRunningChanged: {
            if (running) {
                if (root.keepAwakeWhy !== "")
                    root.send({ cmd: "keepAwake", why: root.keepAwakeWhy });
                return;
            }
            root.keepAwake = { held: false };
            root.available = false;
            root.overviewOpen = false;
            // Crashed, or KWin wasn't ready yet: come back.
            if (root.wanted)
                restart.start();
        }
    }

    Process {
        id: shot
        property string path: ""
        stderr: SplitParser {
            onRead: line => console.warn(`loft-kwin shot: ${line}`)
        }
        onExited: code => {
            if (code === 0)
                root.screenshotTaken(shot.path);
        }
    }

    Timer {
        id: restart
        interval: 2000
        onTriggered: if (root.wanted && !proc.running)
            proc.running = true
    }
}
