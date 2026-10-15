pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Networking
import Quickshell.Services.Mpris
import Quickshell.Services.UPower

// Controls: one model for everything that can live in the Control Center,
// in the menu bar's status area, or both (macOS: "Show in Menu Bar").
//
//   control = { id, label, icon, group, feature, sizes, bar, barDefault,
//               kind, activeOnly }
//     sizes       Control Center sizes ("1x1" "2x1" "2x2" "4x1"); [] = bar only
//     bar         can be shown in the menu bar
//     kind        "panel"  — has a panel (src/controls/PanelHost.qml): a
//                            dropdown in the bar, expands in place in the CC
//                 "toggle" — on/off; "action" — does one thing
//                 "special"— the bar draws it itself (tray, readouts, …)
//     activeOnly  "option" (default off) | "default" (option, default on) |
//                 "always" (an indicator: shown only while active)
//
// Placement persists in Settings.controlCenter.layout ([{ id, size }]) and
// Settings.menubar.bar ({ order, shown: { id: bool }, activeOnly: { id:
// bool }, trayTucked / trayPinned / trayColor: [ids] }). Features (Features.qml) gate the rest:
// a control whose module is off appears nowhere.
Singleton {
    id: root

    readonly property var controls: [
        { id: "connectivity", label: "Connectivity", icon: "󰖩", group: "System", sizes: ["2x2"], bar: false, kind: "panel" },
        { id: "wifi", label: "Wi-Fi", icon: "󰖩", group: "System", feature: "wifiControl", sizes: ["1x1", "2x1"], bar: true, barDefault: false, kind: "panel", activeOnly: "option" },
        { id: "bluetooth", label: "Bluetooth", icon: "󰂯", group: "System", feature: "bluetoothControl", sizes: ["1x1", "2x1"], bar: true, barDefault: false, kind: "panel", activeOnly: "option" },
        { id: "phone", label: "iPhone", icon: "󰄜", group: "Everyday", feature: "phone", sizes: ["2x1", "1x1"], bar: true, barDefault: false, kind: "panel", activeOnly: "option" },
        { id: "focus", label: "Focus", icon: "󰂛", group: "Everyday", feature: "focusControl", sizes: ["2x1", "1x1"], bar: true, barDefault: true, kind: "panel", activeOnly: "default" },
        { id: "display", label: "Display", icon: "󰃟", group: "Display", feature: "displayControl", sizes: ["4x1"], bar: true, barDefault: false, kind: "panel" },
        { id: "sound", label: "Sound", icon: "󰕾", group: "Sound", feature: "soundControl", sizes: ["4x1"], bar: true, barDefault: true, kind: "panel" },
        { id: "nowPlaying", label: "Now Playing", icon: "󰎆", group: "Everyday", feature: "nowPlaying", sizes: ["2x2", "2x1", "4x1"], bar: true, barDefault: false, kind: "panel", activeOnly: "option" },
        { id: "battery", label: "Battery", icon: "󰁹", group: "System", feature: "batteryControl", sizes: ["1x1", "2x1"], bar: true, barDefault: true, kind: "panel", activeOnly: "option" },
        { id: "caffeine", label: "Keep Awake", icon: "󰅶", group: "Desktop", feature: "keepAwake", sizes: ["1x1", "2x1"], bar: true, barDefault: false, kind: "panel", activeOnly: "default" },
        { id: "cleaning", label: "Cleaning Mode", icon: "󰃢", group: "Everyday", feature: "cleaningMode", sizes: ["1x1", "2x1"], bar: true, barDefault: false, kind: "action" },
        { id: "nightLight", label: "Night Light", icon: "󰖔", group: "Display", sizes: ["1x1", "2x1"], bar: true, barDefault: false, kind: "toggle", activeOnly: "default" },
        { id: "powerMode", label: "Power Mode", icon: "󰾅", group: "System", sizes: ["1x1", "2x1"], bar: true, barDefault: false, kind: "toggle" },
        { id: "focusTimer", label: "Focus Timer", icon: "󰔟", group: "Everyday", sizes: ["1x1", "2x1"], bar: true, barDefault: false, kind: "toggle", activeOnly: "default" },
        { id: "screenshot", label: "Screenshot", icon: "󰹑", group: "Capture", feature: "capture", sizes: ["1x1", "2x1"], bar: true, barDefault: false, kind: "action" },
        { id: "record", label: "Screen Recording", icon: "󰻃", group: "Capture", feature: "capture", sizes: ["1x1", "2x1"], bar: true, barDefault: true, kind: "toggle", activeOnly: "default" },
        { id: "micMute", label: "Microphones", icon: "󰍬", group: "Sound", feature: "micTools", sizes: ["1x1", "2x1"], bar: true, barDefault: true, kind: "toggle", activeOnly: "default" },
        { id: "lock", label: "Lock Screen", icon: "󰌾", group: "Desktop", sizes: ["1x1"], bar: true, barDefault: false, kind: "action" },
        { id: "overview", label: "Overview", icon: "󰕰", group: "Windows", sizes: ["1x1", "2x1"], bar: true, barDefault: false, kind: "action" },
        { id: "displays", label: "Displays", icon: "󰍹", group: "Display", sizes: ["1x1", "2x1"], bar: true, barDefault: false, kind: "action" },
        { id: "clipboard", label: "Clipboard", icon: "󰨸", group: "Clipboard & files", feature: "clipboard", sizes: ["1x1"], bar: true, barDefault: false, kind: "action" },
        { id: "colorPicker", label: "Color Picker", icon: "󰈊", group: "Capture", feature: "colorPicker", sizes: ["1x1"], bar: true, barDefault: false, kind: "action" },
        { id: "spotlight", label: "Spotlight", icon: "󰍉", group: "Desktop", feature: "spotlightIcon", sizes: ["1x1"], bar: true, barDefault: true, kind: "action" },
        { id: "clock", label: "Calendar", icon: "󰃭", group: "Everyday", sizes: ["2x2"], bar: true, barDefault: true, kind: "panel" },
        { id: "camera", label: "Camera in use", icon: "󰄀", group: "Capture", feature: "cameraIndicator", sizes: [], bar: true, barDefault: true, kind: "panel", activeOnly: "always" },
        { id: "inputSource", label: "Input Source", icon: "󰌌", group: "Desktop", feature: "inputSource", sizes: [], bar: true, barDefault: true, kind: "panel" },
        { id: "tray", label: "Status icons (tray)", icon: "󰀻", group: "Desktop", sizes: [], bar: true, barDefault: true, kind: "special" },
        { id: "controlcenter", label: "Control Center", icon: "󰒓", group: "Desktop", feature: "controlcenter", sizes: [], bar: true, barDefault: true, kind: "special" }
    ]

    readonly property var readoutLabels: ({
            cpu: "CPU",
            memory: "Memory",
            cpuTemp: "CPU temperature",
            gpu: "GPU",
            network: "Network traffic",
            battery: "Battery (readout)"
        })

    // Bar items left to right (readouts first, the clock last).
    readonly property var barDefaultOrder: ["readout.cpu", "readout.memory", "readout.cpuTemp", "readout.gpu", "readout.network", "readout.battery", "tray", "camera", "micMute", "record", "nowPlaying", "caffeine", "nightLight", "focusTimer", "powerMode", "cleaning", "screenshot", "colorPicker", "clipboard", "overview", "displays", "lock", "inputSource", "phone", "focus", "battery", "bluetooth", "wifi", "sound", "display", "spotlight", "controlcenter", "clock"]

    readonly property var ccDefaultLayout: [
        { id: "connectivity", size: "2x2" },
        { id: "focus", size: "2x1" },
        { id: "caffeine", size: "1x1" },
        { id: "phone", size: "2x1" },
        { id: "nightLight", size: "1x1" },
        { id: "display", size: "4x1" },
        { id: "sound", size: "4x1" },
        { id: "nowPlaying", size: "2x2" },
        { id: "screenshot", size: "1x1" },
        { id: "record", size: "1x1" },
        { id: "micMute", size: "1x1" },
        { id: "lock", size: "1x1" },
        { id: "overview", size: "1x1" },
        { id: "displays", size: "1x1" },
        { id: "clipboard", size: "1x1" },
        { id: "spotlight", size: "1x1" }
    ]

    function control(id) {
        if (id.startsWith("readout."))
            return { id: id, label: readoutLabels[id.slice(8)] ?? id, icon: "󰍛", group: "System", feature: "barReadouts", sizes: [], bar: true, kind: "special" };
        return controls.find(c => c.id === id) ?? null;
    }

    // ── Live state ───────────────────────────────────────────────────────
    readonly property var btAdapter: Bluetooth.defaultAdapter
    readonly property var btConnected: (btAdapter?.devices.values ?? []).filter(d => d.connected)
    readonly property var players: Mpris.players.values
    readonly property var player: players.find(p => p.isPlaying) ?? players[0] ?? null
    readonly property var batteryDevice: UPower.displayDevice
    readonly property bool hasBattery: batteryDevice !== null && batteryDevice.ready && batteryDevice.isLaptopBattery
    readonly property real batteryPercent: hasBattery ? (batteryDevice.percentage > 1 ? batteryDevice.percentage : batteryDevice.percentage * 100) : 0

    // The module (and any condition) that lets the control exist at all.
    function available(id) {
        const c = control(id);
        if (!c)
            return false;
        if (c.feature && !Features.on(c.feature))
            return false;
        switch (id) {
        case "connectivity":
            return Features.on("wifiControl") || Features.on("bluetoothControl");
        case "battery":
            return hasBattery;
        case "inputSource":
            return (Niri.keyboardLayouts.names ?? []).length > 1;
        case "readout.battery":
            return hasBattery;
        }
        return true;
    }

    // Whether the control is "on" (accent in the CC; "only when active").
    function active(id) {
        switch (id) {
        case "wifi":
            return NetStatus.online;
        case "bluetooth":
            return btConnected.length > 0;
        case "focus":
            return Panels.doNotDisturb || FocusTimer.active;
        case "nowPlaying":
            return player?.isPlaying ?? false;
        case "phone":
            return Phone.connected;
        case "battery":
            return hasBattery && UPower.onBattery;
        case "caffeine":
            return KeepAwake.active;
        case "nightLight":
            return NightLight.enabled;
        case "powerMode":
            return PowerProfiles.profile !== PowerProfile.Balanced;
        case "focusTimer":
            return FocusTimer.active;
        case "record":
            return Recorder.active;
        case "micMute":
            return Sound.recording || Sound.micsMuted;
        case "camera":
            return Privacy.cameraInUse;
        }
        return true;
    }

    // ── Menu bar placement ───────────────────────────────────────────────
    readonly property var barCfg: Settings.menubar.bar ?? ({})

    function saveBar(patch) {
        const m = Object.assign({}, Settings.menubar);
        m.bar = Object.assign({}, barCfg, patch);
        Settings.menubar = m;
    }

    // Every bar-capable id, in the user's order (new ids slot in where the
    // default order puts them).
    readonly property var barOrder: {
        const saved = (barCfg.order ?? []).filter(id => barDefaultOrder.includes(id));
        if (saved.length === 0)
            return barDefaultOrder;
        const out = saved.slice();
        for (let i = 0; i < barDefaultOrder.length; i++) {
            const id = barDefaultOrder[i];
            if (out.includes(id))
                continue;
            // After the nearest earlier default neighbour that is placed.
            let at = 0;
            for (let j = i - 1; j >= 0; j--) {
                const k = out.indexOf(barDefaultOrder[j]);
                if (k >= 0) {
                    at = k + 1;
                    break;
                }
            }
            out.splice(at, 0, id);
        }
        return out;
    }

    // "Show in menu bar".
    function onBar(id) {
        if (id.startsWith("readout."))
            return Array.from(Settings.system.readouts).includes(id.slice(8));
        const v = (barCfg.shown ?? {})[id];
        return v === undefined ? (control(id)?.barDefault ?? false) : v;
    }

    function setOnBar(id, on) {
        if (id.startsWith("readout.")) {
            const key = id.slice(8);
            const l = Array.from(Settings.system.readouts).filter(k => k !== key);
            if (on)
                l.push(key);
            Settings.system.readouts = l;
            return;
        }
        const s = Object.assign({}, barCfg.shown ?? {});
        s[id] = on;
        saveBar({ shown: s });
    }

    function activeOnlyMode(id) {
        return control(id)?.activeOnly ?? "";
    }

    function activeOnly(id) {
        const mode = activeOnlyMode(id);
        if (mode === "always")
            return true;
        if (mode === "")
            return false;
        const v = (barCfg.activeOnly ?? {})[id];
        return v === undefined ? mode === "default" : v;
    }

    function setActiveOnly(id, on) {
        const s = Object.assign({}, barCfg.activeOnly ?? {});
        s[id] = on;
        saveBar({ activeOnly: s });
    }

    // On the bar right now.
    function barShown(id) {
        return available(id) && onBar(id) && (!activeOnly(id) || active(id)) && spaceAllows(id);
    }

    // The active space's menu bar (SPACES §5 `menubar.extras`): a subset of
    // the enabled items. The Control Center button always stays.
    function spaceAllows(id) {
        const keep = Spaces.menubarExtras;
        // A readout may be named either way ("readout.cpu" or "cpu").
        return keep === null || id === "controlcenter" || keep.includes(id) || (id.startsWith("readout.") && keep.includes(id.slice(8)));
    }

    // Move `id` to sit before `beforeId` ("" = the end).
    function moveBarItem(id, beforeId) {
        const l = barOrder.filter(x => x !== id);
        const at = beforeId ? l.indexOf(beforeId) : -1;
        if (at < 0)
            l.push(id);
        else
            l.splice(at, 0, id);
        saveBar({ order: l });
    }

    function stepBarItem(id, delta) {
        // Among the items currently arranged (shown) only.
        const vis = barOrder.filter(x => available(x) && onBar(x));
        const i = vis.indexOf(id);
        const j = i + delta;
        if (i < 0 || j < 0 || j >= vis.length)
            return;
        const target = delta > 0 ? (vis[j + 1] ?? "") : vis[j];
        moveBarItem(id, target);
    }

    function resetBar() {
        const m = Object.assign({}, Settings.menubar);
        delete m.bar;
        Settings.menubar = m;
    }

    // Tray (StatusNotifier) items behind the » overflow. Explicit choices
    // (by item id) win; otherwise an item whose job a Loft control already
    // does (blueman next to our Bluetooth, nm-applet next to Wi-Fi, …) is
    // tucked away by default — still reachable, never hidden outright.
    readonly property var trayTucked: barCfg.trayTucked ?? []
    readonly property var trayPinned: barCfg.trayPinned ?? []

    // Tray apps that duplicate a control, matched on the item's id / title /
    // icon name.
    readonly property var trayDuplicates: [
        { match: /blueman|bluetooth-applet|blueberry/i, control: "bluetooth" },
        { match: /nm-applet|nm_applet|networkmanager|network-manager-applet|iwgtk/i, control: "wifi" },
        { match: /pasystray|pavucontrol|volumeicon|pnmixer|pa-applet|kmix/i, control: "sound" }
    ]

    // The control a tray item duplicates ("" = none), while Loft offers that
    // control (in the menu bar or the Control Center).
    function trayDuplicateOf(item) {
        if (!item)
            return "";
        const key = [item.id, item.title, item.tooltipTitle, String(item.icon ?? "")].join(" ");
        const hit = trayDuplicates.find(d => d.match.test(key));
        return hit && available(hit.control) ? hit.control : "";
    }

    function isTrayTucked(item) {
        if (!item)
            return false;
        if (trayTucked.includes(item.id))
            return true;
        if (trayPinned.includes(item.id))
            return false;
        return trayDuplicateOf(item) !== "";
    }

    function setTrayTucked(itemId, tucked) {
        const t = trayTucked.filter(x => x !== itemId);
        const p = trayPinned.filter(x => x !== itemId);
        (tucked ? t : p).push(itemId);
        saveBar({ trayTucked: t, trayPinned: p });
    }

    // Tray items drawn in their own colors instead of as monochrome
    // templates (macOS draws every menu bar icon as a template).
    readonly property var trayColor: barCfg.trayColor ?? []

    function setTrayColor(itemId, color) {
        const l = trayColor.filter(x => x !== itemId);
        if (color)
            l.push(itemId);
        saveBar({ trayColor: l });
    }

    // Status items that didn't fit, per screen (StatusItems reports them;
    // the » overflow lists them).
    property var overflowByScreen: ({})

    function setOverflow(screenName, ids) {
        if (JSON.stringify(overflowByScreen[screenName] ?? []) === JSON.stringify(ids))
            return;
        const m = Object.assign({}, overflowByScreen);
        m[screenName] = ids;
        overflowByScreen = m;
    }


    // ── Control Center layout ────────────────────────────────────────────
    readonly property var ccLayout: {
        const saved = Settings.controlCenter.layout;
        const l = Array.isArray(saved) ? saved : ccDefaultLayout;
        return l.filter(e => e && control(e.id) && (control(e.id).sizes ?? []).includes(e.size));
    }
    // What the CC shows now.
    readonly property var ccVisible: ccLayout.filter(e => available(e.id))

    function saveCc(layout) {
        const c = Object.assign({}, Settings.controlCenter);
        c.layout = layout;
        Settings.controlCenter = c;
    }

    function inCc(id) {
        return ccLayout.some(e => e.id === id);
    }

    function ccAdd(id, size) {
        if (inCc(id))
            return;
        saveCc(ccLayout.concat([{ id: id, size: size ?? control(id).sizes[0] }]));
    }

    function ccRemove(id) {
        saveCc(ccLayout.filter(e => e.id !== id));
    }

    function ccMove(id, toIndex) {
        const l = ccLayout.slice();
        const i = l.findIndex(e => e.id === id);
        if (i < 0)
            return;
        const [e] = l.splice(i, 1);
        l.splice(Math.max(0, Math.min(l.length, toIndex)), 0, e);
        saveCc(l);
    }

    function ccResize(id) {
        const sizes = control(id)?.sizes ?? [];
        const l = ccLayout.map(e => {
            if (e.id !== id)
                return e;
            const i = sizes.indexOf(e.size);
            return { id: e.id, size: sizes[(i + 1) % sizes.length] };
        });
        saveCc(l);
    }

    function ccReset() {
        const c = Object.assign({}, Settings.controlCenter);
        delete c.layout;
        Settings.controlCenter = c;
    }

    // One line under a control's name (CC tiles, the arrange page).
    function status(id) {
        switch (id) {
        case "wifi":
            return !Networking.wifiEnabled ? "Off" : NetStatus.wifiNetwork?.name ?? (NetStatus.wired ? "Ethernet" : "Not connected");
        case "bluetooth":
            return !btAdapter ? "Unavailable" : !btAdapter.enabled ? "Off" : btConnected.length === 1 ? btConnected[0].name : btConnected.length > 1 ? `${btConnected.length} devices` : "On";
        case "focus":
            return FocusTimer.active ? FocusTimer.format(FocusTimer.remaining) : Panels.doNotDisturb ? "Do Not Disturb" : "Off";
        case "caffeine":
            return KeepAwake.status;
        case "nightLight":
            return NightLight.enabled ? `${NightLight.temperature}K` : "Off";
        case "powerMode":
            return PowerProfile.toString(PowerProfiles.profile);
        case "focusTimer":
            return FocusTimer.active ? FocusTimer.format(FocusTimer.remaining) : `${Settings.island.focusMinutes} min`;
        case "record":
            return Recorder.active ? FocusTimer.format(Recorder.elapsed) : "Off";
        case "micMute":
            return Sound.micsMuted ? "Muted" : Sound.recording ? "In use" : "On";
        case "battery":
            return hasBattery ? `${Math.round(batteryPercent)}%` : "";
        case "nowPlaying":
            return player ? (player.trackTitle || "Not playing") : "Not playing";
        case "phone":
            return Phone.activeCall ? `On a call · ${Phone.callTime}` : Phone.unread > 0 && Phone.connected ? `${Phone.statusLine} · ${Phone.unread} unread` : Phone.statusLine;
        }
        return "";
    }

    // The control's glyph for its current state.
    function iconOf(id) {
        switch (id) {
        case "wifi":
            return NetStatus.icon;
        case "bluetooth":
            return !btAdapter || !btAdapter.enabled ? "󰂲" : btConnected.length > 0 ? "󰂱" : "󰂯";
        case "focus":
            return FocusTimer.active ? "󰔟" : "󰂛";
        case "micMute":
            return Sound.micsMuted ? "󰍭" : "󰍬";
        case "powerMode":
            return PowerProfiles.profile === PowerProfile.Performance ? "󰓅" : PowerProfiles.profile === PowerProfile.PowerSaver ? "󰌪" : "󰾅";
        case "battery":
            {
                const p = batteryPercent;
                if (!UPower.onBattery)
                    return "󰂄";
                return p > 90 ? "󰁹" : p > 70 ? "󰂁" : p > 50 ? "󰁿" : p > 30 ? "󰁽" : p > 15 ? "󰁻" : "󰂃";
            }
        case "nowPlaying":
            return player?.isPlaying ? "󰏤" : "󰐊";
        case "phone":
            return Phone.activeCall ? "󰏶" : Phone.glyph;
        }
        return control(id)?.icon ?? "";
    }
}
