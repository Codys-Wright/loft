pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The theme selector's backend: lists installed theme packs and applies one,
// both through the `loft` CLI (the same engine `loft theme apply` uses,
// so the shell, niri, terminals, GTK and the launcher all switch together).
Singleton {
    id: root

    // [{ name, path, polarity, palette, glass, wallpaper }]
    property var themes: []
    property bool applying: false
    property string error: ""
    // The active theme's light / dark variants (`loft theme state`): which
    // appearances it maps ([] = one look only) and its display name.
    property var modes: []
    property string label: ""
    readonly property bool hasModes: modes.includes("light") && modes.includes("dark")

    function refresh() {
        list.running = true;
        stateProc.running = true;
    }

    // Prefer Light / Prefer Dark: the theme's variant for that appearance,
    // applied everywhere (GTK's color-scheme follows, so apps switch too).
    function setMode(mode) {
        if (applying || !hasModes || mode === (Theme.dark ? "dark" : "light"))
            return;
        error = "";
        applying = true;
        applyProc.command = ["loft", "theme", "apply", "--mode", mode];
        applyProc.running = true;
    }

    function apply(name) {
        if (applying || name === Theme.name)
            return;
        error = "";
        applying = true;
        applyProc.command = ["loft", "theme", "apply", name];
        applyProc.running = true;
    }

    Component.onCompleted: refresh()

    Process {
        id: list
        command: ["loft", "theme", "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                // No output: the `loft` CLI isn't on PATH (or failed) — say so once.
                if (text.trim() === "") {
                    root.error = "Theme list unavailable (is the Loft CLI on PATH?)";
                    return;
                }
                try {
                    root.themes = JSON.parse(text);
                } catch (e) {
                    console.warn(`ThemeManager: bad theme list: ${e}`);
                }
            }
        }
    }

    Process {
        id: stateProc
        command: ["loft", "theme", "state", "--compact"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const s = JSON.parse(text);
                    root.modes = s.modes ?? [];
                    root.label = s.label || s.name || "";
                } catch (e) {
                    root.modes = [];
                }
            }
        }
    }

    Process {
        id: applyProc
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "")
                root.error = text.trim()
        }
        onExited: code => {
            root.applying = false;
            stateProc.running = true;
            if (code !== 0 && root.error === "")
                root.error = `loft theme apply exited with ${code}`;
        }
    }

    IpcHandler {
        target: "themes"

        // Apply the next installed theme (alphabetical).
        function cycle(): void {
            if (root.themes.length === 0)
                return;
            const i = root.themes.findIndex(t => t.name === Theme.name);
            root.apply(root.themes[(i + 1) % root.themes.length].name);
        }

        // Open the theme selector (Settings → Appearance).
        function open(): void {
            root.refresh();
            Panels.settingsSection = "appearance";
            Panels.settingsOpen = true;
        }
    }
}
