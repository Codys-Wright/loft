pragma Singleton

import QtQuick
import Quickshell

// The dock's window preview (feature dockPreview): which one is open, and
// the window thumbnails it shows.
//
// Thumbnails, best first:
// - niri-loft (nix/niri/toplevel-export.patch): each card captures its own
//   window, wherever it is — tiled, on another workspace, hidden — live
//   while the popover is open (components/WindowThumb.qml, WindowCapture).
// - Elsewhere (stock niri: wlr-screencopy of whole displays only), a window
//   is cropped out of a still of its display (dock/WindowThumbs.qml) when
//   niri says where it is on screen: floating windows
//   (tile_pos_in_workspace_view) and fullscreen ones, on a workspace that is
//   showing. Tiled windows get no position in niri's IPC, so they show their
//   app icon unless an earlier snapshot is cached. Snapshots are kept per
//   window (in memory) until it closes.
// Capture is only attempted where `loft dock capture` says it's safe
// (WindowCapture); elsewhere every card shows its app icon.
Singleton {
    id: root

    readonly property bool enabled: Features.on("dockPreview") && Features.on("dock")
    // "hover" (after `delay` ms) or "click" (an app with several windows).
    readonly property string mode: Settings.dock.preview === "click" ? "click" : "hover"
    readonly property int delay: Math.max(0, Settings.dock.previewDelay)
    readonly property bool thumbnails: Settings.dock.previewThumbnails && (WindowCapture.canWindows || canCapture || stillPath !== "")
    // Cards capture their own windows (niri-loft).
    readonly property bool windowThumbs: Settings.dock.previewThumbnails && WindowCapture.canWindows

    readonly property var support: WindowCapture.support
    readonly property bool canCapture: WindowCapture.canScreens
    // Test sessions only (LOFT_DEV): a PNG of the whole session standing in
    // for the display capture, so cropping and the cards can be checked
    // where ScreencopyView can't run (see above).
    readonly property string stillPath: Quickshell.env("LOFT_DEV") === "1" ? (Quickshell.env("LOFT_DEV_PREVIEW_STILL") ?? "") : ""

    // The open preview: { screen, appId, x, y, edge } (x, y: the icon's
    // outward edge in screen coordinates), or null.
    property var current: null
    // The pointer is on the popover (keeps it open).
    property bool hovered: false

    function close() {
        current = null;
        hovered = false;
    }

    // ── Thumbnails: window id → { url, at, result } ─────────────────────
    property var thumbs: ({})

    function thumb(id) {
        return thumbs[id]?.url ?? "";
    }

    // `result`: an ItemGrabResult (kept, or its url stops resolving).
    function setThumb(id, result) {
        const m = Object.assign({}, thumbs);
        m[id] = { url: String(result.url), at: Date.now(), result: result };
        thumbs = m;
    }

    // Drop the snapshots of closed windows.
    Connections {
        target: Niri
        function onWindowMapChanged() {
            const gone = Object.keys(root.thumbs).filter(id => !Niri.windowMap[id]);
            if (gone.length === 0)
                return;
            const m = Object.assign({}, root.thumbs);
            for (const id of gone)
                delete m[id];
            root.thumbs = m;
        }
    }

    // ── Where a window is ────────────────────────────────────────────────
    function isParked(w) {
        return (Niri.workspaceMap[w.workspace_id]?.name ?? "").startsWith("hidden-");
    }

    // The window's rectangle on its display right now, in that display's
    // logical px — { output, x, y, width, height } — or null when niri
    // doesn't say or something may cover it.
    function screenRect(w) {
        const ws = Niri.workspaceMap[w.workspace_id];
        if (!ws || !ws.is_active || !ws.output || isParked(w) || Niri.overviewOpen)
            return null;
        const scr = Quickshell.screens.find(s => s.name === ws.output);
        const l = w.layout;
        if (!scr || !l)
            return null;
        const others = Niri.windows.filter(x => x.id !== w.id && x.workspace_id === ws.id);
        let r = null;
        if (w.is_floating && l.tile_pos_in_workspace_view) {
            const off = l.window_offset_in_tile ?? [0, 0];
            r = {
                x: l.tile_pos_in_workspace_view[0] + off[0],
                y: l.tile_pos_in_workspace_view[1] + off[1],
                width: l.window_size[0],
                height: l.window_size[1]
            };
            // Another floating window over it? Only the focused one is surely on top.
            const overlaps = others.some(x => {
                const o = x.layout;
                if (!x.is_floating || !o?.tile_pos_in_workspace_view)
                    return false;
                const ox = o.tile_pos_in_workspace_view[0], oy = o.tile_pos_in_workspace_view[1];
                return ox < r.x + r.width && ox + o.tile_size[0] > r.x && oy < r.y + r.height && oy + o.tile_size[1] > r.y;
            });
            if (overlaps && !w.is_focused)
                return null;
        } else if (!w.is_floating && l.window_size && l.window_size[0] >= scr.width && l.window_size[1] >= scr.height) {
            // Fullscreen: the whole display, if it's the one showing there.
            if (ws.active_window_id !== w.id || others.some(x => x.is_floating))
                return null;
            r = { x: 0, y: 0, width: scr.width, height: scr.height };
        } else {
            return null;
        }
        // Mostly on screen, or nothing.
        const x0 = Math.max(0, r.x), y0 = Math.max(0, r.y);
        const x1 = Math.min(scr.width, r.x + r.width), y1 = Math.min(scr.height, r.y + r.height);
        if (x1 - x0 < r.width * 0.8 || y1 - y0 < r.height * 0.8 || x1 - x0 < 16 || y1 - y0 < 16)
            return null;
        return { output: ws.output, x: x0, y: y0, width: x1 - x0, height: y1 - y0 };
    }
}
