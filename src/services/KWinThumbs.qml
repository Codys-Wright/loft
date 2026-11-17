pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Window stills under KWin (docs/KWIN.md §4.8), for the dock preview and the
// switcher (components/WindowThumb.qml). KWin has no toplevel capture
// protocol, but its ScreenShot2 captures one window by uuid: `loft-kwin
// thumbs DIR MAX UUID…` writes a small PNG per window (longer side ≤
// maxSide) into $XDG_RUNTIME_DIR and prints a line per window.
//
// Nothing polls: a still is taken when something asks for it (a preview or
// the switcher opening, then every couple of seconds while it stays open),
// and once after a window has been focused for a moment, so the switcher
// opens with a picture already there. KWin 6.8 captures windows that are
// covered, on another desktop or minimized (their last frame). A capture
// that fails keeps the last still; with none, consumers show the app icon.
// Stills go with their window.
Singleton {
    id: root

    readonly property bool enabled: Compositor.backend === "kwin" && Compositor.capabilities.windowThumbnails === true && KWin.available
    readonly property string dir: `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/loft-kwin-thumbs/${Quickshell.env("WAYLAND_DISPLAY") || "wayland"}`
    // The longer side of a still, px (the dock preview's cards are 196×124,
    // the switcher's cells at most 220 wide; ×2 for HiDPI).
    readonly property int maxSide: 440

    // window id → { url, at (ms), ms (capture time) }
    property var thumbs: ({})
    // Window ids waiting for the next batch.
    property var queue: []
    // uuid → window id, for the batch running now.
    property var batch: ({})
    // The first batch clears out an earlier run's stills first.
    property bool cleaned: false

    function url(id) {
        return thumbs[id]?.url ?? "";
    }

    // Capture `ids` unless their still is younger than `maxAge` ms. A
    // failed capture keeps the still there is.
    function request(ids, maxAge) {
        if (!enabled)
            return;
        const now = Date.now();
        const q = queue.slice();
        for (const id of ids) {
            const w = Compositor.windowMap[id];
            if (!w?.kwin_uuid || q.includes(id))
                continue;
            if (thumbs[id] && now - thumbs[id].at < (maxAge ?? 0))
                continue;
            q.push(id);
        }
        if (q.length === queue.length)
            return;
        queue = q;
        // Every card asks on its own: one batch for all of them.
        Qt.callLater(flush);
    }

    function flush() {
        if (proc.running || queue.length === 0)
            return;
        const b = {};
        for (const id of queue) {
            const u = Compositor.windowMap[id]?.kwin_uuid;
            if (u)
                b[u] = id;
        }
        queue = [];
        if (Object.keys(b).length === 0)
            return;
        batch = b;
        const argv = [KWin.bin, "thumbs", dir, String(maxSide)].concat(Object.keys(b));
        proc.command = cleaned ? argv : ["sh", "-c", 'rm -rf -- "$1"; shift; exec "$@"', "sh", dir].concat(argv);
        cleaned = true;
        proc.running = true;
    }

    function handle(line) {
        let r;
        try {
            r = JSON.parse(line);
        } catch (e) {
            return;
        }
        const id = batch[r.window];
        if (id === undefined || !r.path || !Compositor.windowMap[id])
            return;
        const m = Object.assign({}, thumbs);
        // A new URL each time, so the Image reloads the file.
        m[id] = { url: `file://${r.path}?t=${Date.now()}`, at: Date.now(), ms: r.ms };
        thumbs = m;
    }

    Process {
        id: proc
        stdout: SplitParser {
            onRead: line => root.handle(line)
        }
        stderr: SplitParser {
            onRead: line => console.warn(`loft-kwin thumbs: ${line}`)
        }
        onExited: {
            root.batch = {};
            Qt.callLater(root.flush);
        }
    }

    // A window that has been focused for a moment: one still, if the last
    // is old, so a minimized window has a recent picture.
    Connections {
        target: Compositor
        enabled: root.enabled
        function onFocusedWindowChanged() {
            settle.restart();
        }
        function onWindowMapChanged() {
            const gone = Object.keys(root.thumbs).filter(id => !Compositor.windowMap[id]);
            if (gone.length === 0)
                return;
            const m = Object.assign({}, root.thumbs);
            const files = [];
            for (const id of gone) {
                files.push(m[id].url.replace(/^file:\/\//, "").replace(/\?.*$/, ""));
                delete m[id];
            }
            root.thumbs = m;
            Quickshell.execDetached(["rm", "-f"].concat(files));
        }
    }
    Timer {
        id: settle
        interval: 1500
        onTriggered: {
            const w = Compositor.focusedWindow;
            if (w)
                root.request([w.id], 10000);
        }
    }

    // Stills of an earlier run are stale, and a restarted loft-kwin numbers
    // windows afresh.
    onEnabledChanged: {
        thumbs = {};
        queue = [];
        cleaned = false;
    }
}
