pragma Singleton

import QtQuick
import Quickshell

// The feature registry — "install only what you use" (docs/FEATURES.md).
//
// Every optional module is listed here. A module that is off isn't loaded:
// shell.qml gates its surfaces with `Features.on(id) ? screens : []`, and
// its Settings page hides. Choices persist in Settings.features (runtime
// overrides), so turning a module back on restores it as it was.
//
// Adding a module: an entry below, its surfaces in shell.qml behind
// Features.on(id), and optionally `page` (a Settings page, relative to
// src/settings/) — no other shared files.
Singleton {
    id: root

    readonly property var groups: ["Desktop", "Sound", "System", "Windows", "Clipboard & files", "Everyday", "Capture", "Apps", "Display"]

    // id, label, icon, group, description, default (on unless false), core (can't be turned off)
    readonly property var modules: [
        { id: "bar", label: "Menu bar", icon: "󰍜", group: "Desktop", core: true, description: "App menu, workspaces, tray, status, date" },
        { id: "dock", label: "Dock", icon: "󱂬", group: "Desktop", description: "Pinned and running apps with magnification" },
        { id: "island", label: "Dynamic Island", icon: "󰟜", group: "Everyday", description: "Now playing, live activities, notifications, system pages" },
        { id: "controlcenter", label: "Control Center", icon: "󰒓", group: "Desktop", description: "Network, Bluetooth, toggles, now playing, volume, calendar" },
        { id: "osd", label: "Volume display", icon: "󰕾", group: "Sound", description: "On-screen pill when volume changes" },
        { id: "switcher", label: "App switcher", icon: "󰕰", group: "Windows", description: "⌘Tab between apps" },
        { id: "wallpaperPicker", label: "Wallpaper picker", icon: "󰸉", group: "Desktop", description: "Browse and apply wallpapers" },
        { id: "lock", label: "Lock screen", icon: "󰌾", group: "Desktop", core: true, description: "Session lock with the theme's design" },
        { id: "appMenu", label: "App menu", icon: "󰀻", group: "Desktop", page: "MenuBarPage.qml", description: "Click the app name (or Mod+F10): About, New Window, desktop actions, window commands, Hide, Quit" },
        { id: "globalMenu", label: "Global menu", icon: "󰍜", group: "Desktop", page: "MenuBarPage.qml", description: "The focused app's File / Edit / View menus in the bar (Qt/KDE apps; GTK menubars best effort)" }
    ]

    readonly property var presets: ({
            "Minimal": ["bar", "lock", "dock"],
            "Everything": null // all modules on
        })

    function module(id) {
        return modules.find(m => m.id === id) ?? null;
    }

    function on(id) {
        const m = module(id);
        if (!m)
            return false;
        if (m.core)
            return true;
        const v = Settings.features[id];
        return v === undefined ? m.default !== false : v;
    }

    function set(id, enabled) {
        const f = Object.assign({}, Settings.features);
        f[id] = enabled;
        Settings.features = f;
    }

    function applyPreset(name) {
        const keep = presets[name];
        const f = {};
        for (const m of modules)
            if (!m.core)
                f[m.id] = keep === null || keep.includes(m.id);
        Settings.features = f;
    }
}
