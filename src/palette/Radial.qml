pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// Radial menu (vorssaint's pointer-centered wheel): hold ⌃⌘Space, or press
// the middle button on the desktop, and a glass wheel of 2–12 slices opens
// around the pointer. Point at a slice and let go (the key's modifier or
// the button) to run it; a slice with a submenu shows its items as an
// outer ring — keep moving outward to pick one (marking-menu style). A
// quick tap leaves the wheel open to click; Esc closes.
//
// Profiles: the first profile whose `apps` (app ids, or /regex/) match the
// focused window's app id is used, else the first ("Default").
//
// <state>/radial.json: { size: small|medium|large, profiles: [{ id, name,
// apps: [..], slices: [slice] }] }
//   slice = { action: <Actions id>, label?, icon? }
//         | { label, icon, children: [slice] }      (a submenu, one level)
//
// The window is RadialMenuWindow.qml (drawing: RadialWheel.qml), the editor
// Settings → Radial Menu.
// IPC: radial hold | toggle | open | close | release | settings
Singleton {
    id: root

    readonly property bool enabled: Features.on("radialMenu")

    property bool open: false
    property string screen: ""
    // Wheel center and the pointer, in the screen's coordinates.
    property real cx: -1
    property real cy: -1
    property real px: -1
    property real py: -1
    readonly property bool placed: cx >= 0
    // "key" (release the modifier to pick), "mouse" (release the button),
    // "" (click to pick).
    property string source: ""
    // Released without a pick: stays open until a click or Esc.
    property bool sticky: false
    property var windowId: null
    property string appId: ""
    property string profileId: ""
    // Main slice whose submenu ring is shown (-1 none).
    property int ring: -1

    // ── Settings ─────────────────────────────────────────────────────────
    readonly property var defaultProfiles: [
        {
            id: "default",
            name: "Default",
            apps: [],
            slices: [
                { action: "terminal" },
                { label: "Window", icon: "󰖯", children: [{ action: "niri:maximize" }, { action: "niri:fullscreen" }, { action: "niri:float" }, { action: "niri:center" }, { action: "niri:monitorNext" }] },
                { label: "Move to", icon: "󰁔", children: [{ action: "ws:1" }, { action: "ws:2" }, { action: "ws:3" }, { action: "ws:4" }, { action: "ws:5" }] },
                { label: "Capture", icon: "󰹑", children: [{ action: "capture:area" }, { action: "capture:window" }, { action: "capture:screen" }, { action: "capture:recordArea" }, { action: "capture:text" }, { action: "capture:color" }] },
                { action: "niri:close" },
                { action: "clipboard:history" },
                { action: "scratchpad" },
                { action: "control:spotlight" }
            ]
        },
        {
            id: "browsers",
            name: "Browsers",
            apps: ["firefox", "librewolf", "/chrom|brave|zen|vivaldi/"],
            slices: [
                { action: "niri:fullscreen" },
                { label: "Move to", icon: "󰁔", children: [{ action: "ws:1" }, { action: "ws:2" }, { action: "ws:3" }, { action: "niri:monitorNext" }] },
                { action: "capture:window" },
                { action: "niri:close" },
                { action: "clipboard:history" },
                { action: "niri:maximize" }
            ]
        }
    ]

    readonly property var cfg: store.value ?? ({})
    readonly property var profiles: Array.isArray(cfg.profiles) && cfg.profiles.length > 0 ? cfg.profiles : defaultProfiles
    readonly property string size: cfg.size ?? "medium"
    // Outer radius of the main wheel; the hub is a third of it.
    readonly property real radius: size === "small" ? 108 : size === "large" ? 168 : 136
    readonly property real hub: radius * 0.34
    readonly property real ringRadius: radius + 46

    JsonStore {
        id: store
        path: `${Settings.stateDir}/radial.json`
        fallback: null
    }

    function save(patch) {
        store.save(Object.assign({ profiles: profiles }, store.value ?? {}, patch));
    }

    function saveProfiles(list) {
        save({ profiles: list });
    }

    function reset() {
        store.save({});
    }

    function matchesApp(profile, app) {
        return (profile.apps ?? []).some(p => {
            if (!p)
                return false;
            if (p.length > 2 && p.startsWith("/") && p.endsWith("/")) {
                try {
                    return new RegExp(p.slice(1, -1), "i").test(app);
                } catch (e) {
                    return false;
                }
            }
            return p.toLowerCase() === app.toLowerCase();
        });
    }

    function profileFor(app) {
        return profiles.find(p => app && matchesApp(p, app)) ?? profiles[0];
    }

    readonly property var profile: profiles.find(p => p.id === profileId) ?? profiles[0]
    readonly property var slices: (profile?.slices ?? []).filter(s => sliceAvailable(s))

    function sliceAvailable(s) {
        if (s.children)
            return s.children.some(c => Actions.available(c.action));
        return Actions.available(s.action);
    }

    function kids(s) {
        return (s?.children ?? []).filter(c => Actions.available(c.action));
    }

    function sliceLabel(s) {
        return s.label || (s.action ? Actions.label(s.action) : "");
    }

    function sliceIcon(s) {
        return s.icon || (s.action ? Actions.icon(s.action) : "󰘥");
    }

    // ── Geometry ─────────────────────────────────────────────────────────
    // Angles in degrees, clockwise from 12 o'clock.
    function sliceAngle(i, n) {
        return i * 360 / n;
    }

    function childSpan(n, m) {
        return Math.min(360 / Math.max(1, m), Math.max(360 / n, 38));
    }

    function childAngle(parentIdx, j, n, m) {
        return sliceAngle(parentIdx, n) + (j - (m - 1) / 2) * childSpan(n, m);
    }

    function angleDiff(a, b) {
        return Math.abs(((a - b + 540) % 360) - 180);
    }

    // What the pointer points at: { main, child } (-1 = none).
    readonly property var selection: {
        const n = slices.length;
        if (!open || !placed || px < 0 || n === 0)
            return { main: -1, child: -1 };
        const dx = px - cx, dy = py - cy;
        const dist = Math.hypot(dx, dy);
        if (dist < hub)
            return { main: -1, child: -1 };
        const ang = (Math.atan2(dx, -dy) * 180 / Math.PI + 360) % 360;
        if (dist > radius + 6 && ring >= 0) {
            const items = kids(slices[ring]);
            const m = items.length;
            const span = childSpan(n, m);
            const mid = sliceAngle(ring, n);
            if (angleDiff(ang, mid) <= span * m / 2 + 12) {
                let best = 0, bestD = 1e9;
                for (let j = 0; j < m; j++) {
                    const d = angleDiff(ang, childAngle(ring, j, n, m));
                    if (d < bestD) {
                        bestD = d;
                        best = j;
                    }
                }
                return { main: ring, child: best };
            }
        }
        return { main: Math.round(ang / (360 / n)) % n, child: -1 };
    }

    // Pointing at a slice with a submenu opens its ring.
    // (Later: `selection` reads `ring`.)
    onSelectionChanged: Qt.callLater(updateRing)

    function updateRing() {
        const sel = selection;
        if (sel.main >= 0 && sel.child < 0)
            ring = slices[sel.main]?.children ? sel.main : -1;
    }

    readonly property var selectedSlice: selection.main < 0 ? null : selection.child >= 0 ? kids(slices[selection.main])[selection.child] : slices[selection.main]

    // ── Opening ──────────────────────────────────────────────────────────
    function begin(how, screenName) {
        windowId = Niri.focusedWindow?.id ?? null;
        appId = Niri.focusedWindow?.app_id ?? "";
        profileId = profileFor(appId)?.id ?? "";
        screen = screenName || (Niri.focusedWorkspace?.output ?? "");
        source = how;
        sticky = how === "";
        ring = -1;
        open = true;
    }

    // From a keybind: centered on the pointer once the overlay sees it.
    function hold() {
        if (!enabled)
            return;
        if (open) {
            close();
            return;
        }
        cx = cy = px = py = -1;
        begin("key", "");
    }

    // From the desktop (middle button) or a caller that knows the pointer.
    function openAt(screenName, x, y, how) {
        if (!enabled)
            return;
        cx = px = x;
        cy = py = y;
        begin(how ?? "", screenName);
    }

    function pointer(x, y) {
        if (!open)
            return;
        px = x;
        py = y;
        if (cx < 0) {
            cx = x;
            cy = y;
        }
    }

    function close() {
        open = false;
        ring = -1;
    }

    // The held key / button was let go.
    function release() {
        if (!open || sticky)
            return;
        const s = selectedSlice;
        if (s && !s.children)
            activate(s);
        else
            sticky = true; // a tap, or a submenu: pick by clicking
    }

    // A click (or Enter) on the current selection.
    function click() {
        const s = selectedSlice;
        if (!s) {
            if (selection.main < 0 && px >= 0 && Math.hypot(px - cx, py - cy) < hub)
                close();
            return;
        }
        if (s.children) {
            ring = selection.main;
            sticky = true;
            return;
        }
        activate(s);
    }

    // Keyboard: put the (virtual) pointer on slice i / child j.
    function point(i, j) {
        const n = slices.length;
        if (n === 0)
            return;
        i = (i + n) % n;
        let ang = sliceAngle(i, n), r = (hub + radius) / 2;
        if (j !== undefined && j >= 0) {
            const m = kids(slices[i]).length;
            j = (j + m) % m;
            ang = childAngle(i, j, n, m);
            r = ringRadius;
        }
        px = cx + r * Math.sin(ang * Math.PI / 180);
        py = cy - r * Math.cos(ang * Math.PI / 180);
    }

    function activate(slice) {
        const id = slice.action;
        const ctx = { windowId: windowId };
        close();
        pending = () => Actions.run(id, ctx);
        later.restart();
    }

    property var pending: null

    Timer {
        id: later
        interval: 90
        onTriggered: {
            const fn = root.pending;
            root.pending = null;
            if (fn)
                fn();
        }
    }

    IpcHandler {
        target: "radial"

        // Bound to ⌃⌘Space: opens at the pointer; releasing the modifier picks.
        function hold(): void {
            root.hold();
        }
        // Opens to click (no release-to-pick).
        function toggle(): void {
            if (root.open)
                root.close();
            else {
                root.hold();
                root.sticky = true;
            }
        }
        function open(): void {
            if (!root.open) {
                root.hold();
                root.sticky = true;
            }
        }
        function close(): void {
            root.close();
        }
        function release(): void {
            root.release();
        }
        function settings(): void {
            Panels.settingsSection = "radialmenu";
            Panels.settingsOpen = true;
        }
    }
}
