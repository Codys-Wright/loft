pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Live niri state + actions over niri's IPC socket ($NIRI_SOCKET).
//
// One socket subscribes to the event stream (newline-delimited JSON, niri-ipc
// `Event`); a second one sends `Action` requests. This replaces the Hyprland
// module the upstream shell used. Wire format: niri-ipc/src/lib.rs (26.04).
Singleton {
    id: root

    readonly property string socketPath: Quickshell.env("NIRI_SOCKET") ?? ""
    readonly property bool available: socketPath !== ""

    // id → workspace / window, as niri reports them.
    property var workspaceMap: ({})
    property var windowMap: ({})

    // Derived, sorted views for the UI.
    readonly property var workspaces: Object.values(workspaceMap).sort((a, b) => (a.output ?? "").localeCompare(b.output ?? "") || a.idx - b.idx)
    readonly property var windows: Object.values(windowMap).sort((a, b) => a.id - b.id)
    readonly property var focusedWindow: windows.find(w => w.is_focused) ?? null
    readonly property var focusedWorkspace: workspaces.find(w => w.is_focused) ?? null
    property bool overviewOpen: false
    // { names: [...], current_idx } (KeyboardLayoutsChanged / …Switched).
    property var keyboardLayouts: ({ names: [], current_idx: 0 })

    // A screenshot was taken (niri's screenshot UI or actions); path may be "".
    signal screenshotTaken(string path)
    // niri (re)loaded its config files; failed = it kept the previous config.
    signal configLoaded(bool failed)
    // The set of outputs carrying workspaces changed (hotplug, enable/disable).
    // niri 26.04 has no output events, so this is the closest live signal.
    signal outputsChanged
    property string outputKey: ""

    function workspacesOn(output) {
        return workspaces.filter(w => w.output === output);
    }

    function windowsOn(workspaceId) {
        return windows.filter(w => w.workspace_id === workspaceId);
    }

    // ── Actions ───────────────────────────────────────────────────────────
    function action(name, args) {
        const a = {};
        a[name] = args ?? {};
        actions.send({ Action: a });
    }

    function focusWorkspace(id) {
        action("FocusWorkspace", { reference: { Id: id } });
    }

    function focusWindow(id) {
        action("FocusWindow", { id: id });
    }

    function spawn(command) {
        action("Spawn", { command: command });
    }

    function toggleOverview() {
        action("ToggleOverview");
    }

    // ── Event handling ────────────────────────────────────────────────────
    function handle(event) {
        const [kind, e] = Object.entries(event)[0];
        switch (kind) {
        case "WorkspacesChanged": {
            const m = {};
            for (const w of e.workspaces)
                m[w.id] = w;
            workspaceMap = m;
            const key = [...new Set(e.workspaces.map(w => w.output ?? ""))].sort().join(",");
            if (key !== outputKey) {
                outputKey = key;
                outputsChanged();
            }
            break;
        }
        case "WorkspaceActivated": {
            const ws = workspaceMap[e.id];
            if (!ws)
                break;
            const m = Object.assign({}, workspaceMap);
            for (const id in m) {
                const w = m[id];
                // Activation is per output; focus is global.
                if (w.output === ws.output)
                    m[id] = Object.assign({}, w, { is_active: w.id === e.id });
                if (e.focused)
                    m[id] = Object.assign({}, m[id], { is_focused: w.id === e.id });
            }
            workspaceMap = m;
            break;
        }
        case "WorkspaceActiveWindowChanged":
            patchWorkspace(e.workspace_id, { active_window_id: e.active_window_id });
            break;
        case "WorkspaceUrgencyChanged":
            patchWorkspace(e.id, { is_urgent: e.urgent });
            break;
        case "WindowsChanged": {
            const m = {};
            for (const w of e.windows)
                m[w.id] = w;
            windowMap = m;
            break;
        }
        case "WindowOpenedOrChanged": {
            const m = Object.assign({}, windowMap);
            if (e.window.is_focused)
                for (const id in m)
                    m[id] = Object.assign({}, m[id], { is_focused: false });
            m[e.window.id] = e.window;
            windowMap = m;
            break;
        }
        case "WindowClosed": {
            const m = Object.assign({}, windowMap);
            delete m[e.id];
            windowMap = m;
            break;
        }
        case "WindowFocusChanged": {
            const m = {};
            for (const id in windowMap)
                m[id] = Object.assign({}, windowMap[id], { is_focused: windowMap[id].id === e.id });
            windowMap = m;
            break;
        }
        case "WindowLayoutsChanged": {
            // [[id, layout], …] — sizes/positions, e.g. a window going fullscreen.
            const m = Object.assign({}, windowMap);
            for (const [id, layout] of e.changes)
                if (m[id])
                    m[id] = Object.assign({}, m[id], { layout: layout });
            windowMap = m;
            break;
        }
        case "WindowUrgencyChanged":
            if (windowMap[e.id]) {
                const m = Object.assign({}, windowMap);
                m[e.id] = Object.assign({}, m[e.id], { is_urgent: e.urgent });
                windowMap = m;
            }
            break;
        case "KeyboardLayoutsChanged":
            keyboardLayouts = e.keyboard_layouts ?? { names: [], current_idx: 0 };
            break;
        case "KeyboardLayoutSwitched":
            keyboardLayouts = Object.assign({}, keyboardLayouts, { current_idx: e.idx });
            break;
        case "OverviewOpenedOrClosed":
            overviewOpen = e.is_open;
            break;
        case "ScreenshotCaptured":
            screenshotTaken(e.path ?? "");
            break;
        case "ConfigLoaded":
            configLoaded(e.failed ?? false);
            break;
        }
    }

    function patchWorkspace(id, patch) {
        if (!workspaceMap[id])
            return;
        const m = Object.assign({}, workspaceMap);
        m[id] = Object.assign({}, m[id], patch);
        workspaceMap = m;
    }

    Socket {
        id: events
        path: root.socketPath
        connected: root.available

        onConnectedChanged: {
            if (connected) {
                write('"EventStream"\n');
                flush();
            } else if (root.available) {
                reconnect.restart();
            }
        }

        parser: SplitParser {
            onRead: line => {
                try {
                    const msg = JSON.parse(line);
                    // The first reply acknowledges the request: {"Ok":"Handled"}.
                    if (msg.Ok !== undefined || msg.Err !== undefined)
                        return;
                    root.handle(msg);
                } catch (err) {
                    console.warn(`Niri: bad event line: ${err}`);
                }
            }
        }
    }

    // niri restarts (or a dev reload) drop the stream; reconnect.
    Timer {
        id: reconnect
        interval: 1000
        onTriggered: {
            events.connected = false;
            events.connected = true;
        }
    }

    Socket {
        id: actions
        path: root.socketPath
        connected: root.available

        property var queue: []

        function send(request) {
            queue.push(JSON.stringify(request));
            if (connected)
                drain();
            else
                connected = true;
        }

        function drain() {
            for (const r of queue)
                write(r + "\n");
            queue = [];
            flush();
        }

        onConnectedChanged: if (connected)
            drain()

        // Replies ({"Ok":…}/{"Err":…}) are only logged on error.
        parser: SplitParser {
            onRead: line => {
                if (line.includes('"Err"'))
                    console.warn(`Niri: action failed: ${line}`);
            }
        }
    }
}
