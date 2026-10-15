pragma Singleton

import QtQuick
import Quickshell
import qs.menubar
import qs.services

// Quit protection: hold ⌘Q to quit (Chrome's "Hold ⌘Q to quit").
//
// niri runs the bind, not the app: Mod+Q / Super+Q (and Alt+F4, which
// xremap's macOS layout sends for ⌘Q) call `quit keyAt <ms>` (niri/shell-binds).
// niri has no key-release events for binds, but it repeats a held bind
// (repeat-delay, then repeat-rate, throttled by the bind's cooldown-ms), and
// xremap re-sends a held ⌘Q as fresh Alt+F4 presses — so a hold is a burst
// of calls, and a release is the burst stopping:
//
//   first call       the pill: "Hold ⌘Q to quit <App>", the ring starts
//   more calls       keep it going (before the first repeat: up to
//                    firstGapMs of silence; after: repeatGapMs)
//   silence          let go → cancelled, the pill fades
//   held holdMs      quit the app (MenuState.doQuitApp, no confirm card:
//                    holding was the confirmation)
//
// Apps without protection keep the old behavior (close the focused window),
// once per burst, so a held key no longer closes window after window.
Singleton {
    id: root

    readonly property bool enabled: Features.on("quitProtection")
    readonly property int holdMs: Math.max(300, EverydayConfig.quit.holdMs)
    readonly property int firstGapMs: 800
    readonly property int repeatGapMs: 400

    // The hold in progress (or the last one, while the pill fades).
    property var window: null
    property string appId: ""
    property real startedAt: 0
    property real lastAt: 0
    property bool repeating: false
    property bool holding: false
    property real progress: 0
    // "hold" | "quitting" | "cancelled" | "" — what the pill says.
    property string phase: ""

    function isProtected(appId) {
        if (!enabled || !appId || Apps.own[appId] !== undefined)
            return false;
        return EverydayConfig.quit.protectAll || EverydayConfig.has(EverydayConfig.quit.protect, appId);
    }

    function setProtected(appId, on) {
        EverydayConfig.quit.protect = EverydayConfig.toggled(EverydayConfig.quit.protect, appId, on);
    }

    // A check item for the dock's Options ▸.
    function menuItem(appId) {
        const on = isProtected(appId);
        return { key: "quit-protect", label: "Hold ⌘Q to Quit", enabled: enabled && !EverydayConfig.quit.protectAll && Apps.own[appId] === undefined, toggle: "check", checked: on, run: () => root.setProtected(appId, !on) };
    }

    property real lastPlainAt: 0

    // The bind fired (press or repeat).
    function key() {
        const now = Date.now();
        const w = Niri.focusedWindow;
        if (!w)
            return;
        if (!isProtected(w.app_id)) {
            // One close per burst of repeats.
            const burst = now - lastPlainAt < repeatGapMs;
            lastPlainAt = now;
            if (!burst)
                Niri.action("CloseWindow", { id: w.id });
            return;
        }
        if (holding && window && window.id === w.id) {
            if (now - startedAt > 120)
                repeating = true;
            lastAt = now;
            return;
        }
        window = w;
        appId = w.app_id;
        startedAt = now;
        lastAt = now;
        repeating = false;
        progress = 0;
        holding = true;
        phase = "hold";
        tick.start();
    }

    function cancel() {
        holding = false;
        tick.stop();
        phase = "cancelled";
        fade.restart();
    }

    function finish() {
        holding = false;
        tick.stop();
        progress = 1;
        phase = "quitting";
        fade.restart();
        if (Niri.windowMap[window.id])
            MenuState.doQuitApp(appId);
    }

    Timer {
        id: tick
        interval: 16
        repeat: true
        onTriggered: {
            const now = Date.now();
            const quiet = now - root.lastAt;
            if (quiet > (root.repeating ? root.repeatGapMs : root.firstGapMs)) {
                root.cancel();
                return;
            }
            root.progress = Math.min(1, (now - root.startedAt) / root.holdMs);
            if (root.progress >= 1 && root.repeating)
                root.finish();
        }
    }

    // How long the pill stays after a release or a quit.
    Timer {
        id: fade
        interval: root.phase === "quitting" ? 700 : 1400
        onTriggered: root.phase = ""
    }
}
