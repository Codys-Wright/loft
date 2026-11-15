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
    // KWin's Overview effect has no state to read; the toggle still works.
    readonly property bool overviewOpen: false
    property var keyboardLayouts: ({ names: [], current_idx: 0 })
    property var activities: []
    property string currentActivity: ""
    // [{ name, geometry, identity ("Make Model Serial", niri's), model }]
    property var displays: []

    // What KWin offers, for Compositor.capabilities (menus hide the rest).
    readonly property var capabilities: ({
            columns: false,
            floating: false,
            minimize: true,
            overview: true,
            windowScreenshot: false,
            workspaceNames: true,
            perOutputWorkspaces: false,
            titleBarEvents: false,
            configReload: false
        })

    signal outputsChanged
    property string outputKey: ""

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
            available = true;
            const key = (s.outputs ?? []).map(o => o.name).sort().join(",");
            if (key !== outputKey) {
                outputKey = key;
                outputsChanged();
            }
        } else if (msg.KeyboardLayouts) {
            keyboardLayouts = msg.KeyboardLayouts;
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

    function screenshotWindow(id, path, showPointer) {
        console.warn("KWin: window screenshots aren't supported yet");
    }

    function setActivity(activity) {
        send({ cmd: "setActivity", activity: activity });
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
        command: [Quickshell.env("LOFT_KWIN_BIN") || "loft-kwin"]
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => root.handle(line)
        }
        stderr: SplitParser {
            onRead: line => console.warn(`loft-kwin: ${line}`)
        }
        onRunningChanged: {
            if (running)
                return;
            root.available = false;
            // Crashed, or KWin wasn't ready yet: come back.
            if (root.wanted)
                restart.start();
        }
    }

    Timer {
        id: restart
        interval: 2000
        onTriggered: if (root.wanted && !proc.running)
            proc.running = true
    }
}
