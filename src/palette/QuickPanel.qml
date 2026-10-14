pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// Quick panel (vorssaint's ⌃⌘V palette): a floating glass palette of your
// favorite tools — any entry of the action catalog (Actions.qml) — plus the
// latest clipboard entries and your snippets, opened near the pointer.
// The window is QuickPanelWindow.qml; Settings → Quick Panel edits it.
//
// <state>/quickpanel.json: { favorites: [action ids], size: small|medium|
// large, position: pointer|center, clipboard: N entries, snippets: bool }
//
// IPC: quickpanel toggle | open | close | settings
Singleton {
    id: root

    readonly property bool enabled: Features.on("quickPanel")
    property bool open: false
    // Output it is open on, and the pointer there (-1 = not known yet).
    property string screen: ""
    property real pointerX: -1
    property real pointerY: -1
    // The window focused when it opened: window actions act on it.
    property var windowId: null

    readonly property var defaults: ({
            favorites: ["capture:area", "capture:selector", "capture:text", "capture:color", "clipboard:history", "snippets:picker", "scratchpad", "timer:25", "control:caffeine", "control:nightLight", "control:micMute", "settings"],
            size: "medium",
            position: "pointer",
            clipboard: 5,
            snippets: true
        })

    readonly property var cfg: Object.assign({}, defaults, store.value ?? {})
    readonly property var favorites: (cfg.favorites ?? []).filter(id => Actions.entry(id) !== null)
    readonly property string size: cfg.size
    readonly property int columns: size === "small" ? 4 : size === "large" ? 6 : 5
    readonly property int panelWidth: size === "small" ? 360 : size === "large" ? 540 : 450

    JsonStore {
        id: store
        path: `${Settings.stateDir}/quickpanel.json`
        fallback: null
    }

    function save(patch) {
        store.save(Object.assign({}, store.value ?? {}, patch));
    }

    function setOption(key, value) {
        const p = {};
        p[key] = value;
        save(p);
    }

    function isFavorite(id) {
        return favorites.includes(id);
    }

    function add(id) {
        if (!isFavorite(id))
            save({ favorites: favorites.concat([id]) });
    }

    function remove(id) {
        save({ favorites: favorites.filter(x => x !== id) });
    }

    // Move `id` to position `to` (clamped).
    function move(id, to) {
        const l = favorites.filter(x => x !== id);
        l.splice(Math.max(0, Math.min(l.length, to)), 0, id);
        save({ favorites: l });
    }

    function reset() {
        store.save({});
    }

    // ── Opening ──────────────────────────────────────────────────────────
    function show(screenName) {
        if (!enabled)
            return;
        screen = screenName || (Niri.focusedWorkspace?.output ?? "");
        pointerX = -1;
        pointerY = -1;
        windowId = Niri.focusedWindow?.id ?? null;
        if (Features.on("clipboard"))
            Clipboard.refresh();
        open = true;
    }

    function toggle() {
        if (open)
            open = false;
        else
            show("");
    }

    // Run after the panel has unmapped (the keyboard goes back to the app;
    // captures don't catch the panel).
    property var pending: null

    function activate(fn) {
        open = false;
        pending = fn;
        later.restart();
    }

    function runAction(id) {
        const ctx = { windowId: windowId };
        activate(() => Actions.run(id, ctx));
    }

    Timer {
        id: later
        interval: 90
        onTriggered: {
            const fn = root.pending;
            root.pending = null;
            if (fn)
                fn();
        }
    }

    IpcHandler {
        target: "quickpanel"

        function toggle(): void {
            root.toggle();
        }
        function open(): void {
            root.show("");
        }
        function close(): void {
            root.open = false;
        }
        function settings(): void {
            Panels.settingsSection = "quickpanel";
            Panels.settingsOpen = true;
        }
    }
}
