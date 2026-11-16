pragma Singleton

import QtQuick
import Quickshell

// The compositor, whichever one the session runs. The shell talks to this,
// never to a backend directly (docs/KWIN.md §2).
//
// Backends: niri (services/Niri.qml, over $NIRI_SOCKET) and KWin
// (services/KWin.qml, through `loft-kwin` and its KWin script). Both expose
// the same state, events and actions; what a backend can't do is off in
// `capabilities`, and its action is a no-op.
//
// The data model is niri's (niri-ipc `Window` / `Workspace`), because every
// consumer was written against it. Another backend produces the same shape:
//   window    { id (int, ascending = older), title, app_id, pid, workspace_id,
//               is_focused, is_floating, is_urgent, focus_timestamp?,
//               is_minimized? (KWin), layout? { window_size, tile_size,
//               tile_pos_in_workspace_view, pos_in_scrolling_layout } }
//   workspace { id, idx (1-based, per output), name, output, is_active,
//               is_focused, is_urgent, active_window_id }
// Under KWin a workspace is one virtual desktop on one output.
Singleton {
    id: root

    // Which compositor the session runs: $LOFT_COMPOSITOR if set, else
    // niri if $NIRI_SOCKET is set, else kwin in a KDE session.
    readonly property string session: {
        const forced = Quickshell.env("LOFT_COMPOSITOR") ?? "";
        if (forced !== "")
            return forced;
        if ((Quickshell.env("NIRI_SOCKET") ?? "") !== "")
            return "niri";
        if ((Quickshell.env("XDG_CURRENT_DESKTOP") ?? "").split(":").includes("KDE"))
            return "kwin";
        return "niri";
    }
    readonly property string backend: session === "kwin" ? "kwin" : "niri"
    readonly property var impl: backend === "kwin" ? KWin : Niri

    // What the backend can do: { columns, floating, minimize, overview,
    // windowScreenshot, workspaceNames, perOutputWorkspaces, titleBarEvents,
    // configReload, serverDecorations }. Menus hide what's off;
    // serverDecorations = the compositor gives the shell's own windows a
    // title bar, so they don't draw traffic lights.
    readonly property var capabilities: impl.capabilities

    Component.onCompleted: {
        if (session !== backend)
            console.warn(`Compositor: no ${session} backend; using ${backend} (inert without its socket)`);
    }

    // ── State ─────────────────────────────────────────────────────────────
    readonly property bool available: impl.available
    // id → workspace / window.
    readonly property var workspaceMap: impl.workspaceMap
    readonly property var windowMap: impl.windowMap
    // Sorted: workspaces by output then idx, windows by id.
    readonly property var workspaces: impl.workspaces
    readonly property var windows: impl.windows
    readonly property var focusedWindow: impl.focusedWindow
    readonly property var focusedWorkspace: impl.focusedWorkspace
    readonly property bool overviewOpen: impl.overviewOpen
    // { names: [...], current_idx }
    readonly property var keyboardLayouts: impl.keyboardLayouts
    // KDE Activities (KWin only; empty under niri).
    readonly property var activities: backend === "kwin" ? KWin.activities : []
    readonly property string currentActivity: backend === "kwin" ? KWin.currentActivity : ""

    function workspacesOn(output) {
        return impl.workspacesOn(output);
    }

    function windowsOn(workspaceId) {
        return impl.windowsOn(workspaceId);
    }

    // ── Events ────────────────────────────────────────────────────────────
    // A screenshot was taken, by the compositor or by Loft's capture; path
    // may be "".
    signal screenshotTaken(string path)
    // Loft's capture takes the picture now (before encoding): the island's
    // shutter flash. Emitted by the shell, not the compositor.
    signal shutter()
    // The compositor (re)loaded its config; failed = it kept the old one.
    signal configLoaded(bool failed)
    // A title bar's minimize button (niri-loft's traffic lights).
    signal windowMinimizeRequested(int id)
    // A title bar asked for the window menu at x, y (logical, within output).
    signal windowActionsMenuRequested(int id, string output, real x, real y)
    // The set of outputs changed (hotplug, enable/disable).
    signal outputsChanged()

    Connections {
        target: Niri
        enabled: root.backend === "niri"
        function onScreenshotTaken(path) {
            root.screenshotTaken(path);
        }
        function onConfigLoaded(failed) {
            root.configLoaded(failed);
        }
        function onWindowMinimizeRequested(id) {
            root.windowMinimizeRequested(id);
        }
        function onWindowActionsMenuRequested(id, output, x, y) {
            root.windowActionsMenuRequested(id, output, x, y);
        }
        function onOutputsChanged() {
            root.outputsChanged();
        }
    }

    Connections {
        target: KWin
        enabled: root.backend === "kwin"
        function onOutputsChanged() {
            root.outputsChanged();
        }
    }

    // ── Actions: any compositor ───────────────────────────────────────────
    function spawn(command) {
        impl.spawn(command);
    }

    function focusWindow(id) {
        impl.focusWindow(id);
    }

    function focusWorkspace(id) {
        impl.focusWorkspace(id);
    }

    // The next (delta > 0) or previous workspace on the focused output.
    function focusWorkspaceRelative(delta) {
        impl.focusWorkspaceRelative(delta);
    }

    function closeWindow(id) {
        impl.closeWindow(id);
    }

    function moveWindowToWorkspace(windowId, workspaceId, focus) {
        impl.moveWindowToWorkspace(windowId, workspaceId, focus);
    }

    // By position (1-based) on the window's output.
    function moveWindowToWorkspaceIndex(windowId, index, focus) {
        impl.moveWindowToWorkspaceIndex(windowId, index, focus);
    }

    // The focused window to the next (delta > 0) or previous workspace.
    function moveFocusedWindowToWorkspaceRelative(delta, focus) {
        impl.moveFocusedWindowToWorkspaceRelative(delta, focus);
    }

    function moveWindowToOutput(id, output) {
        impl.moveWindowToOutput(id, output);
    }

    function moveFocusedWindowToNextOutput() {
        impl.moveFocusedWindowToNextOutput();
    }

    // capabilities.floating
    function toggleFloating(id) {
        impl.toggleFloating(id);
    }

    function setFloating(id, floating) {
        impl.setFloating(id, floating);
    }

    // capabilities.minimize
    function setMinimized(id, minimized) {
        impl.setMinimized(id, minimized);
    }

    function toggleFullscreen(id) {
        impl.toggleFullscreen(id);
    }

    function maximizeToEdges(id) {
        impl.maximizeToEdges(id);
    }

    function centerWindow(id) {
        impl.centerWindow(id);
    }

    // Sizes and positions in % of the output's working area.
    function setWindowWidthPercent(id, percent) {
        impl.setWindowWidthPercent(id, percent);
    }

    function setWindowHeightPercent(id, percent) {
        impl.setWindowHeightPercent(id, percent);
    }

    function resetWindowHeight(id) {
        impl.resetWindowHeight(id);
    }

    function moveFloatingWindowPercent(id, x, y) {
        impl.moveFloatingWindowPercent(id, x, y);
    }

    function setWorkspaceName(workspaceId, name) {
        impl.setWorkspaceName(workspaceId, name);
    }

    function unsetWorkspaceName(workspaceId) {
        impl.unsetWorkspaceName(workspaceId);
    }

    function switchKeyboardLayout(index) {
        impl.switchKeyboardLayout(index);
    }

    function toggleOverview() {
        impl.toggleOverview();
    }

    // The compositor writes `path` (and copies it); screenshotTaken follows.
    // capabilities.windowScreenshot
    function screenshotWindow(id, path, showPointer) {
        impl.screenshotWindow(id, path, showPointer);
    }

    // KDE Activities (KWin).
    function setActivity(activity) {
        impl.setActivity(activity);
    }

    // ── Actions: scrolling-layout columns (capabilities.columns) ─────────
    // These act on the focused column; given a window id, it's focused first.
    function maximizeColumn(id) {
        impl.maximizeColumn(id);
    }

    function setColumnWidthPercent(id, percent) {
        impl.setColumnWidthPercent(id, percent);
    }

    function expandColumn(id) {
        impl.expandColumn(id);
    }

    function centerVisibleColumns(id) {
        impl.centerVisibleColumns(id);
    }

    function expelWindowFromColumn(id) {
        impl.expelWindowFromColumn(id);
    }

    function consumeOrExpelWindowLeft(id) {
        impl.consumeOrExpelWindowLeft(id);
    }
}
