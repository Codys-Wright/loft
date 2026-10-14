pragma Singleton

import QtQuick
import Quickshell
import qs.services
import qs.menubar
import qs.everyday

// The dock's right-click menus, shown by the menu bar's own cascade
// (MenuState.openContext → MenuOverlay/MenuPanel), so they look and behave
// like the app menu: same glass, keyboard, submenus, Hide/Quit logic.
//
//   app      windows (focus) · recent files · New Window + .desktop actions ·
//            Options ▸ (Keep in Dock, Open at Login, Show in Files, Assign
//            To, Move to Desktop / Display) · Show All Windows · Hide ·
//            Hide Others · Quit (Alt: Force Quit)
//   folder   Sort by ▸ · Display as ▸ · View content as ▸ · Open · Remove
//   item     a stack item: Open · Show in Files · Quick Actions ▸ (Media Tools)
//   window   a card in the window preview: Focus · Move to Desktop ▸ /
//            Display ▸ · Hide / Show · Close Window
//   trash    Open · Empty Trash…
//   dock     Magnification · Position ▸ · recent apps · Dock Settings…
Singleton {
    id: root

    function sep(key) {
        return { key: key, separator: true, label: "", enabled: true };
    }

    function header(key, label) {
        return { key: key, label: label, enabled: false, header: true };
    }

    function radio(key, label, checked, run) {
        return { key: key, label: label, enabled: true, toggle: "radio", checked: checked, run: run };
    }

    function check(key, label, checked, run) {
        return { key: key, label: label, enabled: true, toggle: "check", checked: checked, run: run };
    }

    function shorten(s, n) {
        return s.length > n ? s.slice(0, n - 1) + "…" : s;
    }

    // ── Opening ──────────────────────────────────────────────────────────
    function openApp(screen, x, y, edge, appId, section, alt) {
        MenuState.openContext(screen, x, y, edge, () => root.appItems(appId, section, screen), alt);
    }

    function openFolder(screen, x, y, edge, index) {
        MenuState.openContext(screen, x, y, edge, () => root.folderItems(index, screen));
    }

    function openTrash(screen, x, y, edge) {
        MenuState.openContext(screen, x, y, edge, () => root.trashItems(screen));
    }

    function openDock(screen, x, y, edge) {
        MenuState.openContext(screen.name, x, y, edge, () => root.dockItems(screen));
    }

    // ── Window actions ───────────────────────────────────────────────────
    function isParked(w) {
        const ws = Niri.workspaceMap[w.workspace_id];
        return ws ? MenuState.isParking(ws) : false;
    }

    // Focus a window anywhere; a hidden (parked) one comes back first.
    function focus(w) {
        if (isParked(w)) {
            const h = MenuState.hidden.find(x => x.id === w.id);
            const back = h && Niri.workspaceMap[h.workspace] ? h.workspace : Niri.focusedWorkspace?.id;
            if (back !== undefined)
                Niri.action("MoveWindowToWorkspace", { window_id: w.id, reference: { Id: back }, focus: false });
            MenuState.hidden = MenuState.hidden.filter(x => x.id !== w.id);
        }
        Niri.focusWindow(w.id);
    }

    // Bring back every hidden (parked) window of the app; true if any.
    function unhideApp(appId) {
        const parked = DockData.windowsOf(appId).filter(w => isParked(w));
        for (const w of parked) {
            const h = MenuState.hidden.find(x => x.id === w.id);
            const back = h && Niri.workspaceMap[h.workspace] ? h.workspace : Niri.focusedWorkspace?.id;
            if (back !== undefined)
                Niri.action("MoveWindowToWorkspace", { window_id: w.id, reference: { Id: back }, focus: false });
        }
        if (parked.length > 0)
            MenuState.hidden = MenuState.hidden.filter(x => !parked.some(w => w.id === x.id));
        return parked.length > 0;
    }

    // Bring one hidden (parked) window back where it was, without focusing it.
    function unhide(w) {
        const h = MenuState.hidden.find(x => x.id === w.id);
        const back = h && Niri.workspaceMap[h.workspace] ? h.workspace : Niri.focusedWorkspace?.id;
        if (back !== undefined)
            Niri.action("MoveWindowToWorkspace", { window_id: w.id, reference: { Id: back }, focus: false });
        MenuState.hidden = MenuState.hidden.filter(x => x.id !== w.id);
    }

    function moveWindow(w, wsId) {
        Niri.action("MoveWindowToWorkspace", { window_id: w.id, reference: { Id: wsId }, focus: false });
        MenuState.hidden = MenuState.hidden.filter(x => x.id !== w.id);
    }

    function moveWindowToOutput(w, output) {
        Niri.action("MoveWindowToMonitor", { id: w.id, output: output });
        MenuState.hidden = MenuState.hidden.filter(x => x.id !== w.id);
    }

    function closeWindow(w) {
        Niri.action("CloseWindow", { id: w.id });
    }

    function newWindow(appId) {
        const e = Apps.entry(appId);
        if (!e) {
            Apps.launch(appId);
            return;
        }
        const actions = e.actions ?? [];
        const a = actions.find(x => x.id === "new-window" || /^new window$/i.test(x.name));
        if (a)
            a.execute();
        else
            e.execute();
    }

    function forceQuit(appId) {
        const pids = [...new Set(DockData.windowsOf(appId).map(w => w.pid).filter(p => p))];
        if (Apps.own[appId] !== undefined || pids.length === 0)
            return;
        Quickshell.execDetached(["kill", "-KILL"].concat(pids.map(String)));
    }

    function moveAll(appId, ref) {
        for (const w of DockData.windowsOf(appId))
            Niri.action("MoveWindowToWorkspace", { window_id: w.id, reference: ref, focus: false });
    }

    function moveAllToOutput(appId, output) {
        for (const w of DockData.windowsOf(appId))
            Niri.action("MoveWindowToMonitor", { id: w.id, output: output });
    }

    // ── The app menu ─────────────────────────────────────────────────────
    function appItems(appId, section, screen) {
        const own = Apps.own[appId] !== undefined;
        const name = Apps.name(appId);
        const entry = own ? null : Apps.entry(appId);
        const windows = DockData.windowsOf(appId);
        const running = windows.length > 0;
        const items = [];

        // Windows, focused one checked (macOS lists them first).
        for (const w of windows) {
            const label = shorten((isParked(w) ? "◇ " : "") + (w.title || name), 56);
            items.push(check(`win-${w.id}`, label, w.is_focused || MenuState.target?.id === w.id, () => root.focus(w)));
        }
        if (windows.length > 0)
            items.push(sep("s-win"));

        // Recent files, opened with this app.
        const recent = own ? [] : DockData.recentFor(appId).slice(0, 8);
        if (recent.length > 0) {
            items.push(header("h-recent", "Recent"));
            recent.forEach((r, i) => items.push({ key: `rec-${i}`, label: shorten(r.name, 48), enabled: true, run: () => DockData.openWith(appId, r.path) }));
            items.push(sep("s-recent"));
        }

        if (!running)
            items.push({ key: "open", label: "Open", enabled: true, run: () => Apps.launch(appId) });
        if (entry) {
            const actions = entry.actions ?? [];
            const isNew = a => a.id === "new-window" || /^new window$/i.test(a.name);
            if (running || actions.some(isNew))
                items.push({ key: "new", label: "New Window", enabled: true, run: () => root.newWindow(appId) });
            actions.forEach((a, i) => {
                if (!isNew(a))
                    items.push({ key: `action-${i}`, label: a.name, enabled: true, run: () => a.execute() });
            });
        }
        items.push(sep("s-new"));

        items.push({ key: "options", label: "Options", enabled: true, submenu: true, children: optionItems(appId, section, screen) });

        if (running) {
            items.push(sep("s-show"));
            items.push({ key: "show-windows", label: "Show All Windows", enabled: true, run: () => {
                    root.focus(windows.find(w => w.is_focused) ?? windows[0]);
                    if (!Niri.overviewOpen)
                        Niri.toggleOverview();
                } });
            if (Features.on("arrange")) {
                const aw = windows.find(w => w.is_focused) ?? windows.find(w => !isParked(w)) ?? windows[0];
                items.push({ key: "arrange", label: "Arrange", enabled: true, submenu: true, children: Arrange.items(aw) });
            }
            items.push({ key: "hide", label: "Hide", enabled: windows.some(w => !isParked(w)), run: () => MenuState.hideApp(appId) });
            const first = windows.find(w => !isParked(w)) ?? windows[0];
            const others = Niri.windows.filter(x => !DockData.sameApp(x.app_id, appId) && x.workspace_id === first.workspace_id);
            items.push({ key: "hide-others", label: "Hide Others", enabled: others.length > 0, run: () => MenuState.hideOthers(first) });
            if (MenuState.hidden.length > 0)
                items.push({ key: "show-all", label: "Show All", enabled: true, run: () => MenuState.showAll() });
            items.push(sep("s-quit"));
            if (MenuState.altHeld && !own)
                items.push({ key: "force-quit", label: "Force Quit", enabled: true, run: () => root.forceQuit(appId) });
            else
                items.push({ key: "quit", label: own ? "Close" : "Quit", enabled: true, run: () => MenuState.quitApp(appId) });
        } else if (section !== "running") {
            items.push(sep("s-remove"));
            items.push({ key: "remove", label: "Remove from Dock", enabled: true, run: () => {
                    if (section === "recent")
                        AppUsage.forget(appId);
                    else
                        DockData.setPinned(appId, false);
                } });
        }
        return items;
    }

    function optionItems(appId, section, screen) {
        const own = Apps.own[appId] !== undefined;
        const entry = own ? null : Apps.entry(appId);
        const windows = DockData.windowsOf(appId);
        const pinned = DockData.isPinned(appId);
        const items = [];
        items.push(check("keep", "Keep in Dock", pinned, () => DockData.setPinned(appId, !pinned)));
        if (entry) {
            const login = DockData.openAtLogin(appId);
            items.push(check("login", "Open at Login", login, () => DockData.setOpenAtLogin(appId, !login)));
            items.push({ key: "show-files", label: "Show in Files", enabled: true, run: () => DockData.showInFiles(entry.id) });
        }
        // Quit on close / hold ⌘Q (Settings → Everyday).
        if (!own && (Features.on("quitOnClose") || Features.on("quitProtection"))) {
            items.push(sep("s-quit-opts"));
            if (Features.on("quitOnClose"))
                items.push(QuitOnClose.menuItem(appId));
            if (Features.on("quitProtection"))
                items.push(QuitGuard.menuItem(appId));
        }

        // Assign To: a niri window rule (open-on-workspace).
        const assigned = DockData.assignedTo(appId);
        const here = Niri.workspaces.find(w => w.output === screen && w.is_active && !MenuState.isParking(w)) ?? Niri.focusedWorkspace;
        items.push(sep("s-assign"));
        items.push(header("h-assign", "Assign To"));
        items.push({ key: "assign-all", label: "All Desktops", enabled: false, toggle: "radio", checked: false });
        const hereName = here ? DockData.wsName(here) : "";
        items.push(radio("assign-here", here ? `This Desktop (${hereName})` : "This Desktop", assigned !== "" && assigned === hereName, () => DockData.assign(appId, here)));
        if (assigned !== "" && assigned !== hereName)
            items.push(radio("assign-other", `Desktop “${assigned}”`, true, () => {}));
        items.push(radio("assign-none", "None", assigned === "", () => DockData.assign(appId, null)));

        if (windows.length > 0) {
            items.push(sep("s-move"));
            items.push({ key: "move-ws", label: "Move to Desktop", enabled: true, submenu: true, children: moveWorkspaceItems(appId, windows) });
            const outputs = [...new Set(Niri.workspaces.map(x => x.output ?? ""))].filter(o => o !== "");
            items.push({ key: "move-out", label: "Move to Display", enabled: outputs.length > 1, submenu: outputs.length > 1, children: outputs.map(o => radio(`out-${o}`, o, windows.every(w => Niri.workspaceMap[w.workspace_id]?.output === o), () => root.moveAllToOutput(appId, o))) });
        }
        return items;
    }

    function moveWorkspaceItems(appId, windows) {
        const outputs = [...new Set(Niri.workspaces.map(x => x.output ?? ""))];
        const items = [];
        for (const o of outputs) {
            if (outputs.length > 1)
                items.push(header(`h-${o}`, o));
            for (const ws of Niri.workspacesOn(o)) {
                if (MenuState.isParking(ws))
                    continue;
                items.push(radio(`ws-${ws.id}`, MenuState.wsLabel(ws), windows.every(w => w.workspace_id === ws.id), () => root.moveAll(appId, { Id: ws.id })));
            }
            if (outputs.length > 1 && o !== outputs[outputs.length - 1])
                items.push(sep(`s-${o}`));
        }
        return items;
    }

    // ── One window (a card in the dock preview) ──────────────────────────
    function openWindow(screen, x, y, edge, id) {
        MenuState.openContext(screen, x, y, edge, () => root.windowItems(id));
    }

    function windowItems(id) {
        const w = Niri.windowMap[id];
        if (!w)
            return [];
        const parked = isParked(w);
        const outputs = [...new Set(Niri.workspaces.map(x => x.output ?? ""))].filter(o => o !== "");
        const here = Niri.workspaceMap[w.workspace_id]?.output ?? "";
        const desktops = [];
        for (const o of outputs) {
            if (outputs.length > 1)
                desktops.push(header(`h-${o}`, o));
            for (const ws of Niri.workspacesOn(o))
                if (!MenuState.isParking(ws))
                    desktops.push(radio(`ws-${ws.id}`, MenuState.wsLabel(ws), ws.id === w.workspace_id, () => root.moveWindow(w, ws.id)));
            if (outputs.length > 1 && o !== outputs[outputs.length - 1])
                desktops.push(sep(`s-${o}`));
        }
        return [
            header("h-title", shorten(w.title || Apps.name(w.app_id), 48)),
            { key: "focus", label: parked ? "Show and Focus" : "Focus", enabled: true, run: () => root.focus(w) },
            sep("s-move"),
            { key: "move-ws", label: "Move to Desktop", enabled: desktops.length > 0, submenu: true, children: desktops },
            { key: "move-out", label: "Move to Display", enabled: outputs.length > 1, submenu: outputs.length > 1, children: outputs.map(o => radio(`out-${o}`, o, !parked && o === here, () => root.moveWindowToOutput(w, o))) },
            sep("s-hide"),
            parked ? { key: "show", label: "Show", enabled: true, run: () => root.unhide(w) } : { key: "hide", label: "Hide", enabled: true, run: () => MenuState.hideWindows([w]) },
            { key: "close", label: "Close Window", enabled: true, run: () => root.closeWindow(w) }
        ];
    }

    // ── Folder stacks ────────────────────────────────────────────────────
    function folderItems(index, screen) {
        const scr = Quickshell.screens.find(x => x.name === screen);
        const f = scr ? DockData.profileFor(scr).folders[index] : Settings.dock.folders[index];
        if (!f)
            return [];
        const src = DockData.folder(f.path);
        const name = src?.listing?.name || f.path;
        const set = patch => () => DockData.setFolder(index, patch);
        const sort = f.sort ?? "added";
        const display = f.display ?? "stack";
        const view = f.view ?? "auto";
        return [
            { key: "sort", label: "Sort by", enabled: true, submenu: true, children: [radio("sort-name", "Name", sort === "name", set({ sort: "name" })), radio("sort-added", "Date Added", sort === "added", set({ sort: "added" })), radio("sort-modified", "Date Modified", sort === "modified", set({ sort: "modified" })), radio("sort-kind", "Kind", sort === "kind", set({ sort: "kind" }))] },
            { key: "display", label: "Display as", enabled: true, submenu: true, children: [radio("disp-folder", "Folder", display === "folder", set({ display: "folder" })), radio("disp-stack", "Stack", display === "stack", set({ display: "stack" }))] },
            { key: "view", label: "View content as", enabled: true, submenu: true, children: [radio("view-fan", "Fan", view === "fan", set({ view: "fan" })), radio("view-grid", "Grid", view === "grid", set({ view: "grid" })), radio("view-list", "List", view === "list", set({ view: "list" })), radio("view-auto", "Automatic", view === "auto", set({ view: "auto" }))] },
            sep("s-open"),
            { key: "open", label: `Open “${name}”`, enabled: true, run: () => DockData.openFile(src?.path || f.path) },
            sep("s-remove"),
            { key: "remove", label: "Remove from Dock", enabled: true, run: () => DockData.removeFolder(index) }
        ];
    }

    // ── An item in a stack (right-click in the popup) ────────────────────
    function openStackItem(screen, x, y, path) {
        MenuState.openContext(screen, x, y, "bottom", () => root.stackItemItems(path));
    }

    function stackItemItems(path) {
        const name = path.split("/").pop();
        const items = [
            { key: "open", label: "Open", enabled: true, run: () => DockData.openFile(path) },
            { key: "show", label: "Show in Files", enabled: true, run: () => DockData.showInFiles(path) }
        ];
        // Quick Actions ▸ — Media Tools (Utilities window) for videos, images, audio.
        const ext = (name.match(/\.([^.]+)$/)?.[1] ?? "").toLowerCase();
        const kind = /^(mp4|mkv|mov|webm|avi|m4v|mpe?g|wmv|flv|ts|3gp|ogv)$/.test(ext) ? "video" : /^(png|jpe?g|webp|avif|gif|bmp|tiff?|heic|heif|jxl)$/.test(ext) ? "image" : /^(mp3|m4a|aac|flac|wav|ogg|opus|aiff?)$/.test(ext) ? "audio" : "";
        if (Features.on("mediaTools") && kind !== "") {
            const acts = MediaTools.ops.filter(o => o.kinds.includes(kind)).map(o => ({ key: "qa-" + o.id, label: o.label + "…", enabled: true, run: () => MediaTools.openWith([path], o.id) }));
            items.push(sep("s-qa"), { key: "quick", label: "Quick Actions", enabled: true, submenu: true, children: acts });
        }
        return items;
    }

    // ── Trash ────────────────────────────────────────────────────────────
    function trashItems(screen) {
        return [
            { key: "open", label: "Open", enabled: true, run: () => DockData.openTrash() },
            sep("s-empty"),
            { key: "empty", label: "Empty Trash…", enabled: DockData.trashFull, run: () => MenuState.ask(screen, {
                        title: "Empty the Trash?",
                        text: `${DockData.trash?.count ?? 0} item${(DockData.trash?.count ?? 0) === 1 ? "" : "s"} will be erased permanently. You can't undo this.`,
                        button: "Empty Trash",
                        icon: "󰩹",
                        run: () => DockData.emptyTrash()
                    }) }
        ];
    }

    // ── The dock itself (right-click on the shelf) ───────────────────────
    // `screen`: the dock's; hiding and position are per display.
    function dockItems(screen) {
        const prefs = DockData.displayPrefs(screen);
        const pos = prefs.position;
        const mag = Settings.dock.magnification > 1.001;
        const setPos = p => () => DockData.setDisplayPref(screen, "position", p);
        return [
            { key: "autohide", label: "Automatically Hide", enabled: true, submenu: true, children: [radio("hide-never", "Never", prefs.autoHide === "never", () => DockData.setDisplayPref(screen, "autoHide", "never")), radio("hide-windows", "When Windows Are Open", prefs.autoHide === "whenWindows", () => DockData.setDisplayPref(screen, "autoHide", "whenWindows")), radio("hide-always", "Always", prefs.autoHide === "always", () => DockData.setDisplayPref(screen, "autoHide", "always"))] },
            check("magnify", "Magnification", mag, () => Settings.dock.magnification = mag ? 1 : 1.5),
            { key: "position", label: "Position on Screen", enabled: true, submenu: true, children: [radio("pos-left", "Left", pos === "left", setPos("left")), radio("pos-bottom", "Bottom", pos === "bottom", setPos("bottom")), radio("pos-right", "Right", pos === "right", setPos("right"))] },
            check("recents", "Show Recent Apps", Features.on("dockRecents"), () => Features.set("dockRecents", !Features.on("dockRecents"))),
            check("bounce", "Animate Opening Apps", Settings.dock.bounce, () => Settings.dock.bounce = !Settings.dock.bounce),
            sep("s-settings"),
            { key: "settings", label: "Dock Settings…", enabled: true, run: () => {
                    Panels.settingsSection = "dock";
                    Panels.settingsOpen = true;
                } }
        ];
    }
}
