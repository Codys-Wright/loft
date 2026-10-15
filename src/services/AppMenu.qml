pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The global menu (File / Edit / View … of the focused app), from the
// loft-appmenu daemon (crates/loft-appmenu): it owns
// com.canonical.AppMenu.Registrar — so Qt apps export their menubar over
// DBusMenu instead of drawing it — and finds GTK menubars by introspection.
// niri has no appmenu protocol, so menus are matched to windows by pid.
//
// Protocol: line-JSON. We send {"cmd":"focus","pid",…} when the focused
// window changes, and open/close/activate; it sends {"menu": tree|null}.
// Also home of the Menu Bar module's preferences (Settings.menubar).
Singleton {
    id: root

    // { source, pid, service, path, items: [{ id, label, mnemonic, enabled,
    //   separator, toggle, checked, shortcut, submenu, children }] } or null
    property var menu: null
    readonly property var titles: enabled && menu ? menu.items : []
    // "owned" | "external" | "off" | "" (daemon not running)
    property string registrar: ""
    property string lastError: ""
    readonly property bool enabled: Features.on("globalMenu")
    readonly property bool running: proc.running
    // While a menu is open the focused window is pinned (the menu itself
    // takes keyboard focus, which niri may report as "no window").
    property bool frozen: false
    property string sent: ""

    // The window whose menus the bar shows. niri reports no focused window
    // while a layer surface (this menu, Spotlight…) has the keyboard, so
    // the last focused one stays active as long as it's still there on the
    // focused workspace (an empty workspace does clear it).
    property var lastWindow: null
    readonly property var activeWindow: {
        const f = Niri.focusedWindow;
        if (f)
            return f;
        const l = lastWindow ? Niri.windowMap[lastWindow.id] : null;
        return l && l.workspace_id === Niri.focusedWorkspace?.id ? l : null;
    }

    // ── Preferences ──────────────────────────────────────────────────────
    readonly property var defaults: ({
            desktopActions: true, // New Window + the .desktop file's actions
            windowCommands: true, // float, fullscreen, center, maximize, close
            moveCommands: true, // Move to Workspace ▸ / Display ▸
            hideCommands: true, // Hide, Hide Others, Show All
            confirmQuit: true, // ask before quitting an app with several windows
            forceQuitDelay: 3, // seconds before SIGTERM if the app outlives its windows; 0 = never
            symbols: true, // ⌃⇧S instead of Ctrl+Shift+S
            powerCountdown: true // system menu: Restart / Shut Down / Log Out go ahead after 60 s
        })

    function pref(key) {
        const v = Settings.menubar[key];
        return v === undefined ? defaults[key] : v;
    }

    function setPref(key, value) {
        const m = Object.assign({}, Settings.menubar);
        m[key] = value;
        Settings.menubar = m;
    }

    // ── Shortcuts ────────────────────────────────────────────────────────
    // [["Control","Shift","S"]] → "⌃⇧S" (macOS order ⌃⌥⇧⌘) or "Ctrl+Shift+S".
    function formatShortcut(chords) {
        if (!chords || chords.length === 0)
            return "";
        const sym = pref("symbols");
        const order = ["Control", "Alt", "Shift", "Super"];
        const glyph = { Control: "⌃", Alt: "⌥", Shift: "⇧", Super: "⌘" };
        const text = { Control: "Ctrl", Alt: "Alt", Shift: "Shift", Super: "Super" };
        const keyGlyph = { Return: "↩", Backspace: "⌫", Del: "⌦", Esc: "⎋", Tab: "⇥", Space: "␣", Left: "←", Right: "→", Up: "↑", Down: "↓", PgUp: "⇞", PgDown: "⇟", Home: "↖", End: "↘" };
        return chords.map(chord => {
            const mods = chord.slice(0, -1).filter(k => order.includes(k)).sort((a, b) => order.indexOf(a) - order.indexOf(b));
            const key = chord[chord.length - 1];
            if (sym)
                return mods.map(m => glyph[m]).join("") + (keyGlyph[key] ?? key);
            return mods.map(m => text[m]).concat([key]).join("+");
        }).join("  ");
    }

    // ── Daemon ───────────────────────────────────────────────────────────
    function focusMessage(w) {
        if (!w || !w.pid)
            return { cmd: "focus" };
        const same = Niri.windows.filter(x => x.pid === w.pid).sort((a, b) => a.id - b.id);
        const others = Niri.windows.filter(x => x.pid && x.pid !== w.pid).map(x => x.pid);
        return {
            cmd: "focus",
            pid: w.pid,
            index: same.findIndex(x => x.id === w.id),
            count: same.length,
            exclude: [...new Set(others)]
        };
    }

    function send(msg) {
        if (proc.running)
            proc.write(JSON.stringify(msg) + "\n");
    }

    function sync() {
        if (!proc.running || frozen)
            return;
        const msg = JSON.stringify(focusMessage(activeWindow));
        if (msg === sent)
            return;
        sent = msg;
        proc.write(msg + "\n");
    }

    function activate(id) {
        send({ cmd: "activate", id: id });
    }
    function open(id) {
        send({ cmd: "open", id: id });
    }
    function close(id) {
        send({ cmd: "close", id: id });
    }
    function refresh() {
        send({ cmd: "refresh" });
    }

    function handle(line) {
        let ev;
        try {
            ev = JSON.parse(line);
        } catch (e) {
            console.warn(`AppMenu: bad line: ${line}`);
            return;
        }
        if (ev.menu !== undefined)
            menu = ev.menu;
        else if (ev.status)
            registrar = ev.status.registrar;
        else if (ev.error) {
            lastError = ev.error;
            console.warn(`loft-appmenu: ${ev.error}`);
        } else
            console.warn(`loft-appmenu: ${line}`);
    }

    onFrozenChanged: sync()
    onEnabledChanged: {
        proc.running = enabled;
        if (!enabled)
            menu = null;
    }
    Component.onCompleted: proc.running = enabled

    Connections {
        target: Niri
        function onWindowMapChanged() {
            if (Niri.focusedWindow)
                root.lastWindow = Niri.focusedWindow;
            root.sync();
        }
        function onWorkspaceMapChanged() {
            root.sync();
        }
    }

    Process {
        id: proc
        command: [Quickshell.env("LOFT_APPMENU_BIN") || "loft-appmenu"]
        stdinEnabled: true
        stdout: SplitParser {
            onRead: line => root.handle(line)
        }
        stderr: SplitParser {
            onRead: line => console.warn(`loft-appmenu: ${line}`)
        }
        onRunningChanged: {
            if (running) {
                root.sent = "";
                root.sync();
                return;
            }
            root.menu = null;
            root.registrar = "";
            // Crashed or killed: come back. Menubars exported meanwhile are
            // found again by introspection, registered or not.
            if (root.enabled)
                restart.start();
        }
    }

    Timer {
        id: restart
        interval: 2000
        onTriggered: if (root.enabled && !proc.running)
            proc.running = true
    }
}
