pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Which display carries the dock and the menu bar's status area.
//
// The menu bar is on every display; the dock and the right side of the bar
// (status extras, tray, Control Center) live on one display: the main one, or
// the fallback while something on the main display is fullscreen.
//
// Settings.displays.main / .fallback name a display by niri's identity
// ("Make Model Serial", which survives connector renumbering) or by connector.
// Empty = automatic: main = the largest display, fallback = the nearest
// display to its right (else to its left).
Singleton {
    id: root

    // connector → niri identity, from `niri msg -j outputs` (under KWin:
    // loft-kwin rebuilds the same "Make Model Serial" from KWin's outputs).
    property var identities: ({})
    // connector → model name (for labels: "MPG491CX OLED").
    property var models: ({})

    readonly property bool fromKWin: Compositor.backend === "kwin"

    // Outputs that are off drop out of KWin's screens: keep what was learnt.
    function fromKWinOutputs() {
        const m = Object.assign({}, identities), models = Object.assign({}, root.models);
        for (const o of KWin.displays) {
            m[o.name] = o.identity;
            models[o.name] = o.model || o.name;
        }
        identities = m;
        root.models = models;
    }

    Connections {
        target: KWin
        enabled: root.fromKWin
        function onDisplaysChanged() {
            root.fromKWinOutputs();
        }
    }

    readonly property var screens: Quickshell.screens

    // ── Output settings (Settings → Displays, IdentifyOverlay) ────────────
    // One interface, either backend: niri's through loft-niri (NiriSettings,
    // recorded by identity in Loft's overrides), KWin's through KScreen
    // (kscreen-doctor; KScreen saves them itself). Records have loft-niri's
    // `outputs` shape: name, identity, description, modes, mode, scale,
    // transform, logical, enabled, vrr_supported, vrr_enabled, …; KScreen's
    // add primary, can_disable, hdr_supported, hdr_enabled, vrr_policy.
    readonly property var outputs: fromKWin ? KScreen.outputs : NiriSettings.outputs
    // identity → Loft's recorded override (niri only).
    readonly property var overrides: fromKWin ? ({}) : NiriSettings.outputOverrides
    readonly property string error: fromKWin ? KScreen.error : NiriSettings.error
    // What the page may offer beyond the common set.
    //   record    changes are Loft's overrides (Reset, "changed here")
    //   primary   KDE's primary display; hdr: HDR on/off
    //   backend   who reports the outputs, for messages
    readonly property var outputCaps: fromKWin ? {
        record: false,
        primary: true,
        hdr: true,
        backend: "KDE (KScreen)"
    } : {
        record: true,
        primary: false,
        hdr: false,
        backend: "niri"
    }

    function outputByName(name) {
        return outputs.find(o => o.name === name) ?? null;
    }

    // changes: { "<identity or connector>": { mode, scale, transform,
    // position: {x, y}, off, vrr, hdr, primary } }. `live` applies them,
    // `record` keeps them (niri: Loft's overrides; KWin: already kept).
    function setOutputs(changes, live, record, done) {
        if (fromKWin)
            KScreen.setOutputs(changes, live, record, done);
        else
            NiriSettings.setOutputs(changes, live, record, done);
    }

    function resetOutputs(list) {
        if (!fromKWin)
            NiriSettings.apply({ reset_outputs: list });
    }

    function refreshOutputs() {
        if (fromKWin)
            KScreen.refresh();
        else
            NiriSettings.refresh();
    }

    // Identify: every screen flashes its name (IdentifyOverlay).
    property bool identifying: false

    function identify() {
        identifying = true;
        identifyTimer.restart();
    }

    Timer {
        id: identifyTimer
        interval: 2500
        onTriggered: root.identifying = false
    }

    function identity(name) {
        return identities[name] ?? name;
    }

    function resolve(pref) {
        if (!pref)
            return null;
        return screens.find(s => s.name === pref || identity(s.name) === pref) ?? null;
    }

    readonly property var mainScreen: resolve(Settings.displays.main) ?? [...screens].sort((a, b) => b.width * b.height - a.width * a.height)[0] ?? null

    readonly property var fallbackScreen: {
        const m = mainScreen;
        const chosen = resolve(Settings.displays.fallback);
        if (chosen && chosen !== m)
            return chosen;
        if (!m)
            return null;
        const others = screens.filter(s => s !== m);
        const right = others.filter(s => s.x >= m.x + m.width).sort((a, b) => a.x - b.x);
        const left = others.filter(s => s.x + s.width <= m.x).sort((a, b) => b.x - a.x);
        return right[0] ?? left[0] ?? others[0] ?? null;
    }

    // The display's active workspace shows a fullscreen window: a tiled
    // window in the workspace's active column whose tile covers the whole
    // display. niri 26.04 has no fullscreen flag in its IPC; a fullscreen
    // tile is exactly output-sized (a fixed-size window sits centred on a
    // black backdrop the tile includes), while maximized and
    // maximized-to-edges windows keep out of the bar's exclusive zone. This
    // is when niri draws the Top layer (the bar) under the window
    // (render_above_top_layer: the active column is fullscreen). With a
    // floating window focused the active column is unknown: any fullscreen
    // tile counts.
    function fullscreenOn(screen) {
        if (!screen)
            return false;
        const ws = Compositor.workspaces.find(w => w.output === screen.name && w.is_active);
        if (!ws)
            return false;
        const active = Compositor.windowMap[ws.active_window_id] ?? null;
        const column = active && !active.is_floating ? active.layout?.pos_in_scrolling_layout?.[0] : undefined;
        // KWin has no tiling: every window counts as floating there, so the
        // column test below never matches. Its windows say fullscreen outright.
        if (Compositor.backend === "kwin")
            return fullscreenWindowOn(screen) !== null;
        return Compositor.windows.some(w => {
            const size = w.layout?.tile_size;
            if (w.workspace_id !== ws.id || w.is_floating || !size || size[0] < screen.width - 1 || size[1] < screen.height - 1)
                return false;
            return column === undefined || w.layout?.pos_in_scrolling_layout?.[0] === column;
        });
    }

    // KWin: the fullscreen window on the display's current desktop and
    // Activity (the focused one first), or null. The bar's title strip acts
    // on it (Bar.qml).
    function fullscreenWindowOn(screen) {
        if (!screen || Compositor.backend !== "kwin")
            return null;
        const ws = Compositor.workspaces.find(w => w.output === screen.name && w.is_active);
        if (!ws)
            return null;
        const all = Compositor.windows.filter(w => {
            const acts = w.kwin_activities ?? [];
            const here = acts.length === 0 || acts.includes(KWin.currentActivity);
            return w.workspace_id === ws.id && w.is_fullscreen === true && !w.is_minimized && here;
        });
        return all.find(w => w.is_focused) ?? all[0] ?? null;
    }

    readonly property bool mainFullscreen: fullscreenOn(mainScreen)
    readonly property var activeScreen: mainFullscreen && fallbackScreen ? fallbackScreen : mainScreen
    readonly property string activeName: activeScreen?.name ?? ""

    function isActive(screen) {
        return !!screen && screen.name === activeName;
    }

    function refresh() {
        if (fromKWin)
            fromKWinOutputs();
        else
            niriOutputs.running = true;
    }

    Component.onCompleted: refresh()

    Connections {
        target: Compositor
        function onOutputsChanged() {
            root.refresh();
        }
    }

    Process {
        id: niriOutputs
        command: ["niri", "msg", "-j", "outputs"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const m = {}, models = {};
                    for (const [name, o] of Object.entries(JSON.parse(text))) {
                        m[name] = `${o.make} ${o.model} ${o.serial ?? "Unknown"}`;
                        models[name] = o.model || name;
                    }
                    root.identities = m;
                    root.models = models;
                } catch (e) {
                    console.warn(`Displays: ${e}`);
                }
            }
        }
    }

    IpcHandler {
        target: "displays"

        function status(): string {
            return JSON.stringify({
                main: root.mainScreen?.name ?? null,
                fallback: root.fallbackScreen?.name ?? null,
                mainFullscreen: root.mainFullscreen,
                active: root.activeName
            });
        }
    }
}
