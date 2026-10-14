pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// Which bar menu is open, the app menu's contents, and the window commands
// behind it.
//
// Titles are numbered: 0 = the app menu (bold app name), 1… = the focused
// app's global menus (AppMenu.titles). The open menu cascades: `path[i]` is
// the highlighted item key in panel i, and `depth` panels are shown.
//
// Items share one shape for both sources: { key, label, enabled, separator,
// toggle ("check"|"radio"), checked, shortcut ([[mods…, key]]), submenu,
// children, run() }. Global items come from the daemon (numeric `id`, no
// `run`; activated through AppMenu).
Singleton {
    id: root

    property bool open: false
    property string screen: ""
    property int current: -1
    property var path: []
    property int depth: 0
    // "menu" | "about" | "confirm" | "extra" (a status item's panel)
    property string mode: "menu"
    // The open status item (mode "extra"): control id, the bar item it
    // hangs from, and ⌥ details.
    property string extra: ""
    property var anchor: null
    property bool details: false
    // Per screen: the status items with panels, left to right
    // ([{ id, item }]), for hover-switching and arrow keys.
    property var extraItems: ({})
    // The focused window when the menu opened (focus moves to the menu).
    property var target: null
    // Quit waiting for confirmation: { window, count }.
    property var pendingQuit: null
    // Hidden windows: [{ id, workspace, appId }], restored by Show All.
    property var hidden: []
    // A context menu (the dock's): { items: () => [...], x, y, edge } —
    // the point (screen coordinates) on the edge of what was clicked, and
    // which screen edge that sits on (bottom/left/right): the menu opens
    // away from it. `current` is -2 while it's open.
    property var context: null
    // Its items, built once on open (and on refreshContext()): rebuilding
    // them on every highlight would recreate the rows under the pointer.
    property var contextItems: []
    // Alt held while a menu is open (Quit → Force Quit, like Option on macOS).
    property bool altHeld: false
    // A generic confirmation card: { title, text, button, icon, run }.
    property var pendingAsk: null

    readonly property bool appMenuOn: Features.on("appMenu")
    readonly property int firstTitle: appMenuOn ? 0 : 1
    // Global titles that fit in each screen's bar (MenuBarTitles reports
    // them); the rest go under a "»" title right after.
    property var fits: ({})
    readonly property var window: open ? target : AppMenu.activeWindow

    onOpenChanged: AppMenu.frozen = open

    function fitOn(screenName) {
        const f = fits[screenName];
        return f === undefined ? AppMenu.titles.length : Math.min(f, AppMenu.titles.length);
    }

    function setFit(screenName, n) {
        if (fits[screenName] === n)
            return;
        const m = Object.assign({}, fits);
        m[screenName] = n;
        fits = m;
    }

    function titleCountOn(screenName) {
        const f = fitOn(screenName);
        return 1 + f + (f < AppMenu.titles.length ? 1 : 0);
    }

    function isOverflow(screenName, index) {
        return index === 1 + fitOn(screenName) && fitOn(screenName) < AppMenu.titles.length;
    }

    // ── Opening and closing ──────────────────────────────────────────────
    function openTitle(screenName, index) {
        if (index < firstTitle || index >= titleCountOn(screenName))
            return;
        context = null;
        if (!open)
            target = AppMenu.activeWindow;
        if (open && current !== index)
            notifyClosed(current);
        screen = screenName;
        current = index;
        path = [];
        depth = 1;
        mode = "menu";
        extra = "";
        anchor = null;
        open = true;
        notifyOpened(index);
        if (index === 0 && (NiriSettings.bindsData.binds ?? []).length === 0)
            NiriSettings.refreshBinds();
    }

    function toggleTitle(screenName, index) {
        if (open && current === index && screen === screenName && mode === "menu")
            close();
        else
            openTitle(screenName, index);
    }

    // Hovering another title while a menu is open switches to it (macOS).
    function hoverTitle(screenName, index) {
        if (context)
            return;
        if (open && (mode === "menu" || mode === "extra") && screen === screenName && (mode === "extra" || current !== index))
            openTitle(screenName, index);
    }

    // ── Status items (extras) ────────────────────────────────────────────
    function setExtraItems(screenName, list) {
        const m = Object.assign({}, extraItems);
        m[screenName] = list;
        extraItems = m;
    }

    function anchorOf(screenName, id) {
        const l = extraItems[screenName] ?? [];
        return (l.find(e => e.id === id) ?? l.find(e => e.id === "overflow"))?.item ?? null;
    }

    function openExtra(screenName, id, anchorItem, withDetails) {
        if (open && mode === "menu")
            notifyClosed(current);
        context = null;
        if (!open)
            target = AppMenu.activeWindow;
        screen = screenName;
        current = -1;
        path = [];
        depth = 0;
        extra = id;
        anchor = anchorItem ?? anchorOf(screenName, id);
        details = !!withDetails;
        mode = "extra";
        Nav.item = null;
        open = true;
    }

    function toggleExtra(screenName, id, anchorItem, withDetails) {
        if (open && mode === "extra" && extra === id && screen === screenName && details === !!withDetails)
            close();
        else
            openExtra(screenName, id, anchorItem, withDetails);
    }

    // Hovering another status item (or a title) while a menu is open
    // switches to it, as on macOS.
    function hoverExtra(screenName, id, anchorItem) {
        if (context)
            return;
        if (open && (mode === "menu" || mode === "extra") && screen === screenName && !(mode === "extra" && extra === id))
            openExtra(screenName, id, anchorItem, false);
    }

    function stepExtra(delta) {
        const l = (extraItems[screen] ?? []).filter(e => e.item && e.item.visible);
        const i = l.findIndex(e => e.id === extra);
        const j = i + delta;
        if (j < 0 && titleCountOn(screen) > firstTitle) {
            // Left past the first status item: the last menu title.
            openTitle(screen, titleCountOn(screen) - 1);
            return;
        }
        if (l.length === 0)
            return;
        const e = l[(j + l.length) % l.length];
        openExtra(screen, e.id, e.item, false);
    }

    function extraKey(event) {
        switch (event.key) {
        case Qt.Key_Escape:
            if (!(Nav.root && typeof Nav.root.back === "function" && Nav.root.back()))
                close();
            break;
        case Qt.Key_Down:
            Nav.step(1);
            break;
        case Qt.Key_Up:
            Nav.step(-1);
            break;
        case Qt.Key_Left:
            stepExtra(-1);
            break;
        case Qt.Key_Right:
            stepExtra(1);
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            Nav.activate();
            break;
        default:
            if (event.text && event.text.length === 1 && /\S/.test(event.text))
                Nav.typeSelect(event.text);
        }
    }

    function step(delta) {
        if (context)
            return;
        const n = titleCountOn(screen) - firstTitle;
        // Right past the last title (or left past the first): status items.
        const extras = (extraItems[screen] ?? []).filter(e => e.item && e.item.visible);
        if (extras.length > 0 && ((delta > 0 && current === titleCountOn(screen) - 1) || (delta < 0 && current === firstTitle))) {
            const e = delta > 0 ? extras[0] : extras[extras.length - 1];
            openExtra(screen, e.id, e.item, false);
            return;
        }
        if (n <= 1)
            return;
        const next = firstTitle + ((current - firstTitle + delta) % n + n) % n;
        openTitle(screen, next);
        // Keyboard: highlight the first item.
        const items = itemsAt(0);
        const first = nextSelectable(items, -1, 1);
        if (first >= 0)
            path = [keyOf(items[first])];
    }

    function close() {
        if (!open)
            return;
        notifyClosed(current);
        open = false;
        current = -1;
        depth = 0;
        path = [];
        mode = "menu";
        extra = "";
        anchor = null;
        details = false;
        Nav.item = null;
        pendingQuit = null;
        pendingAsk = null;
        context = null;
        contextItems = [];
        altHeld = false;
    }

    // A context menu at a point (screen coordinates) of `screenName`, e.g.
    // the dock's: `items` is a function returning the top level, built on
    // open and again by refreshContext() (Alt). `alt`: Alt was held when it
    // opened.
    function openContext(screenName, x, y, edge, items, alt) {
        if (open)
            close();
        target = AppMenu.activeWindow;
        context = { items: items, x: x, y: y, edge: edge ?? "bottom" };
        screen = screenName;
        current = -2;
        path = [];
        depth = 1;
        mode = "menu";
        altHeld = alt === true;
        contextItems = items();
        open = true;
    }

    function refreshContext() {
        if (context)
            contextItems = context.items();
    }

    // Ask before doing something destructive (the menu's confirm card).
    function ask(screenName, spec) {
        if (open)
            close();
        target = null;
        pendingAsk = spec;
        screen = screenName;
        mode = "confirm";
        depth = 0;
        open = true;
    }

    function notifyOpened(index) {
        const t = index >= 1 && !isOverflow(screen, index) ? AppMenu.titles[index - 1] : null;
        if (t)
            AppMenu.open(t.id);
    }

    function notifyClosed(index) {
        const t = index >= 1 && !isOverflow(screen, index) ? AppMenu.titles[index - 1] : null;
        if (t)
            AppMenu.close(t.id);
    }

    // ── The cascade ──────────────────────────────────────────────────────
    function keyOf(item) {
        return item.key ?? `g${item.id}`;
    }

    function topItems() {
        if (context)
            return contextItems;
        if (current === 0)
            return appItems(target);
        if (isOverflow(screen, current))
            return AppMenu.titles.slice(fitOn(screen));
        const t = AppMenu.titles[current - 1];
        return t ? (t.children ?? []) : [];
    }

    function itemsAt(level) {
        let items = topItems();
        for (let i = 0; i < level; i++) {
            const parent = items.find(x => keyOf(x) === path[i]);
            items = parent && parent.submenu ? (parent.children ?? []) : [];
        }
        return items;
    }

    function selectable(item) {
        return item && !item.separator && item.enabled !== false;
    }

    function nextSelectable(items, from, delta) {
        for (let n = 1; n <= items.length; n++) {
            const i = ((from + delta * n) % items.length + items.length) % items.length;
            if (selectable(items[i]))
                return i;
        }
        return -1;
    }

    // Highlight `item` in panel `level`; a submenu opens alongside.
    function highlight(level, item, expand) {
        const p = path.slice(0, level);
        p[level] = keyOf(item);
        path = p;
        depth = level + 1 + (expand && item.submenu ? 1 : 0);
        if (expand && item.submenu && item.id !== undefined && item.key === undefined)
            AppMenu.open(item.id);
    }

    function trigger(item) {
        if (!selectable(item))
            return;
        if (item.submenu)
            return;
        close();
        // Let the app get keyboard focus back before it acts (Paste…).
        pending = item;
        runLater.restart();
    }

    property var pending: null
    Timer {
        id: runLater
        interval: 80
        onTriggered: {
            const item = root.pending;
            root.pending = null;
            if (!item)
                return;
            if (item.run)
                item.run();
            else if (item.id !== undefined)
                AppMenu.activate(item.id);
        }
    }

    // ── Keyboard (MenuOverlay forwards keys) ─────────────────────────────
    function key(event) {
        if (event.key === Qt.Key_Alt) {
            altHeld = true;
            refreshContext();
            return;
        }
        if (mode === "extra") {
            extraKey(event);
            return;
        }
        if (mode !== "menu") {
            if (event.key === Qt.Key_Escape)
                close();
            else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && mode === "confirm")
                confirmQuit();
            else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && mode === "about")
                close();
            return;
        }
        const level = Math.max(0, depth - 1);
        // The deepest panel with a highlight drives arrows.
        const items = itemsAt(level);
        const i = items.findIndex(x => keyOf(x) === path[level]);
        const cur = i >= 0 ? items[i] : null;
        switch (event.key) {
        case Qt.Key_Escape:
            if (depth > 1) {
                depth -= 1;
                path = path.slice(0, depth);
            } else
                close();
            break;
        case Qt.Key_Down:
        case Qt.Key_Up:
            {
                const n = nextSelectable(items, i, event.key === Qt.Key_Down ? 1 : -1);
                if (n >= 0)
                    highlight(level, items[n], false);
                break;
            }
        case Qt.Key_Right:
            if (cur && cur.submenu && selectable(cur)) {
                highlight(level, cur, true);
                const sub = itemsAt(level + 1);
                const f = nextSelectable(sub, -1, 1);
                if (f >= 0)
                    path = path.concat([keyOf(sub[f])]);
            } else
                step(1);
            break;
        case Qt.Key_Left:
            if (depth > 1) {
                depth -= 1;
                path = path.slice(0, depth);
            } else
                step(-1);
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            if (cur && cur.submenu) {
                highlight(level, cur, true);
                const sub = itemsAt(level + 1);
                const f = nextSelectable(sub, -1, 1);
                if (f >= 0)
                    path = path.concat([keyOf(sub[f])]);
            } else if (cur)
                trigger(cur);
            break;
        default:
            // Type to select: mnemonic first, then the first letter.
            if (event.text && event.text.length === 1 && /\S/.test(event.text)) {
                const t = event.text.toLowerCase();
                const match = x => selectable(x) && ((x.mnemonic ?? "").toLowerCase() === t || x.label.toLowerCase().startsWith(t));
                let n = -1;
                for (let k = 1; k <= items.length; k++) {
                    const j = ((i < 0 ? -1 : i) + k + items.length) % items.length;
                    if (match(items[j])) {
                        n = j;
                        break;
                    }
                }
                if (n >= 0)
                    highlight(level, items[n], false);
            }
        }
    }

    function keyReleased(event) {
        if (event.key === Qt.Key_Alt) {
            altHeld = false;
            refreshContext();
        }
    }

    // ── The app menu ─────────────────────────────────────────────────────
    function sep(key) {
        return { key: key, separator: true, label: "", enabled: true };
    }

    // niri's bind for an action (no args), as a shortcut chord.
    function niriShortcut(action, args) {
        const binds = NiriSettings.bindsData.binds ?? [];
        const b = binds.find(x => x.action === action && !x.shadowed && JSON.stringify(x.args ?? []) === JSON.stringify(args ?? []));
        if (!b)
            return [];
        const names = { Mod: "Super", Super: "Super", Ctrl: "Control", Control: "Control", Alt: "Alt", Shift: "Shift" };
        return [(b.modifiers ?? []).map(m => names[m] ?? m).concat([b.trigger.length === 1 ? b.trigger.toUpperCase() : b.trigger])];
    }

    function appItems(w) {
        if (!w)
            return desktopItems();
        const own = Apps.own[w.app_id] !== undefined;
        const name = Apps.name(w.app_id);
        const entry = own ? null : Apps.entry(w.app_id);
        const items = [];
        items.push({ key: "about", label: `About ${name}`, enabled: true, run: () => root.showAbout(w) });

        if (AppMenu.pref("desktopActions") && entry) {
            items.push(sep("s-new"));
            const actions = entry.actions ?? [];
            // The app's own "new window" action, if it has one, beats relaunching.
            const isNew = a => a.id === "new-window" || /^new window$/i.test(a.name);
            const newAction = actions.find(isNew);
            items.push({ key: "new", label: "New Window", enabled: true, run: () => newAction ? newAction.execute() : entry.execute() });
            for (let i = 0; i < actions.length; i++) {
                const a = actions[i];
                if (a !== newAction)
                    items.push({ key: `action-${i}`, label: a.name, enabled: true, run: () => a.execute() });
            }
        }

        if (AppMenu.pref("moveCommands")) {
            items.push(sep("s-move"));
            items.push({ key: "workspace", label: "Move to Workspace", enabled: true, submenu: true, children: workspaceItems(w) });
            const displays = displayItems(w);
            items.push({ key: "display", label: "Move to Display", enabled: displays.length > 0, submenu: displays.length > 0, children: displays });
        }

        if (AppMenu.pref("windowCommands")) {
            items.push(sep("s-window"));
            items.push({ key: "float", label: w.is_floating ? "Tile Window" : "Float Window", enabled: true, shortcut: niriShortcut("toggle-window-floating"), run: () => Niri.action("ToggleWindowFloating", { id: w.id }) });
            items.push({ key: "fullscreen", label: "Toggle Full Screen", enabled: true, shortcut: niriShortcut("fullscreen-window"), run: () => Niri.action("FullscreenWindow", { id: w.id }) });
            items.push({ key: "maximize", label: "Maximize Column", enabled: !w.is_floating, shortcut: niriShortcut("maximize-column"), run: () => {
                    Niri.focusWindow(w.id);
                    Niri.action("MaximizeColumn");
                } });
            items.push({ key: "center", label: "Center", enabled: true, shortcut: niriShortcut("center-column"), run: () => Niri.action("CenterWindow", { id: w.id }) });
        }

        if (AppMenu.pref("hideCommands")) {
            items.push(sep("s-hide"));
            items.push({ key: "hide", label: `Hide ${name}`, enabled: true, run: () => root.hideApp(w.app_id) });
            const others = Niri.windows.filter(x => x.app_id !== w.app_id && x.workspace_id === w.workspace_id);
            items.push({ key: "hide-others", label: "Hide Others", enabled: others.length > 0, run: () => root.hideOthers(w) });
            items.push({ key: "show-all", label: "Show All", enabled: hidden.length > 0, run: () => root.showAll() });
        }

        items.push(sep("s-quit"));
        items.push({ key: "close", label: "Close Window", enabled: true, shortcut: niriShortcut("close-window"), run: () => Niri.action("CloseWindow", { id: w.id }) });
        items.push({ key: "quit", label: own ? `Close ${name}` : `Quit ${name}`, enabled: true, run: () => root.quit(w) });
        return items;
    }

    function desktopItems() {
        return [
            { key: "about", label: "About loft", enabled: true, run: () => root.showAbout(null) },
            sep("s1"),
            { key: "settings", label: "Settings…", enabled: true, shortcut: [["Super", ","]], run: () => Panels.settingsOpen = true },
            { key: "overview", label: "Overview", enabled: true, shortcut: niriShortcut("toggle-overview"), run: () => Niri.toggleOverview() },
            sep("s2"),
            { key: "show-all", label: "Show All", enabled: hidden.length > 0, run: () => root.showAll() }
        ];
    }

    function wsLabel(ws) {
        return ws.name ? `${ws.idx}  ${ws.name}` : `Workspace ${ws.idx}`;
    }

    function workspaceItems(w) {
        const here = Niri.workspaces.find(x => x.id === w.workspace_id);
        const out = here?.output ?? "";
        const outputs = [...new Set(Niri.workspaces.map(x => x.output ?? ""))];
        const items = [];
        for (const o of outputs) {
            if (outputs.length > 1)
                items.push({ key: `h-${o}`, label: o, enabled: false });
            for (const ws of Niri.workspacesOn(o)) {
                if (isParking(ws))
                    continue;
                items.push({
                    key: `ws-${ws.id}`,
                    label: wsLabel(ws),
                    enabled: true,
                    toggle: "radio",
                    checked: ws.id === w.workspace_id,
                    run: () => Niri.action("MoveWindowToWorkspace", { window_id: w.id, reference: { Id: ws.id }, focus: true })
                });
            }
            if (outputs.length > 1 && o !== outputs[outputs.length - 1])
                items.push(sep(`s-${o}`));
        }
        return items;
    }

    function displayItems(w) {
        const here = Niri.workspaces.find(x => x.id === w.workspace_id)?.output ?? "";
        const outputs = [...new Set(Niri.workspaces.map(x => x.output ?? ""))].filter(o => o !== "");
        if (outputs.length < 2)
            return [];
        return outputs.map(o => ({
                    key: `out-${o}`,
                    label: o,
                    enabled: o !== here,
                    toggle: "radio",
                    checked: o === here,
                    run: () => Niri.action("MoveWindowToMonitor", { id: w.id, output: o })
                }));
    }

    // ── Hide: niri has no minimize, so windows park on a named workspace
    // at the bottom of their output ("hidden-<output>"), and Show All
    // brings them back. The parking workspace is unnamed again once empty.
    function parkingName(output) {
        return `hidden-${output}`;
    }

    function isParking(ws) {
        return (ws.name ?? "").startsWith("hidden-");
    }

    function hideWindows(windows) {
        const moved = [];
        for (const x of windows) {
            const ws = Niri.workspaces.find(s => s.id === x.workspace_id);
            if (!ws || isParking(ws))
                continue;
            const name = parkingName(ws.output ?? "");
            let park = Niri.workspaces.find(s => s.name === name);
            if (!park) {
                // niri keeps an empty workspace last on each output: claim it.
                const last = Niri.workspacesOn(ws.output).slice(-1)[0];
                if (!last || last.id === ws.id)
                    continue;
                Niri.action("SetWorkspaceName", { name: name, workspace: { Id: last.id } });
                park = last;
            }
            Niri.action("MoveWindowToWorkspace", { window_id: x.id, reference: { Id: park.id }, focus: false });
            moved.push({ id: x.id, workspace: x.workspace_id, appId: x.app_id });
        }
        hidden = hidden.filter(h => !moved.some(m => m.id === h.id)).concat(moved);
    }

    function hideApp(appId) {
        hideWindows(Niri.windows.filter(x => x.app_id === appId));
    }

    function hideOthers(w) {
        hideWindows(Niri.windows.filter(x => x.app_id !== w.app_id && x.workspace_id === w.workspace_id));
    }

    function showAll() {
        for (const h of hidden) {
            if (!Niri.windowMap[h.id])
                continue;
            const back = Niri.workspaceMap[h.workspace] ? { Id: h.workspace } : { Id: Niri.focusedWorkspace?.id ?? 0 };
            Niri.action("MoveWindowToWorkspace", { window_id: h.id, reference: back, focus: false });
        }
        hidden = [];
        for (const ws of Niri.workspaces)
            if (isParking(ws))
                Niri.action("UnsetWorkspaceName", { reference: { Id: ws.id } });
    }

    // ── Quit: close every window of the process; if it outlives them,
    // SIGTERM after forceQuitDelay (only when the pid is this app's alone).
    function quit(w) {
        const count = Niri.windows.filter(x => x.pid && x.pid === w.pid).length;
        if (count > 1 && AppMenu.pref("confirmQuit")) {
            target = w;
            pendingQuit = { window: w, count: count };
            screen = Niri.workspaces.find(x => x.id === w.workspace_id)?.output ?? screen;
            mode = "confirm";
            depth = 0;
            open = true;
            return;
        }
        doQuit(w);
    }

    function confirmQuit() {
        const q = pendingQuit;
        const a = pendingAsk;
        close();
        if (a)
            a.run();
        else if (q && q.appId)
            doQuitApp(q.appId);
        else if (q)
            doQuit(q.window);
    }

    // Quit an app (the dock): every window with its app id, whichever
    // process owns it; confirms when several are open.
    function quitApp(appId) {
        const ws = Niri.windows.filter(x => x.app_id === appId);
        if (ws.length === 0)
            return;
        if (ws.length > 1 && AppMenu.pref("confirmQuit")) {
            target = ws[0];
            pendingQuit = { window: ws[0], count: ws.length, appId: appId };
            screen = Niri.workspaces.find(x => x.id === ws[0].workspace_id)?.output ?? screen;
            mode = "confirm";
            depth = 0;
            open = true;
            return;
        }
        doQuitApp(appId);
    }

    function doQuitApp(appId) {
        const ws = Niri.windows.filter(x => x.app_id === appId);
        const pids = [];
        for (const w of ws) {
            if (!w.pid)
                Niri.action("CloseWindow", { id: w.id });
            else if (!pids.includes(w.pid)) {
                pids.push(w.pid);
                doQuit(w);
            }
        }
    }

    function doQuit(w) {
        const own = Apps.own[w.app_id] !== undefined;
        const windows = w.pid ? Niri.windows.filter(x => x.pid === w.pid) : [w];
        for (const x of windows)
            Niri.action("CloseWindow", { id: x.id });
        const shared = windows.some(x => x.app_id !== w.app_id);
        const delay = AppMenu.pref("forceQuitDelay");
        if (own || shared || !w.pid || delay <= 0)
            return;
        // Same process (comm unchanged) still alive after the delay → TERM.
        Quickshell.execDetached(["sh", "-c", 'c=$(cat /proc/$1/comm 2>/dev/null) || exit 0; sleep "$2"; [ "$(cat /proc/$1/comm 2>/dev/null)" = "$c" ] && kill -TERM "$1"', "loft-quit", String(w.pid), String(delay)]);
    }

    // ── About ────────────────────────────────────────────────────────────
    function showAbout(w) {
        // trigger() closed the menu; reopen as the About card.
        target = w;
        screen = (w ? Niri.workspaces.find(x => x.id === w.workspace_id)?.output : Niri.focusedWorkspace?.output) ?? screen;
        mode = "about";
        depth = 0;
        open = true;
    }

    // Status items: open one on the focused output (no arguments: the ipc
    // CLI can't pass them together with --path).
    IpcHandler {
        target: "extras"

        function show(id: string, withDetails: bool): void {
            // The status area lives on one display (Displays.activeName).
            const out = Displays.activeName || (Niri.focusedWorkspace?.output ?? "");
            root.openExtra(out, id, null, withDetails);
        }
        function wifi(): void {
            show("wifi", false);
        }
        function wifiDetails(): void {
            show("wifi", true);
        }
        function bluetooth(): void {
            show("bluetooth", false);
        }
        function bluetoothDetails(): void {
            show("bluetooth", true);
        }
        function sound(): void {
            show("sound", false);
        }
        function soundDetails(): void {
            show("sound", true);
        }
        function nowPlaying(): void {
            show("nowPlaying", false);
        }
        function focus(): void {
            show("focus", false);
        }
        function display(): void {
            show("display", false);
        }
        function battery(): void {
            show("battery", false);
        }
        function clock(): void {
            show("clock", false);
        }
        function camera(): void {
            show("camera", false);
        }
        function inputSource(): void {
            show("inputSource", false);
        }
        function overflow(): void {
            show("overflow", false);
        }
        function details(): void {
            if (root.open && root.mode === "extra")
                root.details = !root.details;
        }
        function close(): void {
            root.close();
        }
        function down(): void {
            root.key({ key: Qt.Key_Down, text: "" });
        }
        function up(): void {
            root.key({ key: Qt.Key_Up, text: "" });
        }
        function left(): void {
            root.key({ key: Qt.Key_Left, text: "" });
        }
        function right(): void {
            root.key({ key: Qt.Key_Right, text: "" });
        }
        function enter(): void {
            root.key({ key: Qt.Key_Return, text: "" });
        }
        function esc(): void {
            root.key({ key: Qt.Key_Escape, text: "" });
        }
    }

    IpcHandler {
        target: "appmenu"

        // Mod+F10: the app menu on the focused output.
        function toggle(): void {
            const out = Niri.focusedWorkspace?.output ?? "";
            if (root.open)
                root.close();
            else {
                root.openTitle(out, root.firstTitle);
                const items = root.itemsAt(0);
                const f = root.nextSelectable(items, -1, 1);
                if (f >= 0)
                    root.path = [root.keyOf(items[f])];
            }
        }

        // The first global menu (File), keyboard-highlighted.
        function global(): void {
            if (AppMenu.titles.length > 0)
                root.openTitle(Niri.focusedWorkspace?.output ?? "", 1);
        }

        function close(): void {
            root.close();
        }

        // Debugging / screenshots: arrow keys without a keyboard.
        function right(): void {
            root.key({ key: Qt.Key_Right, text: "" });
        }
        function left(): void {
            root.key({ key: Qt.Key_Left, text: "" });
        }
        function down(): void {
            root.key({ key: Qt.Key_Down, text: "" });
        }
        function up(): void {
            root.key({ key: Qt.Key_Up, text: "" });
        }
        function enter(): void {
            root.key({ key: Qt.Key_Return, text: "" });
        }
    }
}
