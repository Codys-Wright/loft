pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The active theme's vibe set and the user's choices from it.
//
// `studio theme vibes --json` lists the theme's own wallpapers and lock
// designs, curated ones from linked packs, then every other installed pack's
// (and the wallpaper folder's images) ranked by palette closeness
// (docs/THEME-FORMAT.md, "Vibes"). Re-read on theme switch and on demand.
//
// Choices are per theme (Settings.perTheme[<theme>]), so switching themes
// brings back that theme's wallpaper / rotation / lock; a key a theme never
// set falls back to the global Settings value.
//
// Wallpaper, per screen: the chosen one > rotation / per-workspace through
// the theme's collection > the theme's default.
// Lock: the chosen design > the theme's default (manifest) > built-in.
Singleton {
    id: root

    property var data: null
    property bool loading: false
    readonly property string theme: Theme.name

    // The last lock design that failed to load, for the Lock Screen page.
    property string lockError: ""
    property string lockErrorDesign: ""

    readonly property var wallpapers: data?.wallpapers ?? []
    readonly property var locks: data?.locks ?? []
    readonly property var themeWallpapers: wallpapers.filter(w => w.origin !== "match")
    readonly property var matchingWallpapers: wallpapers.filter(w => w.origin === "match")
    readonly property var themeLocks: locks.filter(l => l.origin !== "match")
    readonly property var matchingLocks: locks.filter(l => l.origin === "match")
    readonly property string defaultWallpaper: data?.defaults?.wallpaper ?? ""
    readonly property string defaultLock: data?.defaults?.lock ?? ""

    // Stills the image layer can show, for rotation / per-workspace.
    readonly property var collection: themeWallpapers.filter(w => w.kind === "image").map(w => w.path)

    // ── per-theme choices ───────────────────────────────────────────────
    readonly property var choices: Settings.perTheme?.[theme] ?? ({})

    function has(key) {
        return Object.prototype.hasOwnProperty.call(choices, key);
    }

    function setChoice(key, value) {
        const all = Object.assign({}, Settings.perTheme ?? {});
        const mine = Object.assign({}, all[theme] ?? {});
        mine[key] = value;
        all[theme] = mine;
        Settings.perTheme = all;
    }

    // "" = the theme's own default.
    readonly property string chosenWallpaper: has("wallpaper") ? choices.wallpaper : Settings.wallpaper.path
    readonly property real rotateMinutes: has("rotate") ? choices.rotate : Settings.wallpaper.rotate
    readonly property bool perWorkspace: has("perWorkspace") ? choices.perWorkspace : Settings.wallpaper.perWorkspace
    // A design dir, "builtin", or "" = the theme's default.
    readonly property string chosenLock: has("lockDesign") ? choices.lockDesign : Settings.lock.design

    function chooseWallpaper(path) {
        setChoice("wallpaper", path);
    }

    function chooseLock(path) {
        setChoice("lockDesign", path);
    }

    // ── wallpaper resolution ────────────────────────────────────────────
    property int step: 0
    onThemeChanged: {
        step = 0;
        refresh();
    }

    Timer {
        interval: Math.max(1, root.rotateMinutes) * 60000
        running: root.rotateMinutes > 0 && root.chosenWallpaper === "" && root.collection.length > 1
        repeat: true
        onTriggered: root.step++
    }

    // Absolute path (or "") of what a screen should show.
    function wallpaperFor(screenName) {
        if (chosenWallpaper !== "")
            return chosenWallpaper;
        const col = collection;
        if (col.length > 0 && (perWorkspace || rotateMinutes > 0)) {
            let i = step;
            if (perWorkspace) {
                const ws = Niri.workspaces.find(w => w.output === screenName && w.is_active) ?? Niri.focusedWorkspace;
                i += Math.max(0, (ws?.idx ?? 1) - 1);
            }
            return col[i % col.length];
        }
        return Theme.wallpaperImage;
    }

    function url(path) {
        if (!path)
            return "";
        const abs = path.startsWith("~/") ? Quickshell.env("HOME") + path.slice(1) : path;
        return abs.startsWith("/") ? "file://" + abs : abs;
    }

    // Whether this wallpaper is what the user sees now (for pickers).
    function isCurrentWallpaper(path) {
        if (chosenWallpaper !== "")
            return chosenWallpaper === path;
        return path === defaultWallpaper && !(perWorkspace || rotateMinutes > 0);
    }

    // ── lock resolution ─────────────────────────────────────────────────
    // { builtin: true } | { path, main, format, name } | null (= the theme's default)
    readonly property var lockChoice: {
        if (chosenLock === "builtin")
            return { builtin: true };
        if (chosenLock === "")
            return null;
        return locks.find(l => l.path === chosenLock) ?? { path: chosenLock, main: chosenLock + "/Main.qml", format: "", name: chosenLock.split("/").pop() };
    }

    function isCurrentLock(path) {
        if (chosenLock === "")
            return path === (defaultLock || "builtin");
        return chosenLock === path;
    }

    // Lock now with the current choice (Lock.qml listens).
    signal lockRequested

    function previewLock() {
        lockRequested();
    }

    // ── data ────────────────────────────────────────────────────────────
    readonly property string folder: {
        const d = Settings.wallpaper.directory;
        return d.startsWith("~/") ? Quickshell.env("HOME") + d.slice(1) : d;
    }
    onFolderChanged: refresh()

    function refresh() {
        if (proc.running) {
            pending = true;
            return;
        }
        loading = true;
        proc.command = ["studio", "theme", "vibes", "--json", "--dir", folder];
        proc.running = true;
    }
    property bool pending: false

    Component.onCompleted: refresh()

    Process {
        id: proc
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.data = JSON.parse(text);
                } catch (e) {
                    console.warn(`Vibes: bad output from studio theme vibes: ${e}`);
                }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "")
                console.warn(`Vibes: ${text.trim()}`)
        }
        onExited: {
            root.loading = false;
            if (root.pending) {
                root.pending = false;
                root.refresh();
            }
        }
    }

    IpcHandler {
        target: "vibes"

        function refresh(): void {
            root.refresh();
        }

        // Next / previous wallpaper of the theme's collection (as a choice).
        function next(): void {
            root.cycle(1);
        }

        function prev(): void {
            root.cycle(-1);
        }

        function current(): string {
            return root.wallpaperFor(Niri.focusedWorkspace?.output ?? "");
        }

        function lockDesign(): string {
            return root.chosenLock || "(theme default) " + root.defaultLock;
        }

        // Lock now with this theme's chosen design (Settings → Lock Screen → Preview).
        function previewLock(): void {
            root.previewLock();
        }
    }

    function cycle(dir) {
        const col = collection;
        if (col.length === 0)
            return;
        // The theme default shows the rendered bundle's copy: find it by its pack path.
        let cur = col.indexOf(wallpaperFor(Niri.focusedWorkspace?.output ?? ""));
        if (cur < 0)
            cur = col.indexOf(defaultWallpaper);
        chooseWallpaper(col[((cur < 0 ? 0 : cur + dir) % col.length + col.length) % col.length]);
    }
}
