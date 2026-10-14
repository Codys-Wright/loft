pragma Singleton

import QtQuick
import Quickshell
import qs.capture
import qs.controls
import qs.services

// The action catalog behind the Quick Panel and the Radial Menu: every
// control of the Control Center registry (Controls.qml — toggles, actions,
// panels), plus tools (capture modes, OCR, color, clipboard, snippets,
// scratchpad, timers), niri window actions and app launches.
//
//   entry = { id, label, icon, group, kind, feature, hint }
//     kind  "toggle" (has an on state: active(id)), "action", "panel"
//           (opens its Control Center module), "app" (icon from the app)
//
// Ids are stable strings saved in quickpanel.json / radial.json:
//   control:<Controls id>   capture:<mode>   niri:<action>   ws:<n>
//   app:<desktop id>        snippet:<id>     tool ids below
// run(id, ctx) — ctx.windowId: the window that was focused when the
// palette opened (window actions act on it).
Singleton {
    id: root

    readonly property var groups: ["Controls", "Capture", "Clipboard & text", "Everyday", "Windows", "Desktop", "Apps", "Snippets"]

    readonly property var tools: [
        // Capture
        { id: "capture:selector", label: "Capture…", icon: "󰄀", group: "Capture", feature: "capture", hint: "The ⌘⇧5 toolbar" },
        { id: "capture:area", label: "Screenshot Area", icon: "󰩭", group: "Capture", feature: "capture" },
        { id: "capture:window", label: "Screenshot Window", icon: "󰖯", group: "Capture", feature: "capture" },
        { id: "capture:screen", label: "Screenshot Screen", icon: "󰍹", group: "Capture", feature: "capture" },
        { id: "capture:recordArea", label: "Record Area", icon: "󰑋", group: "Capture", feature: "capture", kind: "toggle" },
        { id: "capture:recordScreen", label: "Record Screen", icon: "󰻃", group: "Capture", feature: "capture", kind: "toggle" },
        { id: "capture:text", label: "Copy Text (OCR)", icon: "󱄽", group: "Capture", feature: "ocr" },
        { id: "capture:color", label: "Color Picker", icon: "󰈊", group: "Capture", feature: "colorPicker" },
        { id: "capture:camera", label: "Camera Mirror", icon: "󰄀", group: "Capture", feature: "camera", kind: "toggle" },
        // Clipboard & text
        { id: "clipboard:history", label: "Clipboard History", icon: "󰨸", group: "Clipboard & text", feature: "clipboard" },
        { id: "clipboard:plain", label: "Paste as Plain Text", icon: "󰉿", group: "Clipboard & text", feature: "clipboard" },
        { id: "clipboard:cleanUrl", label: "Clean URL", icon: "󰌷", group: "Clipboard & text", feature: "clipboard", hint: "Strip tracking parameters from the copied link" },
        { id: "snippets:picker", label: "Snippets", icon: "󱐋", group: "Clipboard & text", feature: "snippets" },
        { id: "emoji", label: "Emoji & Symbols", icon: "󰞅", group: "Clipboard & text" },
        // Everyday
        { id: "scratchpad", label: "Scratchpad", icon: "󰺿", group: "Everyday", feature: "scratchpad", kind: "toggle" },
        { id: "scratchpad:new", label: "New Note", icon: "󰎜", group: "Everyday", feature: "scratchpad" },
        { id: "timer:5", label: "Timer 5 min", icon: "󰔟", group: "Everyday" },
        { id: "timer:25", label: "Focus 25 min", icon: "󰔟", group: "Everyday" },
        { id: "timer:50", label: "Focus 50 min", icon: "󰔟", group: "Everyday" },
        { id: "timer:stop", label: "Stop Timer", icon: "󱫪", group: "Everyday" },
        // Windows (niri)
        { id: "niri:maximize", label: "Maximize", icon: "󰊓", group: "Windows" },
        { id: "niri:fullscreen", label: "Full Screen", icon: "󰊓", group: "Windows" },
        { id: "niri:float", label: "Float / Tile", icon: "󰖲", group: "Windows" },
        { id: "niri:center", label: "Center", icon: "󰘞", group: "Windows" },
        { id: "niri:close", label: "Close Window", icon: "󰅖", group: "Windows" },
        { id: "niri:wsPrev", label: "Move to Workspace Above", icon: "󰁝", group: "Windows" },
        { id: "niri:wsNext", label: "Move to Workspace Below", icon: "󰁅", group: "Windows" },
        { id: "niri:monitorNext", label: "Move to Next Display", icon: "󰍺", group: "Windows" },
        { id: "ws:1", label: "Move to Workspace 1", icon: "󰎤", group: "Windows" },
        { id: "ws:2", label: "Move to Workspace 2", icon: "󰎧", group: "Windows" },
        { id: "ws:3", label: "Move to Workspace 3", icon: "󰎪", group: "Windows" },
        { id: "ws:4", label: "Move to Workspace 4", icon: "󰎭", group: "Windows" },
        { id: "ws:5", label: "Move to Workspace 5", icon: "󰎱", group: "Windows" },
        // Desktop
        { id: "terminal", label: "Terminal", icon: "󰆍", group: "Desktop" },
        { id: "settings", label: "Settings", icon: "󰒓", group: "Desktop" },
        { id: "wallpaper:picker", label: "Wallpapers", icon: "󰸉", group: "Desktop", feature: "wallpaperPicker" },
        { id: "controlcenter", label: "Control Center", icon: "󰒓", group: "Desktop", feature: "controlcenter" },
        { id: "monitor", label: "System Monitor", icon: "󰄧", group: "Desktop", feature: "systemMonitor" },
        { id: "quickpanel:settings", label: "Edit Quick Panel…", icon: "󰏫", group: "Desktop", feature: "quickPanel" },
        { id: "radial:settings", label: "Edit Radial Menu…", icon: "󰏫", group: "Desktop", feature: "radialMenu" }
    ]

    // Controls → entries (the "special" ones are drawn by the bar itself).
    readonly property var controlEntries: Controls.controls.filter(c => c.kind !== "special" && c.id !== "connectivity").map(c => ({
                id: "control:" + c.id,
                label: c.label,
                icon: c.icon,
                group: "Controls",
                feature: c.feature,
                kind: c.kind === "panel" && !["wifi", "bluetooth", "focus", "nowPlaying"].includes(c.id) ? "panel" : c.kind === "action" ? "action" : "toggle",
                control: c.id
            }))

    readonly property var catalog: controlEntries.concat(tools)

    // Every app with a desktop entry, by name (for pickers).
    readonly property var apps: DesktopEntries.applications.values.filter(e => !e.noDisplay).map(e => ({
                id: "app:" + e.id,
                label: e.name,
                icon: "",
                group: "Apps",
                kind: "app",
                appId: e.id
            })).sort((a, b) => a.label.localeCompare(b.label))

    readonly property var snippetEntries: Snippets.items.map(s => ({
                id: "snippet:" + s.id,
                label: s.name || s.trigger || "Snippet",
                icon: "󱐋",
                group: "Snippets",
                feature: "snippets",
                kind: "action",
                hint: s.trigger ?? ""
            }))

    // Settings rows: a System Settings badge color per group.
    function badge(group) {
        return ({
                "Controls": "blue",
                "Capture": "orange",
                "Clipboard & text": "yellow",
                "Everyday": "green",
                "Windows": "teal",
                "Desktop": "graphite",
                "Apps": "gray",
                "Snippets": "brown"
            })[group] ?? "gray";
    }

    function entry(id) {
        if (!id)
            return null;
        if (id.startsWith("app:")) {
            const appId = id.slice(4);
            return { id: id, label: Apps.name(appId) || Apps.prettify(appId), icon: "", group: "Apps", kind: "app", appId: appId };
        }
        if (id.startsWith("snippet:"))
            return snippetEntries.find(e => e.id === id) ?? null;
        return catalog.find(e => e.id === id) ?? null;
    }

    // Everything a picker can offer, grouped in `groups` order.
    function all() {
        return catalog.concat(snippetEntries, apps);
    }

    function available(id) {
        const e = entry(id);
        if (!e)
            return false;
        if (e.control)
            return Controls.available(e.control);
        return !e.feature || Features.on(e.feature);
    }

    function label(id) {
        return entry(id)?.label ?? id;
    }

    function icon(id) {
        const e = entry(id);
        if (!e)
            return "󰘥";
        if (e.control)
            return Controls.iconOf(e.control);
        return e.icon;
    }

    // On/off state for toggles.
    function active(id) {
        const e = entry(id);
        if (!e || e.kind !== "toggle")
            return false;
        if (e.control)
            return Controls.active(e.control);
        switch (id) {
        case "capture:recordArea":
        case "capture:recordScreen":
            return Recorder.active;
        case "capture:camera":
            return Capture.cameraOn;
        case "scratchpad":
            return Scratchpad.open;
        }
        return false;
    }

    // A short state line (toggles, timers).
    function status(id) {
        const e = entry(id);
        if (e?.control)
            return Controls.status(e.control);
        if (id.startsWith("timer:") && FocusTimer.active)
            return FocusTimer.format(FocusTimer.remaining);
        return "";
    }

    // ── Running ──────────────────────────────────────────────────────────
    // Callers close their own surface first; actions that grab the screen
    // or type into an app wait a moment for it to unmap.
    function run(id, ctx) {
        const e = entry(id);
        if (!e || !available(id))
            return;
        const winId = ctx?.windowId ?? Niri.focusedWindow?.id ?? null;
        if (e.control)
            return runControl(e.control);
        if (id.startsWith("app:"))
            return Apps.launch(e.appId);
        if (id.startsWith("snippet:")) {
            const s = Snippets.items.find(x => "snippet:" + x.id === id);
            if (s)
                Snippets.expand(s);
            return;
        }
        if (id.startsWith("ws:")) {
            if (winId !== null)
                Niri.action("MoveWindowToWorkspace", { window_id: winId, reference: { Index: parseInt(id.slice(3)) }, focus: true });
            return;
        }
        switch (id) {
        case "capture:selector":
            return Capture.openSelector();
        case "capture:area":
            return Capture.capture("shot", "area", 0);
        case "capture:window":
            return Capture.capture("shot", "window", 0);
        case "capture:screen":
            return Capture.capture("shot", "screen", 0);
        case "capture:recordArea":
            return Recorder.active ? Recorder.stop() : Capture.capture("record", "area", 0);
        case "capture:recordScreen":
            return Recorder.active ? Recorder.stop() : Capture.capture("record", "screen", 0);
        case "capture:text":
            return Capture.capture("text", "area", 0);
        case "capture:color":
            return Capture.capture("color", "area", 0);
        case "capture:camera":
            Capture.cameraOn = !Capture.cameraOn;
            return;
        case "clipboard:history":
            Clipboard.panelOpen = true;
            return;
        case "clipboard:plain":
            return Clipboard.pastePlain();
        case "clipboard:cleanUrl":
            return Clipboard.cleanCurrent(false);
        case "snippets:picker":
            Snippets.pickerOpen = true;
            return;
        case "emoji":
            return Quickshell.execDetached(["loft-launcher", "emoji"]);
        case "scratchpad":
            Scratchpad.open = !Scratchpad.open;
            return;
        case "scratchpad:new":
            Scratchpad.newNote();
            Scratchpad.open = true;
            return;
        case "timer:5":
        case "timer:25":
        case "timer:50":
            return FocusTimer.startFor(parseInt(id.slice(6)));
        case "timer:stop":
            return FocusTimer.stop();
        case "niri:maximize":
            return Niri.action("MaximizeColumn");
        case "niri:fullscreen":
            return Niri.action("FullscreenWindow", { id: winId });
        case "niri:float":
            return Niri.action("ToggleWindowFloating", { id: winId });
        case "niri:center":
            return Niri.action("CenterWindow", { id: winId });
        case "niri:close":
            return Niri.action("CloseWindow", { id: winId });
        case "niri:wsPrev":
            return Niri.action("MoveWindowToWorkspaceUp", { focus: true });
        case "niri:wsNext":
            return Niri.action("MoveWindowToWorkspaceDown", { focus: true });
        case "niri:monitorNext":
            return Niri.action("MoveWindowToMonitorNext");
        case "terminal":
            return Quickshell.execDetached(["sh", "-c", 'for t in "$TERMINAL" xdg-terminal-exec ghostty kitty foot alacritty wezterm konsole gnome-terminal xterm; do [ -n "$t" ] && command -v "$t" >/dev/null 2>&1 && exec "$t"; done', "loft-terminal"]);
        case "settings":
            Panels.settingsOpen = true;
            return;
        case "wallpaper:picker":
            Panels.wallpaperPickerOpen = true;
            return;
        case "controlcenter":
            return Panels.toggleControlCenter(Niri.focusedWorkspace?.output ?? "");
        case "monitor":
            SystemStats.monitorOpen = !SystemStats.monitorOpen;
            return;
        case "quickpanel:settings":
            return showSettings("quickpanel");
        case "radial:settings":
            return showSettings("radialmenu");
        }
    }

    function runControl(cid) {
        switch (cid) {
        case "nowPlaying":
            if (Controls.player?.canTogglePlaying)
                Controls.player.togglePlaying();
            return;
        case "clock":
        case "display":
        case "sound":
        case "battery":
        case "camera":
        case "inputSource":
            // Panels open as their Control Center module.
            if (!Panels.controlCenterOpen)
                Panels.toggleControlCenter(Niri.focusedWorkspace?.output ?? "");
            Panels.ccEditing = false;
            Panels.ccExpanded = cid === "clock" ? "" : cid;
            return;
        }
        ControlActions.trigger(cid);
    }

    function showSettings(section) {
        Panels.settingsSection = section;
        Panels.settingsOpen = true;
    }

    // Case-insensitive match on the label, group and hint.
    function matches(e, q) {
        if (!q)
            return true;
        const s = `${e.label} ${e.group} ${e.hint ?? ""}`.toLowerCase();
        return q.toLowerCase().split(/\s+/).every(w => s.includes(w));
    }
}
