pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The theme selector's backend: lists installed theme packs and applies one,
// both through the `studio` CLI (the same engine `studio theme apply` uses,
// so the shell, niri, terminals, GTK and the launcher all switch together).
Singleton {
    id: root

    // [{ name, path, polarity, palette, glass, wallpaper }]
    property var themes: []
    property bool applying: false
    property string error: ""

    function refresh() {
        list.running = true;
    }

    function apply(name) {
        if (applying || name === Theme.name)
            return;
        error = "";
        applying = true;
        applyProc.command = ["studio", "theme", "apply", name];
        applyProc.running = true;
    }

    Component.onCompleted: refresh()

    Process {
        id: list
        command: ["studio", "theme", "list", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.themes = JSON.parse(text);
                } catch (e) {
                    console.warn(`ThemeManager: bad theme list: ${e}`);
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
            if (code !== 0 && root.error === "")
                root.error = `studio theme apply exited with ${code}`;
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
