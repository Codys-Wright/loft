pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// What the dock knows beyond niri: recent files per app (recently-used.xbel
// + editor workspaces, via `loft dock recents`), Open at Login (XDG
// autostart, `loft dock autostart`), Assign To (niri window rules in
// overrides/niri.json, written through loft-niri), docked folders and the
// Trash (DockFolder), and which stack popup is open.
Singleton {
    id: root

    readonly property string stateDir: Quickshell.env("LOFT_STATE_DIR") || `${Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state"}/loft`
    readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share"

    // ── Same app? Pins may be desktop ids, windows carry niri app ids ─────
    function entryId(appId) {
        if (Apps.own[appId] !== undefined)
            return appId;
        return Apps.entry(appId)?.id ?? appId;
    }

    function sameApp(a, b) {
        return a === b || (a && b && entryId(a) === entryId(b));
    }

    function windowsOf(appId) {
        return Niri.windows.filter(w => w.app_id && sameApp(w.app_id, appId));
    }

    function isPinned(appId) {
        return Array.from(Settings.dock.pinned).some(p => sameApp(p, appId));
    }

    function setPinned(appId, on) {
        const l = Array.from(Settings.dock.pinned).filter(p => !sameApp(p, appId));
        if (on)
            l.push(appId);
        Settings.dock.pinned = l;
    }

    // ── Dock profiles ────────────────────────────────────────────────────
    // Everything a dock shows and how it behaves, in one shape:
    //   { pinned, folders, trash, recentCount, iconSize, magnification,
    //     bounce, indicators, enabled, autoHide, position, hidden }
    // Read it through profileFor(screen), never Settings.dock directly.
    // The layers: Settings.dock (defaults) ← the active space's `dock`
    // (Spaces.dock, SPACES §5: pinned replace / prepend / append, visible
    // show / autohide / hidden) ← the display's own prefs (enabled /
    // position; its auto-hide only while the space says nothing).
    function profileFor(screen) {
        const d = Settings.dock;
        const disp = displayPrefs(screen);
        const sp = Spaces.dock;
        let pinned = Array.from(d.pinned);
        if (sp && Array.isArray(sp.pinned)) {
            const own = Array.from(sp.pinned);
            const rest = pinned.filter(p => !own.some(o => sameApp(o, p)));
            pinned = sp.mode === "append" ? rest.concat(own) : sp.mode === "prepend" ? own.concat(rest) : own;
        }
        const visible = sp?.visible ?? "";
        return {
            pinned: pinned,
            folders: Array.from(d.folders),
            trash: d.trash,
            recentCount: d.recentCount,
            iconSize: d.iconSize,
            magnification: d.magnification,
            bounce: d.bounce,
            indicators: d.indicators,
            enabled: disp.enabled,
            autoHide: visible === "show" ? "never" : visible === "autohide" ? "always" : disp.autoHide,
            // A space's `visible: "hidden"`: no dock, no edge to summon it.
            hidden: visible === "hidden",
            position: disp.position
        };
    }

    // ── Per display ──────────────────────────────────────────────────────
    function displayKey(screen) {
        return Displays.identity(screen.name);
    }

    // Auto-hide modes: "never", "always", or "whenWindows" (shown while
    // the display's workspace is empty, hidden once a window is open there).
    // Booleans from older settings mean always / never.
    function hideMode(v) {
        if (v === true)
            return "always";
        if (v === false || v === undefined || v === null)
            return "never";
        return ["never", "always", "whenWindows"].includes(v) ? v : "never";
    }

    // { enabled, autoHide (mode), position } for a screen: its own entry in
    // Settings.dock.displays, else the dock-wide defaults (an ultrawide,
    // ≥ 2.2:1, hides when windows are open).
    function displayPrefs(screen) {
        const all = Settings.dock.displays ?? {};
        const p = all[displayKey(screen)] ?? all[screen.name] ?? {};
        const ultrawide = screen.width / Math.max(1, screen.height) >= 2.2;
        const pos = p.position ?? Settings.dock.position;
        const fallback = Settings.dock.autoHide !== false && Settings.dock.autoHide !== "never" ? Settings.dock.autoHide : ultrawide ? "whenWindows" : "never";
        return {
            enabled: p.enabled ?? true,
            autoHide: hideMode(p.autoHide ?? fallback),
            position: pos === "left" || pos === "right" ? pos : "bottom"
        };
    }

    function setDisplayPref(screen, key, value) {
        const all = Object.assign({}, Settings.dock.displays ?? {});
        const k = displayKey(screen);
        const cur = Object.assign({}, all[k] ?? all[screen.name] ?? {});
        delete all[screen.name];
        cur[key] = value;
        all[k] = cur;
        Settings.dock.displays = all;
    }

    // "MPG491CX OLED (center)" — model and where it sits, left to right.
    function displayLabel(screen) {
        const model = Displays.models[screen.name] ?? screen.name;
        const xs = Quickshell.screens.map(s => s.x).sort((a, b) => a - b);
        if (xs.length < 2)
            return model;
        const i = xs.indexOf(screen.x);
        const where = i === 0 ? "left" : i === xs.length - 1 ? "right" : xs.length === 3 ? "center" : `${i + 1} of ${xs.length}`;
        return `${model} (${where})`;
    }

    // ── Recent files ─────────────────────────────────────────────────────
    // desktop id → [{ path, name, dir, mime, icon, generic, source }]
    property var recents: ({})

    function recentFor(appId) {
        return recents[entryId(appId)] ?? recents[appId] ?? [];
    }

    function refreshRecents() {
        if (recentsProc.running)
            return;
        recentsProc.running = true;
    }

    Process {
        id: recentsProc
        command: ["loft", "dock", "recents", "--limit", "10"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.recents = JSON.parse(text).byApp ?? {};
                } catch (e) {
                    console.warn(`dock: bad recents: ${e}`);
                }
            }
        }
    }

    FileView {
        path: `${root.dataHome}/recently-used.xbel`
        watchChanges: true
        printErrors: false
        // Only the change matters (the helper parses it); reloading keeps
        // the watch on the file GTK replaces by renaming.
        onFileChanged: {
            reload();
            recentsDebounce.restart();
        }
    }

    Timer {
        id: recentsDebounce
        interval: 1500
        onTriggered: root.refreshRecents()
    }

    // ── Open at Login ────────────────────────────────────────────────────
    property var loginItems: []

    function openAtLogin(appId) {
        return loginItems.includes(entryId(appId));
    }

    function setOpenAtLogin(appId, on) {
        Quickshell.execDetached(["sh", "-c", 'loft dock autostart set "$1" "$2" >/dev/null; true', "loft-dock", entryId(appId), on ? "on" : "off"]);
        // Optimistic; re-read shortly.
        const l = loginItems.filter(i => i !== entryId(appId));
        if (on)
            l.push(entryId(appId));
        loginItems = l;
        loginRefresh.restart();
    }

    Process {
        id: loginList
        command: ["loft", "dock", "autostart", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.loginItems = JSON.parse(text).enabled ?? [];
                } catch (e) {}
            }
        }
    }

    Timer {
        id: loginRefresh
        interval: 700
        onTriggered: loginList.running = true
    }

    // Start the Open-at-Login apps once per niri session (unless systemd's
    // xdg-desktop-autostart.target already does).
    Process {
        id: autostartRun
        command: ["loft", "dock", "autostart", "run", "--once", Quickshell.env("NIRI_SOCKET") || "session"]
    }

    // ── Assign To (niri window rules) ────────────────────────────────────
    property var rules: ({})

    FileView {
        path: `${root.stateDir}/overrides/niri.json`
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                const o = JSON.parse(text());
                root.rules = o["window-rules"] ?? {};
            } catch (e) {
                root.rules = {};
            }
        }
        onLoadFailed: root.rules = {}
    }

    // The workspace name the app is assigned to, or "".
    function assignedTo(appId) {
        return rules[appId]?.["open-on-workspace"] ?? "";
    }

    function wsName(ws) {
        if (ws.name)
            return ws.name;
        const clash = Niri.workspaces.some(x => x.id !== ws.id && x.idx === ws.idx);
        return clash ? `Desktop ${ws.idx} (${ws.output})` : `Desktop ${ws.idx}`;
    }

    // Assign the app to a workspace (niri: open-on-workspace, which needs a
    // named workspace), or null for none. An unnamed workspace is named
    // "Desktop N" (+ " (OUTPUT)" when N is ambiguous) now, and again by
    // ensureNamed() whenever niri starts without it — the overrides can't
    // declare it (the fragment is included twice: it would exist twice).
    function assign(appId, ws) {
        const batch = { window_rules: {} };
        if (!ws) {
            // Fields merge per app (crates/loft-niri window_rules): drop only this one.
            batch.window_rules[appId] = { "open-on-workspace": null };
        } else {
            const name = wsName(ws);
            if (!ws.name)
                Niri.action("SetWorkspaceName", { name: name, workspace: { Id: ws.id } });
            batch.window_rules[appId] = { "open-on-workspace": name };
        }
        NiriSettings.apply(batch);
    }

    // Rules point at "Desktop N" names that may not exist (niri restarted):
    // name the matching unnamed workspace again.
    function ensureNamed() {
        const wanted = [...new Set(Object.values(rules).map(r => r["open-on-workspace"]).filter(n => n))];
        for (const name of wanted) {
            if (Niri.workspaces.some(w => w.name === name))
                continue;
            const m = /^Desktop (\d+)(?: \((.+)\))?$/.exec(name);
            if (!m)
                continue;
            const output = m[2] ?? Niri.focusedWorkspace?.output;
            const ws = Niri.workspaces.find(w => w.output === output && w.idx === Number(m[1]) && !w.name);
            if (ws)
                Niri.action("SetWorkspaceName", { name: name, workspace: { Id: ws.id } });
        }
    }

    Timer {
        id: ensureTimer
        interval: 1500
        onTriggered: root.ensureNamed()
    }
    onRulesChanged: ensureTimer.restart()
    Connections {
        target: Niri
        function onWorkspaceMapChanged() {
            ensureTimer.restart();
        }
    }

    // ── Folders and the Trash ────────────────────────────────────────────
    readonly property bool stacksOn: Features.on("dockStacks")

    Variants {
        id: folderSources
        model: root.stacksOn ? Settings.dock.folders : []

        DockFolder {
            required property var modelData
            spec: modelData.path ?? ""
            sort: modelData.sort ?? "added"
        }
    }

    function folder(spec) {
        return folderSources.instances.find(f => f.spec === spec) ?? null;
    }

    function setFolder(index, patch) {
        const l = Array.from(Settings.dock.folders).map(f => Object.assign({}, f));
        if (index < 0 || index >= l.length)
            return;
        l[index] = Object.assign(l[index], patch);
        Settings.dock.folders = l;
    }

    function removeFolder(index) {
        const l = Array.from(Settings.dock.folders).filter((_, i) => i !== index);
        Settings.dock.folders = l;
    }

    function addFolder(path) {
        const p = (path ?? "").trim();
        if (p === "" || Array.from(Settings.dock.folders).some(f => f.path === p))
            return;
        Settings.dock.folders = Array.from(Settings.dock.folders).concat([{ path: p, sort: "added", display: "stack", view: "auto" }]);
    }

    LazyLoader {
        id: trashLoader
        active: root.stacksOn && Settings.dock.trash
        DockFolder {
            trash: true
        }
    }

    readonly property var trash: trashLoader.item
    readonly property bool trashFull: (trash?.count ?? 0) > 0

    function emptyTrash() {
        // The home trash only (`loft dock trash --empty`), never other volumes'.
        Quickshell.execDetached(["loft", "dock", "trash", "--empty"]);
    }

    function trashFiles(urls) {
        const paths = urls.map(u => decodeURIComponent(String(u).replace(/^file:\/\//, ""))).filter(p => p.startsWith("/"));
        if (paths.length > 0)
            Quickshell.execDetached(["gio", "trash", "--"].concat(paths));
    }

    function openTrash() {
        Quickshell.execDetached(["sh", "-c", 'gio open trash:/// 2>/dev/null || xdg-open "$1"', "loft-dock", trash?.path || `${root.dataHome}/Trash/files`]);
    }

    // Icon candidates for a listed file (AppIcon.sources): its thumbnail,
    // its MIME icon, the generic one for its kind, then a glyph.
    function fileIcons(item, thumbs) {
        const out = [];
        if (thumbs !== false && item.thumb)
            out.push("file://" + item.thumb);
        for (const n of [item.icon, item.generic, item.dir ? "folder" : "text-x-generic", "unknown"]) {
            const p = n ? Quickshell.iconPath(n, true) : "";
            if (p && !out.includes(p))
                out.push(p);
        }
        out.push("");
        return out;
    }

    // A docked folder's own icon (Display as Folder).
    function folderIcons(spec) {
        const special = { "xdg:DOWNLOAD": "folder-download", "xdg:DOCUMENTS": "folder-documents", "xdg:PICTURES": "folder-pictures", "xdg:MUSIC": "folder-music", "xdg:VIDEOS": "folder-videos", "xdg:DESKTOP": "user-desktop" };
        const out = [];
        for (const n of [special[spec], "folder"]) {
            const p = n ? Quickshell.iconPath(n, true) : "";
            if (p && !out.includes(p))
                out.push(p);
        }
        out.push("");
        return out;
    }

    // ── Opening things ───────────────────────────────────────────────────
    function openFile(path) {
        Quickshell.execDetached(["xdg-open", path]);
    }

    // Open `path` with the app (its desktop entry); else the default app.
    function openWith(appId, path) {
        const e = Apps.entry(appId);
        if (e)
            Quickshell.execDetached(["sh", "-c", 'loft dock open "$1" "$2" >/dev/null 2>&1 || xdg-open "$2"', "loft-dock", e.id, path]);
        else
            openFile(path);
    }

    function showInFiles(pathOrId) {
        Quickshell.execDetached(["loft", "dock", "show", pathOrId]);
    }

    // Which stack popup is open: { screen, index, x, y, edge } or null.
    property var openStack: null

    Component.onCompleted: {
        refreshRecents();
        loginList.running = true;
        autostartRun.running = true;
    }
}
