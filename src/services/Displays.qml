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

    // connector → niri identity, from `niri msg -j outputs`.
    property var identities: ({})

    readonly property var screens: Quickshell.screens

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

    // A tiled window on the display's active workspace that covers the whole
    // display (niri has no fullscreen flag in its IPC; fullscreen windows are
    // exactly output-sized, maximized ones leave room for the bar).
    function fullscreenOn(screen) {
        if (!screen)
            return false;
        const ws = Niri.workspaces.find(w => w.output === screen.name && w.is_active);
        if (!ws)
            return false;
        return Niri.windows.some(w => {
            const size = w.layout?.window_size;
            return w.workspace_id === ws.id && !w.is_floating && size && size[0] >= screen.width && size[1] >= screen.height;
        });
    }

    readonly property bool mainFullscreen: fullscreenOn(mainScreen)
    readonly property var activeScreen: mainFullscreen && fallbackScreen ? fallbackScreen : mainScreen
    readonly property string activeName: activeScreen?.name ?? ""

    function isActive(screen) {
        return !!screen && screen.name === activeName;
    }

    function refresh() {
        outputs.running = true;
    }

    Component.onCompleted: refresh()

    Connections {
        target: Niri
        function onOutputsChanged() {
            root.refresh();
        }
    }

    Process {
        id: outputs
        command: ["niri", "msg", "-j", "outputs"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const m = {};
                    for (const [name, o] of Object.entries(JSON.parse(text)))
                        m[name] = `${o.make} ${o.model} ${o.serial ?? "Unknown"}`;
                    root.identities = m;
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
