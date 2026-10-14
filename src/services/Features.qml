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

    readonly property var groups: ["Desktop", "Sound", "System", "Windows", "Clipboard & files", "Everyday", "Capture", "Apps", "Display", "Controls"]

    // id, label, icon, group, description, default (on unless false), core (can't be turned off)
    readonly property var modules: [
        { id: "bar", label: "Menu bar", icon: "󰍜", group: "Desktop", core: true, description: "App menu, workspaces, tray, status, date" },
        { id: "dock", label: "Dock", icon: "󱂬", group: "Desktop", description: "Pinned and running apps with magnification" },
        { id: "island", label: "Dynamic Island", icon: "󰟜", group: "Everyday", description: "Now playing, live activities, notifications, system pages" },
        { id: "controlcenter", label: "Control Center", icon: "󰒓", group: "Desktop", description: "Network, Bluetooth, toggles, now playing, volume, calendar" },
        { id: "osd", label: "Volume display", icon: "󰄧", group: "Sound", description: "On-screen pill when volume changes" },
        { id: "switcher", label: "App switcher", icon: "󰕰", group: "Windows", description: "⌘Tab between apps" },
        { id: "wallpaperPicker", label: "Wallpaper picker", icon: "󰸉", group: "Desktop", description: "Browse and apply wallpapers" },
        { id: "desktopMenu", label: "Desktop menu", icon: "󰍝", group: "Desktop", page: "DesktopMenuPage.qml", description: "Right-click the wallpaper: wallpaper, theme, appearance, displays, screenshot, terminal, lock, settings" },
        { id: "lock", label: "Lock screen", icon: "󰌾", group: "Desktop", core: true, description: "Session lock with the theme's design" },
        { id: "systemMonitor", label: "System Monitor", icon: "󰄧", group: "System", description: "History graphs, processes (quit / force quit), disks, sensors and fans" },
        { id: "barReadouts", label: "Menu bar readouts", icon: "󰍛", group: "System", default: false, description: "CPU, memory, temperature, GPU, network and battery in the bar" },
        { id: "network", label: "Network", icon: "󰛳", group: "System", description: "Live traffic, session totals, local addresses and a speed test" },
        { id: "alerts", label: "Alerts", icon: "󰀦", group: "System", description: "Notifications for sustained load, heat, memory pressure, low disk and battery" },
        { id: "clipboard", label: "Clipboard history", icon: "󰨸", group: "Clipboard & files", description: "History with pins and image previews, paste as plain text, auto-clear, Clean URL" },
        { id: "snippets", label: "Text snippets", icon: "󱐋", group: "Clipboard & files", description: "Saved text typed into any app, with {date} and {clipboard} variables" },
        { id: "shelf", label: "Shelf", icon: "󰄠", group: "Clipboard & files", description: "Park files, links and text at the screen edge while dragging" },
        { id: "scratchpad", label: "Scratchpad", icon: "󰺿", group: "Everyday", description: "Tabbed, autosaved Markdown notes in a floating window" },
        { id: "mixer", label: "Volume mixer", icon: "󰘮", group: "Sound", description: "Per-app volume up to 150 %, mute, favorites and per-app output" },
        { id: "audioOutputs", label: "Output switcher", icon: "󰓃", group: "Sound", description: "Pick the output from the Control Center or ⌘⇧O; safe volume when headphones disconnect" },
        { id: "micTools", label: "Microphone tools", icon: "󰍬", group: "Sound", description: "Default input, level, mute all (⌘⇧M), bar indicator while recording" },
        { id: "capture", label: "Screenshots & recording", icon: "󰹑", group: "Capture", description: "⌘⇧5 selector: area/window/screen shots, recording with audio, thumbnail, annotate, pin, GIF, trim" },
        { id: "ocr", label: "Text from screen", icon: "󱄽", group: "Capture", description: "Copy the text or QR code in a screen region (tesseract, zbar)" },
        { id: "colorPicker", label: "Color picker", icon: "󰈊", group: "Capture", description: "Pick any pixel with a loupe; HEX / RGB / HSL / QML, recent colors" },
        { id: "camera", label: "Camera mirror", icon: "󰄀", group: "Capture", description: "A floating round camera preview + an island page" },
        { id: "appMenu", label: "App menu", icon: "󰀻", group: "Desktop", page: "MenuBarPage.qml", description: "Click the app name (or Mod+F10): About, New Window, desktop actions, window commands, Hide, Quit" },
        // Controls: each lives in the Control Center, the menu bar, or both
        // (Controls.qml; arranged in Settings → Menu Bar and CC Edit Controls).
        { id: "wifiControl", label: "Wi-Fi & network", icon: "󰖩", group: "Controls", page: "MenuBarPage.qml", description: "Networks, password entry, wired links and VPNs (Tailscale), details with ⌥-click" },
        { id: "bluetoothControl", label: "Bluetooth", icon: "󰂯", group: "Controls", page: "MenuBarPage.qml", description: "Devices with battery, connect, nearby devices to pair; low-battery alerts" },
        { id: "soundControl", label: "Sound", icon: "󰕾", group: "Controls", page: "MenuBarPage.qml", description: "Volume, outputs (with Bluetooth battery), mixer; ⌥-click: inputs and the PipeWire clock" },
        { id: "nowPlaying", label: "Now Playing", icon: "󰎆", group: "Controls", page: "MenuBarPage.qml", description: "Art, transport and scrubber for every MPRIS player" },
        { id: "focusControl", label: "Focus", icon: "󰂛", group: "Controls", page: "MenuBarPage.qml", description: "Do Not Disturb and focus timers" },
        { id: "displayControl", label: "Display", icon: "󰃟", group: "Controls", page: "MenuBarPage.qml", description: "Brightness (backlight / DDC), Night Light, Dark or Light appearance" },
        { id: "batteryControl", label: "Battery", icon: "󰁹", group: "Controls", page: "MenuBarPage.qml", description: "Charge, time remaining, power source and power mode (only with a battery)" },
        { id: "cameraIndicator", label: "Camera in use", icon: "󰄀", group: "Controls", page: "MenuBarPage.qml", description: "A green dot in the bar while an app uses a camera, with who" },
        { id: "inputSource", label: "Input source", icon: "󰌌", group: "Controls", page: "MenuBarPage.qml", description: "Keyboard layout in the bar (only with more than one layout)" },
        { id: "spotlightIcon", label: "Spotlight icon", icon: "󰍉", group: "Controls", page: "MenuBarPage.qml", description: "A magnifier in the bar that opens the launcher" },
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
