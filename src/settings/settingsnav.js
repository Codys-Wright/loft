.pragma library

// Loft Settings' structure (SettingsApp.qml), macOS System Settings style:
// a grouped sidebar of top-level entries, some of which hold sub-pages you
// drill into (a row with a chevron on the parent's overview → the sub-page,
// with a back button in the toolbar). Tested by tests/settingsnav.test.js.
//
// Every page keeps the id it had before the redesign (`settings open
// <id>`, Panels.settingsSection = "<id>" all over the shell), so a caller
// that opens "wallpaper" lands on Appearance ▸ Wallpaper. Top-level entries
// that group pages got new ids (general, desktop, windows); `aliases` maps
// a few more names people type.
//
//   label, icon (Nerd Font), badge (Theme.badgeColor), parent, children,
//   feature (Features module that has to be on for the page to work),
//   summary (one line on the parent's overview), keywords (sidebar search).

var pages = {
    // ── General ─────────────────────────────────────────────────────────
    general: { label: "General", icon: "󰒓", badge: "gray", children: ["about", "features", "system"], keywords: ["preferences", "modules"] },
    about: { label: "About", icon: "󰋼", badge: "gray", parent: "general", summary: "This computer and Loft", keywords: ["version", "about this computer", "hardware", "computer"] },
    features: { label: "Features", icon: "󰐱", badge: "green", parent: "general", summary: "Switch whole modules on or off", keywords: ["modules", "enable", "disable", "presets", "install"] },
    system: { label: "Monitor & Alerts", icon: "󰍛", badge: "gray", parent: "general", summary: "System Monitor, menu bar readouts, alerts", keywords: ["system", "cpu", "memory", "temperature", "readouts", "alerts"] },

    // ── Desktop ─────────────────────────────────────────────────────────
    appearance: { label: "Appearance", icon: "󰏘", badge: "graphite", children: ["wallpaper", "lockscreen"], keywords: ["theme", "dark", "light", "glass", "transparency", "blur", "colors", "spotify"] },
    wallpaper: { label: "Wallpaper", icon: "󰸉", badge: "cyan", parent: "appearance", summary: "Collection, per display and workspace, video", keywords: ["background", "video wallpaper", "rotate"] },
    lockscreen: { label: "Lock Screen", icon: "󰌾", badge: "indigo", parent: "appearance", summary: "The lock screen's design", keywords: ["lock", "lock screen settings"] },
    menubar: { label: "Menu Bar", icon: "󰍜", badge: "graphite", keywords: ["bar", "status bar", "top bar", "controls", "control center", "global menu", "system menu", "app menu"] },
    desktop: { label: "Desktop & Dock", icon: "󱂬", badge: "blue", children: ["dock", "island", "desktopmenu", "quickpanel", "radialmenu"], keywords: ["desktop", "taskbar"] },
    dock: { label: "Dock", icon: "󱂬", badge: "blue", parent: "desktop", feature: "dock", summary: "Apps, size, magnification, folders", keywords: ["taskbar", "magnification", "autohide"] },
    island: { label: "Dynamic Island", icon: "󰟜", badge: "purple", parent: "desktop", feature: "island", summary: "Now playing, live activities, notifications", keywords: ["island", "notch"] },
    desktopmenu: { label: "Desktop Menu", icon: "󰍝", badge: "blue", parent: "desktop", feature: "desktopMenu", summary: "Right-click the wallpaper", keywords: ["right click menu", "context menu"] },
    quickpanel: { label: "Quick Panel", icon: "󰕮", badge: "orange", parent: "desktop", feature: "quickPanel", summary: "⌃⌘V: tools, clipboard and snippets at the pointer", keywords: ["palette"] },
    radialmenu: { label: "Radial Menu", icon: "󰫈", badge: "purple", parent: "desktop", feature: "radialMenu", summary: "Hold ⌃⌘Space: a wheel of actions", keywords: ["wheel", "pie menu"] },
    displays: { label: "Displays", icon: "󰍹", badge: "teal", keywords: ["monitors", "resolution", "scale", "arrangement", "refresh rate"] },
    windows: { label: "Spaces & Windows", icon: "󰖲", badge: "indigo", children: ["spaces", "layout", "windowrules"], keywords: ["windows", "workspaces", "tiling"] },
    spaces: { label: "Spaces", icon: "󰕰", badge: "indigo", parent: "windows", feature: "spaces", summary: "Functional desktops across every display", keywords: ["workspaces", "desktops", "activities"] },
    layout: { label: "Layout & Motion", icon: "󰕰", badge: "mint", parent: "windows", summary: "Gaps, column widths, animations", keywords: ["gaps", "animations", "window layout", "struts"] },
    windowrules: { label: "Window Rules", icon: "󰖲", badge: "teal", parent: "windows", summary: "Where and how each app's windows open", keywords: ["rules", "floating", "opacity", "glass windows"] },

    // ── Tools ───────────────────────────────────────────────────────────
    spotlight: { label: "Spotlight", icon: "󰍉", badge: "blue", keywords: ["quicklinks", "scripts", "bangs", "search engine", "launcher"] },
    sound: { label: "Sound", icon: "󰕾", badge: "pink", keywords: ["audio", "volume", "output", "input", "microphone"] },
    capture: { label: "Capture", icon: "󰹑", badge: "orange", feature: "capture", keywords: ["screenshots", "recording", "screen recording"] },
    clipboard: { label: "Clipboard & Files", icon: "󰨸", badge: "yellow", keywords: ["clipboard settings", "shelf", "history"] },
    everyday: { label: "Everyday", icon: "󰅶", badge: "orange", keywords: ["keep awake", "caffeine", "cleaning mode", "quit protection", "sleep"] },
    phone: { label: "Phone", icon: "󰄜", badge: "green", feature: "phone", keywords: ["iphone", "tether", "pair phone", "messages settings"] },

    // ── Keyboard ────────────────────────────────────────────────────────
    input: { label: "Keyboard & Mouse", icon: "󰌌", badge: "gray", children: ["keybinds", "keyremaps", "snippets"], keywords: ["keyboard", "mouse", "trackpad", "touchpad", "pointer", "key repeat", "layout"] },
    keybinds: { label: "Keyboard Shortcuts", icon: "󰘳", badge: "graphite", parent: "input", summary: "Every shortcut of the session", keywords: ["keybinds", "shortcuts", "hotkeys", "leave alone"] },
    keyremaps: { label: "Keyboard Remaps", icon: "󰌌", badge: "indigo", parent: "input", summary: "macOS-style keys, per app", keywords: ["remap", "xremap", "keys"] },
    snippets: { label: "Snippets", icon: "󱐋", badge: "brown", parent: "input", feature: "snippets", summary: "Saved text typed into any app", keywords: ["snippets settings", "text expansion", "text replacements"] }
};

// The sidebar, top to bottom; a small gap between groups (no headers).
var groups = [
    ["general"],
    ["appearance", "menubar", "desktop", "displays", "windows"],
    ["spotlight", "sound", "capture", "clipboard", "everyday", "phone"],
    ["input"]
];

var aliases = {
    keyboard: "input",
    mouse: "input",
    trackpad: "input",
    shortcuts: "keybinds",
    remaps: "keyremaps",
    theme: "appearance",
    lock: "lockscreen",
    monitor: "system",
    dockdesktop: "desktop",
    rules: "windowrules"
};

function page(id) {
    var p = pages[id];
    if (!p)
        return null;
    return {
        id: id,
        label: p.label,
        icon: p.icon,
        badge: p.badge,
        parent: p.parent || "",
        children: p.children || [],
        feature: p.feature || "",
        summary: p.summary || "",
        keywords: p.keywords || []
    };
}

// A known page id for `id` (or an alias), else "".
function resolve(id) {
    id = String(id || "").trim().toLowerCase();
    if (pages[id])
        return id;
    return aliases[id] || "";
}

function parentOf(id) {
    return pages[id] && pages[id].parent || "";
}

// The sidebar entry a page lives under (itself for a top-level page).
function topOf(id) {
    var p = parentOf(id);
    return p || (pages[id] ? id : "");
}

function childrenOf(id) {
    return pages[id] && pages[id].children || [];
}

// "Appearance ▸ Wallpaper" for a sub-page, the label for a top-level page.
function path(id) {
    var p = pages[id];
    if (!p)
        return "";
    return p.parent ? pages[p.parent].label + " ▸ " + p.label : p.label;
}

function allIds() {
    return Object.keys(pages);
}

// Pages matching a sidebar search: label first, then keywords; best first.
// `on(feature)` is accepted for symmetry with the QML side but every page
// is listed — an off module's page offers the switch to turn it on.
function searchPages(query) {
    var q = String(query || "").trim().toLowerCase();
    if (!q)
        return [];
    var scored = [];
    for (var id in pages) {
        var p = pages[id];
        var label = p.label.toLowerCase();
        var score = -1;
        if (label.indexOf(q) === 0)
            score = 0;
        else if (label.indexOf(" " + q) >= 0)
            score = 1;
        else if (label.indexOf(q) >= 0)
            score = 2;
        else if ((p.keywords || []).some(function (k) { return k.indexOf(q) >= 0; }))
            score = 3;
        if (score >= 0)
            scored.push({ id: id, score: score + (p.parent ? 0.5 : 0) });
    }
    scored.sort(function (a, b) { return a.score - b.score || pages[a.id].label.localeCompare(pages[b.id].label); });
    return scored.map(function (s) { return s.id; });
}

// Row labels found in the pages (SettingsApp walks them) matching `query`:
// entries are { page, label, kind }; best first, at most `limit`.
function searchRows(index, query, limit) {
    var q = String(query || "").trim().toLowerCase();
    if (!q)
        return [];
    var seen = {};
    var out = [];
    for (var i = 0; i < index.length; i++) {
        var e = index[i];
        var label = e.label.toLowerCase();
        var at = label.indexOf(q);
        if (at < 0)
            continue;
        var key = e.page + "\u0000" + label;
        if (seen[key])
            continue;
        seen[key] = true;
        out.push({ e: e, score: (at === 0 ? 0 : label.indexOf(" " + q) >= 0 ? 1 : 2) + (e.kind === "section" ? -0.5 : 0) + i / 100000 });
    }
    out.sort(function (a, b) { return a.score - b.score; });
    return out.slice(0, limit || 40).map(function (s) { return s.e; });
}
