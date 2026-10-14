pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Shell settings. Source: $STUDIO_SETTINGS_FILE (watched). Defaults below
// are the product defaults (PLAN §4.1 layer 1); the consumer's defaults and
// runtime overrides will be merged into the file the shell reads.
Singleton {
    id: root

    readonly property alias dock: settings.dock

    FileView {
        path: Quickshell.env("STUDIO_SETTINGS_FILE") ?? ""
        watchChanges: true
        onFileChanged: reload()

        JsonAdapter {
            id: settings

            property JsonObject dock: JsonObject {
                // Desktop-entry ids / niri app-ids, left to right.
                property list<string> pinned: ["org.gnome.Nautilus", "firefox", "kitty", "com.mitchellh.ghostty", "obsidian"]
                property real iconSize: 48
                property real magnification: 1.3
            }
        }
    }
}
