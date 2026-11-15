pragma Singleton

import QtQuick
import Quickshell

// The compositor, whichever one the session runs. The shell talks to this,
// never to a backend directly (docs/KWIN.md §2).
//
// Backends: niri (services/Niri.qml, over $NIRI_SOCKET) is the only one so
// far. KWin is planned (docs/KWIN.md). Until it exists, every session uses
// the niri backend, which is inert without $NIRI_SOCKET: no windows, no
// workspaces, and actions go nowhere.
//
// The data model is niri's (niri-ipc `Window` / `Workspace`), because every
// consumer was written against it. Another backend produces the same shape:
//   window    { id (int, ascending = older), title, app_id, pid, workspace_id,
//               is_focused, is_floating, is_urgent, focus_timestamp?,
//               layout? { window_size, tile_size, tile_pos_in_workspace_view,
//               pos_in_scrolling_layout } }
//   workspace { id, idx (1-based, per output), name, output, is_active,
//               is_focused, is_urgent, active_window_id }
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
    // The backend in use. Only niri exists yet.
    readonly property string backend: "niri"

    // What the backend can do. Under niri, everything. A KWin backend turns
    // off what it can't map (docs/KWIN.md §4), and the UI hides those items.
    readonly property var capabilities: ({
            columns: true, // scrolling-layout column ops (Arrange's tiled presets, Maximize Column)
            overview: true, // toggleOverview
            windowScreenshot: true, // screenshotWindow (compositor-side)
            workspaceNames: true, // setWorkspaceName / unsetWorkspaceName
            perOutputWorkspaces: true, // each output has its own workspaces
            titleBarEvents: true, // windowMinimizeRequested / windowActionsMenuRequested
            configReload: true // configLoaded
        })

    Component.onCompleted: {
        if (session !== backend)
            console.warn(`Compositor: no ${session} backend yet; using ${backend} (inert without its socket)`);
    }

    // ── State ─────────────────────────────────────────────────────────────
    readonly property bool available: Niri.available
    // id → workspace / window.
    readonly property var workspaceMap: Niri.workspaceMap
    readonly property var windowMap: Niri.windowMap
    // Sorted: workspaces by output then idx, windows by id.
    readonly property var workspaces: Niri.workspaces
    readonly property var windows: Niri.windows
    readonly property var focusedWindow: Niri.focusedWindow
    readonly property var focusedWorkspace: Niri.focusedWorkspace
    readonly property bool overviewOpen: Niri.overviewOpen
    // { names: [...], current_idx }
    readonly property var keyboardLayouts: Niri.keyboardLayouts

    function workspacesOn(output) {
        return Niri.workspacesOn(output);
    }

    function windowsOn(workspaceId) {
        return Niri.windowsOn(workspaceId);
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

    // ── Actions: any compositor ───────────────────────────────────────────
    function spawn(command) {
        Niri.spawn(command);
    }

    function focusWindow(id) {
        Niri.focusWindow(id);
    }

    function focusWorkspace(id) {
        Niri.focusWorkspace(id);
    }

    // The next (delta > 0) or previous workspace on the focused output.
    function focusWorkspaceRelative(delta) {
        Niri.action(delta > 0 ? "FocusWorkspaceDown" : "FocusWorkspaceUp");
    }

    function closeWindow(id) {
        Niri.action("CloseWindow", { id: id });
    }

    function moveWindowToWorkspace(windowId, workspaceId, focus) {
        Niri.action("MoveWindowToWorkspace", { window_id: windowId, reference: { Id: workspaceId }, focus: focus === true });
    }

    // By position (1-based) on the window's output.
    function moveWindowToWorkspaceIndex(windowId, index, focus) {
        Niri.action("MoveWindowToWorkspace", { window_id: windowId, reference: { Index: index }, focus: focus === true });
    }

    // The focused window to the next (delta > 0) or previous workspace.
    function moveFocusedWindowToWorkspaceRelative(delta, focus) {
        Niri.action(delta > 0 ? "MoveWindowToWorkspaceDown" : "MoveWindowToWorkspaceUp", { focus: focus === true });
    }

    function moveWindowToOutput(id, output) {
        Niri.action("MoveWindowToMonitor", { id: id, output: output });
    }

    function moveFocusedWindowToNextOutput() {
        Niri.action("MoveWindowToMonitorNext");
    }

    function toggleFloating(id) {
        Niri.action("ToggleWindowFloating", { id: id });
    }

    function setFloating(id, floating) {
        Niri.action(floating ? "MoveWindowToFloating" : "MoveWindowToTiling", { id: id });
    }

    function toggleFullscreen(id) {
        Niri.action("FullscreenWindow", { id: id });
    }

    function maximizeToEdges(id) {
        Niri.action("MaximizeWindowToEdges", { id: id });
    }

    function centerWindow(id) {
        Niri.action("CenterWindow", { id: id });
    }

    // Sizes and positions in % of the output's working area.
    function setWindowWidthPercent(id, percent) {
        Niri.action("SetWindowWidth", { id: id, change: { SetProportion: percent } });
    }

    function setWindowHeightPercent(id, percent) {
        Niri.action("SetWindowHeight", { id: id, change: { SetProportion: percent } });
    }

    function resetWindowHeight(id) {
        Niri.action("ResetWindowHeight", { id: id });
    }

    function moveFloatingWindowPercent(id, x, y) {
        Niri.action("MoveFloatingWindow", { id: id, x: { SetProportion: x }, y: { SetProportion: y } });
    }

    function setWorkspaceName(workspaceId, name) {
        Niri.action("SetWorkspaceName", { name: name, workspace: { Id: workspaceId } });
    }

    function unsetWorkspaceName(workspaceId) {
        Niri.action("UnsetWorkspaceName", { reference: { Id: workspaceId } });
    }

    function switchKeyboardLayout(index) {
        Niri.action("SwitchLayout", { layout: { Index: index } });
    }

    function toggleOverview() {
        Niri.toggleOverview();
    }

    // The compositor writes `path` (and copies it); screenshotTaken follows.
    function screenshotWindow(id, path, showPointer) {
        Niri.action("ScreenshotWindow", { id: id, write_to_disk: true, show_pointer: showPointer, path: path });
    }

    // ── Actions: scrolling-layout columns (capabilities.columns) ─────────
    // These act on the focused column; given a window id, it's focused first.
    function maximizeColumn(id) {
        focusFirst(id);
        Niri.action("MaximizeColumn");
    }

    function setColumnWidthPercent(id, percent) {
        focusFirst(id);
        Niri.action("SetColumnWidth", { change: { SetProportion: percent } });
    }

    function expandColumn(id) {
        focusFirst(id);
        Niri.action("ExpandColumnToAvailableWidth");
    }

    function centerVisibleColumns(id) {
        focusFirst(id);
        Niri.action("CenterVisibleColumns");
    }

    function expelWindowFromColumn(id) {
        focusFirst(id);
        Niri.action("ExpelWindowFromColumn");
    }

    function consumeOrExpelWindowLeft(id) {
        Niri.action("ConsumeOrExpelWindowLeft", { id: id });
    }

    function focusFirst(id) {
        if (id !== undefined && id !== null)
            Niri.focusWindow(id);
    }
}
