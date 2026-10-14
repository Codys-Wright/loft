pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The active theme: palette + glass state that every component reads.
// Components never hardcode colors — everything goes through here.
//
// Source: $STUDIO_THEME_FILE (set by the studio-shell wrapper / studio-dev),
// normally <state>/current/theme.json where `current` is a symlink to the
// active theme. Edits to that file apply live (watched). Re-pointing the
// symlink is NOT visible to the watcher (it follows the old target), so
// applying a theme also calls `qs ipc call theme reload`, which re-resolves
// the path. Defaults below are used for missing keys.
Singleton {
    id: root

    readonly property string file: Quickshell.env("STUDIO_THEME_FILE") ?? ""

    readonly property string name: theme.name
    readonly property bool dark: theme.polarity !== "light"

    readonly property color bg: theme.palette.bg
    readonly property color surface: theme.palette.surface
    readonly property color overlay: theme.palette.overlay
    readonly property color text: theme.palette.text
    readonly property color subtext: theme.palette.subtext
    readonly property color accent: theme.palette.accent
    readonly property color accent2: theme.palette.accent2
    readonly property color urgent: theme.palette.urgent
    readonly property color ok: theme.palette.ok
    readonly property color warn: theme.palette.warn

    // Glass: a tinted, semi-transparent fill the compositor blurs behind.
    readonly property bool blur: theme.glass.blur
    readonly property real glassOpacity: theme.glass.opacity
    readonly property color glassFill: withAlpha(theme.glass.tint, theme.glass.opacity)
    readonly property color glassBorder: withAlpha(theme.glass.border, theme.glass.borderOpacity)
    readonly property real radius: theme.glass.radius

    readonly property var wallpaperGradient: theme.wallpaper.gradient

    // Fonts ship with the shell (store paths from the wrapper) so it looks the
    // same on any machine; fall back to whatever the system has.
    readonly property string fontUi: uiFont.status === FontLoader.Ready ? uiFont.name : "Adwaita Sans"
    readonly property string fontIcons: iconFont.status === FontLoader.Ready ? iconFont.name : "JetBrainsMono Nerd Font"

    FontLoader {
        id: uiFont
        source: Quickshell.env("STUDIO_UI_FONT") ? "file://" + Quickshell.env("STUDIO_UI_FONT") : ""
    }

    FontLoader {
        id: iconFont
        source: Quickshell.env("STUDIO_ICON_FONT") ? "file://" + Quickshell.env("STUDIO_ICON_FONT") : ""
    }

    function withAlpha(c, a) {
        const q = typeof c === "string" ? Qt.color(c) : c;
        return Qt.rgba(q.r, q.g, q.b, a);
    }

    IpcHandler {
        target: "theme"

        // Re-resolve the theme path (after `current` was re-pointed) and reload.
        function reload(): void {
            view.path = "";
            view.path = root.file;
        }

        function current(): string {
            return root.name;
        }
    }

    FileView {
        id: view
        path: root.file
        watchChanges: true
        onFileChanged: reload()
        // A rewrite by `studio theme apply` can briefly remove the file.
        onLoadFailed: error => console.warn(`Theme: cannot load ${root.file}: ${error}`)

        JsonAdapter {
            id: theme

            property string name: "default"
            property string polarity: "dark"

            property JsonObject palette: JsonObject {
                property string bg: "#1a1b26"
                property string surface: "#24283b"
                property string overlay: "#414868"
                property string text: "#c0caf5"
                property string subtext: "#a9b1d6"
                property string accent: "#7aa2f7"
                property string accent2: "#bb9af7"
                property string urgent: "#f7768e"
                property string ok: "#9ece6a"
                property string warn: "#e0af68"
            }

            property JsonObject glass: JsonObject {
                property bool blur: true
                property string tint: "#1a1b26"
                property real opacity: 0.45
                property string border: "#ffffff"
                property real borderOpacity: 0.14
                property real radius: 14
            }

            property JsonObject wallpaper: JsonObject {
                property list<string> gradient: ["#16161e", "#2a3a6e", "#6b4fa3"]
            }
        }
    }
}
