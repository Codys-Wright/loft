pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.capture
import qs.menubar
import qs.services

// The desktop's right-click menu: a right-click on the wallpaper (a click
// that lands on no window) opens it at the pointer, on that display. It
// draws with the bar menus' glass panels (menubar/MenuPanel.qml) and keeps
// their item shape ({ key, label, enabled, separator, toggle, checked,
// submenu, children, run() } + icon / swatch / thumb / header).
//
// Its top level is a user-arranged list: `catalog` below in the default
// order, re-ordered and shown / hidden in Settings → Desktop Menu and saved
// as Settings.desktopMenu.items ([{ id, shown }]). Items whose feature
// module is off (Features.on) are left out. Submenus are built when they
// open, so the menu always shows the live theme, wallpaper and settings.
Singleton {
    id: root

    property bool open: false
    property string screen: ""
    // Where it was opened, in the screen's coordinates.
    property real atX: 0
    property real atY: 0
    // The cascade: highlighted key per panel, and panels shown. Each panel's
    // items live in their own property so opening a submenu never rebuilds
    // (and scrolls back) the panels before it.
    property var path: []
    property int depth: 0
    property var items0: []
    property var items1: []
    property var items2: []
    property var items3: []

    // ── The arrangeable top level ────────────────────────────────────────
    // id, label, feature (hidden while that module is off), submenu, icon
    // (only a few common items have one — Golden Gate), hint (Settings).
    readonly property var catalog: [
        { id: "changeWallpaper", label: "Change Wallpaper…", icon: "󰸉", hint: "Settings → Wallpaper" },
        { id: "wallpaper", label: "Wallpaper", submenu: true, hint: "Next, previous, shuffle, suggestions that match the theme" },
        { id: "sep-wallpaper", separator: true },
        { id: "theme", label: "Theme", submenu: true, hint: "Every installed theme, with its palette" },
        { id: "appearance", label: "Appearance", submenu: true, hint: "Light / Dark, Liquid Glass, Reduce Transparency, menu bar background" },
        { id: "sep-appearance", separator: true },
        { id: "displays", label: "Display Settings…", hint: "Settings → Displays" },
        { id: "dock", label: "Dock Settings…", feature: "dock", hint: "Settings → Dock" },
        { id: "controlCenter", label: "Control Center", feature: "controlcenter", hint: "Opens on this display" },
        { id: "notifications", label: "Notification History", hint: "Calendar and recent notifications (the clock's panel)" },
        { id: "sep-panels", separator: true },
        { id: "screenshot", label: "Screenshot", icon: "󰹑", submenu: true, feature: "capture", hint: "Capture selector, screen or area" },
        { id: "terminal", label: "Open Terminal Here", icon: "󰆍", hint: "In ~/Desktop, or your home folder" },
        { id: "sep-tools", separator: true },
        { id: "lock", label: "Lock Screen", hint: "Lock now" },
        { id: "settings", label: "System Settings…", icon: "󰒓", hint: "The Settings app" }
    ]

    function entry(id) {
        return catalog.find(c => c.id === id) ?? null;
    }

    // The arrangement: saved order + shown flags; catalog items the saved
    // list doesn't know (added in a later version) go in after their
    // catalog predecessor.
    readonly property var layout: {
        const saved = (Settings.desktopMenu?.items ?? []).filter(s => entry(s.id) !== null);
        const out = saved.map(s => ({ id: s.id, shown: s.shown !== false }));
        for (let i = 0; i < catalog.length; i++) {
            const c = catalog[i];
            if (out.some(o => o.id === c.id))
                continue;
            let at = 0;
            for (let j = i - 1; j >= 0; j--) {
                const k = out.findIndex(o => o.id === catalog[j].id);
                if (k >= 0) {
                    at = k + 1;
                    break;
                }
            }
            out.splice(at, 0, { id: c.id, shown: true });
        }
        return out;
    }

    function saveLayout(list) {
        const d = Object.assign({}, Settings.desktopMenu ?? {});
        d.items = list.map(o => ({ id: o.id, shown: o.shown }));
        Settings.desktopMenu = d;
    }

    function setShown(id, shown) {
        saveLayout(layout.map(o => o.id === id ? { id: o.id, shown: shown } : o));
    }

    function move(id, delta) {
        const l = layout.slice();
        const i = l.findIndex(o => o.id === id);
        const j = i + delta;
        if (i < 0 || j < 0 || j >= l.length)
            return;
        const t = l[i];
        l[i] = l[j];
        l[j] = t;
        saveLayout(l);
    }

    function resetLayout() {
        const d = Object.assign({}, Settings.desktopMenu ?? {});
        delete d.items;
        Settings.desktopMenu = d;
    }

    // An entry's feature module is off: it isn't in the menu.
    function available(c) {
        return !c.feature || Features.on(c.feature);
    }

    // ── Opening and closing ──────────────────────────────────────────────
    function openAt(screenName, x, y) {
        if (!Features.on("desktopMenu"))
            return;
        screen = screenName;
        atX = x;
        atY = y;
        items1 = [];
        items2 = [];
        items3 = [];
        items0 = topItems();
        path = [];
        depth = 1;
        open = true;
        // Theme list and vibes may be stale (installed / switched elsewhere).
        if (ThemeManager.themes.length === 0)
            ThemeManager.refresh();
    }

    // IPC / keyboard: the middle of the focused display, first item lit.
    function openCentered(screenName) {
        const s = Quickshell.screens.find(x => x.name === screenName) ?? Quickshell.screens[0];
        if (!s)
            return;
        openAt(s.name, s.width / 2 - 120, s.height / 3);
        const f = nextSelectable(items0, -1, 1);
        if (f >= 0)
            path = [keyOf(items0[f])];
    }

    function close() {
        if (!open)
            return;
        open = false;
        depth = 0;
        path = [];
    }

    // ── The cascade ──────────────────────────────────────────────────────
    function keyOf(item) {
        return item.key ?? "";
    }

    function itemsAt(level) {
        return level === 0 ? items0 : level === 1 ? items1 : level === 2 ? items2 : level === 3 ? items3 : [];
    }

    function setItemsAt(level, list) {
        if (level === 1)
            items1 = list;
        else if (level === 2)
            items2 = list;
        else if (level === 3)
            items3 = list;
    }

    function selectable(item) {
        return item && !item.separator && !item.header && item.enabled !== false;
    }

    function nextSelectable(items, from, delta) {
        for (let n = 1; n <= items.length; n++) {
            const i = ((from + delta * n) % items.length + items.length) % items.length;
            if (selectable(items[i]))
                return i;
        }
        return -1;
    }

    // Highlight `item` in panel `level`; with `expand`, its submenu opens
    // alongside (built now, from live state).
    function highlight(level, item, expand) {
        const was = path[level];
        const p = path.slice(0, level);
        p[level] = keyOf(item);
        path = p;
        const sub = expand && item.submenu && level < 3;
        if (sub && (was !== keyOf(item) || depth !== level + 2))
            setItemsAt(level + 1, item.build ? item.build() : (item.children ?? []));
        depth = level + 1 + (sub ? 1 : 0);
    }

    function trigger(item) {
        if (!selectable(item) || item.submenu)
            return;
        close();
        // Let the menu's surface go first (a screenshot mustn't catch it).
        pending = item;
        runLater.interval = item.delay ?? 80;
        runLater.restart();
    }

    property var pending: null
    Timer {
        id: runLater
        interval: 80
        onTriggered: {
            const item = root.pending;
            root.pending = null;
            if (item && item.run)
                item.run();
        }
    }

    // Open a submenu from the keyboard: its first item lit (the checked
    // one in a list like Theme ▸).
    function expandFirst(level, item) {
        highlight(level, item, true);
        const sub = itemsAt(level + 1);
        const c = item.preferChecked ? sub.findIndex(x => x.checked && selectable(x)) : -1;
        const f = c >= 0 ? c : nextSelectable(sub, -1, 1);
        if (f >= 0)
            path = path.concat([keyOf(sub[f])]);
    }

    // ── Keyboard (the overlay forwards keys) ─────────────────────────────
    function key(event) {
        const level = Math.max(0, depth - 1);
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
                const down = event.key === Qt.Key_Down;
                // Nothing lit yet: Down starts at the top, Up at the bottom.
                const n = nextSelectable(items, i >= 0 ? i : down ? -1 : items.length, down ? 1 : -1);
                if (n >= 0)
                    highlight(level, items[n], false);
                break;
            }
        case Qt.Key_Right:
            if (cur && cur.submenu && selectable(cur))
                expandFirst(level, cur);
            break;
        case Qt.Key_Left:
            if (depth > 1) {
                depth -= 1;
                path = path.slice(0, depth);
            }
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            if (cur && cur.submenu)
                expandFirst(level, cur);
            else if (cur)
                trigger(cur);
            break;
        default:
            // Type to select: the first item starting with the letter.
            if (event.text && event.text.length === 1 && /\S/.test(event.text)) {
                const t = event.text.toLowerCase();
                for (let k = 1; k <= items.length; k++) {
                    const j = ((i < 0 ? -1 : i) + k + items.length) % items.length;
                    if (selectable(items[j]) && items[j].label.toLowerCase().startsWith(t)) {
                        highlight(level, items[j], false);
                        break;
                    }
                }
            }
        }
    }

    // ── Items ────────────────────────────────────────────────────────────
    function sep(key) {
        return { key: key, separator: true, label: "", enabled: true };
    }

    function header(key, label) {
        return { key: key, header: true, label: label, enabled: false };
    }

    function settingsPage(section) {
        Panels.settingsSection = section;
        Panels.settingsOpen = true;
    }

    function topItems() {
        const out = [];
        for (const o of layout) {
            const c = entry(o.id);
            if (!o.shown || !available(c))
                continue;
            // No separator first or twice in a row.
            if (c.separator && (out.length === 0 || out[out.length - 1].separator))
                continue;
            out.push(c.separator ? sep(c.id) : build(c));
        }
        if (out.length > 0 && !out[out.length - 1].separator)
            out.push(sep("sep-edit"));
        // Always last, so the menu can always be put back together.
        out.push({ key: "edit", label: "Edit Menu…", enabled: true, run: () => root.settingsPage("desktopmenu") });
        return out;
    }

    function build(c) {
        const it = { key: c.id, label: c.label, icon: c.icon ?? "", enabled: true, submenu: c.submenu === true };
        switch (c.id) {
        case "changeWallpaper":
            it.run = () => root.settingsPage("wallpaper");
            break;
        case "wallpaper":
            it.build = () => root.wallpaperItems();
            break;
        case "theme":
            it.preferChecked = true;
            it.build = () => root.themeItems();
            break;
        case "appearance":
            it.build = () => root.appearanceItems();
            break;
        case "displays":
            it.run = () => root.settingsPage("displays");
            break;
        case "dock":
            it.run = () => root.settingsPage("dock");
            break;
        case "controlCenter":
            {
                const s = root.screen;
                it.run = () => {
                    Panels.controlCenterScreen = s;
                    Panels.controlCenterOpen = true;
                };
                break;
            }
        case "notifications":
            // The clock's panel — calendar + notifications, Notification
            // Center in short — on the display with the status area.
            it.run = () => MenuState.openExtra(Displays.activeName || root.screen, "clock", null, false);
            break;
        case "screenshot":
            it.build = () => root.screenshotItems();
            break;
        case "terminal":
            it.run = () => root.openTerminal();
            break;
        case "lock":
            it.run = () => Vibes.previewLock();
            break;
        case "settings":
            it.run = () => {
                Panels.settingsOpen = true;
            };
            break;
        }
        return it;
    }

    // Wallpaper ▸ — the theme's vibe set.
    // Stills to step through: the theme's collection, or (a theme with one
    // image or none) the closest matches too.
    readonly property var vibeSet: {
        if (Vibes.collection.length > 1)
            return Vibes.collection;
        return Vibes.wallpapers.filter(w => w.kind === "image").slice(0, 24).map(w => w.path);
    }

    function currentWallpaper() {
        return Vibes.wallpaperFor(screen);
    }

    // With several displays a choice from the desktop menu is for the
    // display that was right-clicked (Vibes' per-display choice, by niri
    // identity); with one it is the theme's choice.
    readonly property bool multiDisplay: Quickshell.screens.length > 1

    function ownChoice(screenName) {
        return !!(Vibes.displayChoices[Displays.identity(screenName)] ?? Vibes.displayChoices[screenName]);
    }

    function chooseWallpaper(path) {
        if (multiDisplay)
            Vibes.chooseWallpaperFor(screen, path);
        else
            Vibes.chooseWallpaper(path);
    }

    function stepWallpaper(dir) {
        const set = vibeSet;
        if (set.length === 0)
            return;
        let i = set.indexOf(currentWallpaper());
        if (i < 0)
            i = set.indexOf(Vibes.defaultWallpaper);
        chooseWallpaper(set[((i < 0 ? 0 : i + dir) % set.length + set.length) % set.length]);
    }

    function shuffleWallpaper() {
        const set = vibeSet.filter(p => p !== currentWallpaper());
        if (set.length > 0)
            chooseWallpaper(set[Math.floor(Math.random() * set.length)]);
    }

    function wallpaperName(path) {
        const short = Library.byPath[path]?.short;
        if (short)
            return short;
        const parts = path.split("/");
        const file = parts.pop().replace(/\.[^.]+$/, "");
        // Generic file names ("bg", "Background"): say whose it is.
        const pack = parts.indexOf("Packs") >= 0 ? parts[parts.indexOf("Packs") + 1] : "";
        let nice = /^(bg|background|wallpaper|wall)\d*$/i.test(file) && pack ? prettyTheme(pack).label : file.replace(/[-_]+/g, " ").trim();
        nice = nice.charAt(0).toUpperCase() + nice.slice(1);
        return nice.length > 28 ? nice.slice(0, 27) + "…" : nice;
    }

    function wallpaperItems() {
        const n = vibeSet.length;
        const cur = currentWallpaper();
        const items = [
            { key: "next", label: "Next Wallpaper", enabled: n > 1, run: () => root.stepWallpaper(1) },
            { key: "prev", label: "Previous Wallpaper", enabled: n > 1, run: () => root.stepWallpaper(-1) },
            { key: "shuffle", label: "Shuffle", enabled: n > 1, run: () => root.shuffleWallpaper() }
        ];
        const picks = Vibes.wallpapers.filter(w => w.kind === "image").slice(0, 5);
        if (picks.length === 0 && Vibes.loading) {
            items.push(sep("s-picks"));
            items.push({ key: "loading", label: "Finding wallpapers that match…", enabled: false });
        }
        if (picks.length > 0) {
            items.push(sep("s-picks"));
            items.push(header("h-picks", `Goes with ${prettyTheme(Theme.name).label}` + (multiDisplay ? ` · ${screen}` : "")));
            for (const w of picks) {
                const path = w.path;
                const thumb = Library.byPath[path]?.thumb ?? "";
                items.push({
                    key: `wp-${path}`,
                    label: wallpaperName(path),
                    thumb: Vibes.url(thumb || path),
                    enabled: true,
                    toggle: "radio",
                    checked: path === cur,
                    run: () => root.chooseWallpaper(path)
                });
            }
        }
        items.push(sep("s-browse"));
        if (multiDisplay) {
            // This display has its own; or put this display's on all of them.
            const s = screen;
            items.push({ key: "all", label: "Use on All Displays", enabled: true, run: () => {
                    Vibes.setChoice("displays", {});
                    Vibes.chooseWallpaper(cur);
                } });
            if (ownChoice(s))
                items.push({ key: "follow", label: "Same as Other Displays", enabled: true, run: () => Vibes.chooseWallpaperFor(s, "") });
        }
        if (Vibes.chosenWallpaper !== "" && !(multiDisplay && ownChoice(screen)))
            items.push({ key: "default", label: "Use Theme's Wallpaper", enabled: true, run: () => Vibes.chooseWallpaper("") });
        if (Features.on("wallpaperPicker"))
            items.push({ key: "picker", label: "Wallpaper Picker…", enabled: true, run: () => {
                    Panels.wallpaperPickerOpen = true;
                } });
        items.push({ key: "library", label: "Browse Library…", enabled: true, run: () => root.settingsPage("wallpaper") });
        return items;
    }

    // Theme ▸ — grouped by where the pack came from; the current one checked.
    readonly property var importers: [
        { prefix: "cozytile-", group: "Cozytile" },
        { prefix: "qylock-", group: "Qylock" }
    ]

    // { group, label } for a theme name (importer prefix stripped, words capitalized).
    function prettyTheme(name, path) {
        let group = "Built-in";
        let rest = name;
        const imp = importers.find(x => name.startsWith(x.prefix));
        if (imp) {
            group = imp.group;
            rest = name.slice(imp.prefix.length);
        } else if (path && (path.indexOf("/Packs/") >= 0 || path.startsWith(Quickshell.env("HOME") + "/")))
            group = "Installed";
        const label = rest.split(/[-_ ]+/).filter(w => w !== "").map(w => /^\d/.test(w) ? w : w[0].toUpperCase() + w.slice(1)).join(" ");
        return { group: group, label: label };
    }

    function themeItems() {
        const themes = ThemeManager.themes;
        const items = [];
        if (themes.length === 0)
            items.push({ key: "none", label: ThemeManager.error !== "" ? "Theme list unavailable" : "Loading themes…", enabled: false });
        const groups = ["Built-in", "Installed"].concat(importers.map(x => x.group));
        const rows = themes.map(t => Object.assign({ theme: t }, prettyTheme(t.name, t.path)));
        for (const g of groups) {
            const inGroup = rows.filter(r => r.group === g);
            if (inGroup.length === 0)
                continue;
            if (items.length > 0)
                items.push(sep(`s-${g}`));
            items.push(header(`h-${g}`, g));
            for (const r of inGroup) {
                const t = r.theme;
                const p = t.palette ?? {};
                items.push({
                    key: `theme-${t.name}`,
                    label: r.label,
                    swatch: [p.bg ?? "#000000", p.accent ?? "#ffffff", p.accent2 ?? p.text ?? "#ffffff"],
                    enabled: !ThemeManager.applying,
                    toggle: "radio",
                    checked: t.name === Theme.name,
                    run: () => ThemeManager.apply(t.name)
                });
            }
        }
        items.push(sep("s-more"));
        items.push({ key: "more", label: "More Themes…", enabled: true, run: () => root.settingsPage("appearance") });
        return items;
    }

    // Appearance ▸
    // A pack's other-polarity sibling: "x" ↔ "x-dark" / "x-light" (also -day / -night).
    function baseName(name) {
        return name.replace(/[-_](dark|light|day|night)$/i, "");
    }

    function variant(polarity) {
        const base = baseName(Theme.name);
        return ThemeManager.themes.find(t => t.name !== Theme.name && baseName(t.name) === base && (t.polarity ?? "dark") === polarity) ?? null;
    }

    function glassPreset() {
        const g = Settings.appearance.glass;
        if (g < 0)
            return "default";
        return g <= 0.08 ? "clear" : g >= 0.92 ? "tinted" : "custom";
    }

    function appearanceItems() {
        const items = [];
        const other = variant(Theme.dark ? "light" : "dark");
        if (other) {
            items.push({ key: "light", label: "Light", enabled: true, toggle: "radio", checked: !Theme.dark, run: () => Theme.dark ? ThemeManager.apply(other.name) : null });
            items.push({ key: "dark", label: "Dark", enabled: true, toggle: "radio", checked: Theme.dark, run: () => Theme.dark ? null : ThemeManager.apply(other.name) });
            items.push(sep("s-mode"));
        }
        const preset = glassPreset();
        items.push({ key: "glass", label: "Liquid Glass", enabled: !Theme.reduceTransparency, submenu: true, children: [
                { key: "clear", label: "Clear", enabled: true, toggle: "radio", checked: preset === "clear", run: () => {
                        Settings.appearance.glass = 0;
                    } },
                { key: "default", label: "Default", enabled: true, toggle: "radio", checked: preset === "default", run: () => {
                        Settings.appearance.glass = -1;
                    } },
                { key: "tinted", label: "Tinted", enabled: true, toggle: "radio", checked: preset === "tinted", run: () => {
                        Settings.appearance.glass = 1;
                    } }
            ].concat(preset === "custom" ? [sep("s-custom"), { key: "custom", label: `Custom (${Math.round(Theme.glass * 100)} %)`, enabled: false }] : [])
        });
        items.push({ key: "reduce", label: "Reduce Transparency", enabled: true, toggle: "check", checked: Theme.reduceTransparency, run: () => {
                Settings.appearance.reduceTransparency = !Theme.reduceTransparency;
            } });
        // Reduce Transparency always draws it (flat).
        items.push({ key: "barbg", label: "Show Menu Bar Background", enabled: !Theme.reduceTransparency, toggle: "check", checked: Theme.barBackground, run: () => {
                Settings.appearance.barBackground = Theme.barBackground ? 0 : 1;
            } });
        items.push(sep("s-settings"));
        items.push({ key: "appearanceSettings", label: "Appearance Settings…", enabled: true, run: () => root.settingsPage("appearance") });
        return items;
    }

    // Screenshot ▸ — the capture module's entry points; a beat later so the
    // menu is gone from the frame.
    function screenshotItems() {
        return [
            { key: "selector", label: "Capture…", enabled: true, delay: 250, run: () => Capture.openSelector() },
            sep("s-shot"),
            { key: "screen", label: "Capture Screen", enabled: true, delay: 250, run: () => Capture.capture("shot", "screen", 0) },
            { key: "area", label: "Capture Area", enabled: true, delay: 250, run: () => Capture.capture("shot", "area", 0) }
        ];
    }

    // ── Actions ──────────────────────────────────────────────────────────
    function openTerminal() {
        // ~/Desktop when there is one; the first terminal found.
        Quickshell.execDetached(["sh", "-c", 'd="$HOME/Desktop"; [ -d "$d" ] || d="$HOME"; cd "$d" || exit 1; for t in "$TERMINAL" xdg-terminal-exec ghostty kitty foot alacritty wezterm konsole gnome-terminal xterm; do [ -n "$t" ] && command -v "$t" >/dev/null 2>&1 && exec "$t"; done', "loft-terminal"]);
    }

    // Data the submenus show.
    Connections {
        target: root
        function onOpenChanged() {
            if (root.open && !Vibes.data && !Vibes.loading)
                Vibes.refresh();
        }
    }

    IpcHandler {
        target: "desktopmenu"

        // Open in the middle of the focused display (a right-click opens it
        // at the pointer).
        function open(): void {
            root.openCentered(Niri.focusedWorkspace?.output ?? "");
        }
        function close(): void {
            root.close();
        }
        function toggle(): void {
            if (root.open)
                root.close();
            else
                open();
        }
        // Open with a submenu expanded (tests, screenshots).
        function theme(): void {
            root.openSub("theme");
        }
        function appearance(): void {
            root.openSub("appearance");
        }
        function wallpaper(): void {
            root.openSub("wallpaper");
        }
        function screenshot(): void {
            root.openSub("screenshot");
        }
        // Keys without a keyboard.
        function down(): void {
            root.key({ key: Qt.Key_Down, text: "" });
        }
        function up(): void {
            root.key({ key: Qt.Key_Up, text: "" });
        }
        function right(): void {
            root.key({ key: Qt.Key_Right, text: "" });
        }
        function left(): void {
            root.key({ key: Qt.Key_Left, text: "" });
        }
        function enter(): void {
            root.key({ key: Qt.Key_Return, text: "" });
        }
        function esc(): void {
            root.key({ key: Qt.Key_Escape, text: "" });
        }
        function state(): string {
            return JSON.stringify({ open: root.open, screen: root.screen, depth: root.depth, path: root.path, top: root.items0.map(i => i.separator ? "—" : i.label), sub: root.items1.map(i => i.separator ? "—" : i.label), vibes: Vibes.wallpapers.length, vibesLoading: Vibes.loading, themes: ThemeManager.themes.length });
        }
    }

    function openSub(id) {
        if (!open)
            openCentered(Niri.focusedWorkspace?.output ?? "");
        const it = items0.find(x => x.key === id);
        if (it)
            expandFirst(0, it);
    }
}
