pragma Singleton

import QtQuick

// The greeter's Theme: the same API as the shell's src/services/Theme.qml
// (which needs Quickshell, absent in sddm-greeter), so the shared design and
// glass components run unchanged under SDDM.
//
// Main.qml calls load() with candidate theme.json paths: the greeter pack
// (/var/lib/studio-linux/greeter, machine-wide, PLAN §4.5), then the bundled
// default. Reading files through XMLHttpRequest needs
// QML_XHR_ALLOW_FILE_READ=1 in the greeter environment; without it the
// defaults below (the built-in default theme) are used.
QtObject {
    id: root

    property var json: ({})
    readonly property var pal: json.palette ?? {}
    readonly property var glass: json.glass ?? {}

    readonly property string file: ""
    readonly property string name: json.name ?? "default"
    readonly property bool dark: (json.polarity ?? "dark") !== "light"

    readonly property color bg: pal.bg ?? "#1a1b26"
    readonly property color surface: pal.surface ?? "#24283b"
    readonly property color overlay: pal.overlay ?? "#414868"
    readonly property color text: pal.text ?? "#c0caf5"
    readonly property color subtext: pal.subtext ?? "#a9b1d6"
    readonly property color accent: pal.accent ?? "#7aa2f7"
    readonly property color accent2: pal.accent2 ?? "#bb9af7"
    readonly property color urgent: pal.urgent ?? "#f7768e"
    readonly property color ok: pal.ok ?? "#9ece6a"
    readonly property color warn: pal.warn ?? "#e0af68"

    readonly property bool blur: glass.blur ?? true
    readonly property real glassOpacity: glass.opacity ?? 0.45
    readonly property color glassFill: withAlpha(glass.tint ?? "#1a1b26", glassOpacity)
    readonly property color glassBorder: withAlpha(glass.border ?? "#ffffff", glass.borderOpacity ?? 0.14)
    readonly property real radius: glass.radius ?? 14

    // The material API GlassSurface reads (src/services/Theme.qml). The
    // greeter has no runtime settings: the theme's glass, never reduced.
    readonly property bool reduceTransparency: false
    readonly property real glassDefault: glassOpacity
    readonly property real textShadowStrength: 0
    readonly property color textShadow: "transparent"
    readonly property color glassTint: glass.tint ?? "#1a1b26"
    readonly property real edgeDarken: glass.edgeDarken ?? (dark ? 0.35 : 0.18)
    readonly property real specular: glass.specular ?? (dark ? 0.5 : 0.75)
    readonly property color edgeColor: withAlpha("#000000", edgeDarken * 0.55)
    readonly property color specularColor: withAlpha("#ffffff", Math.min(1, specular * (dark ? 0.55 : 0.95)))
    readonly property color sheenColor: withAlpha("#ffffff", specular * (dark ? 0.09 : 0.2))
    readonly property real inactiveDim: 0.07
    readonly property real windowRadius: json.shape?.windowRadius ?? json.radii?.window ?? 12
    readonly property real panelRadius: json.shape?.panelRadius ?? 18
    readonly property real controlRadius: json.shape?.controlRadius ?? 8

    function glassAlpha(strength) {
        return Math.min(0.97, glassOpacity * strength);
    }
    function fillFor(strength) {
        return withAlpha(glassTint, glassAlpha(strength));
    }
    function clearFillFor(strength) {
        return withAlpha("#ffffff", (dark ? 0.12 : 0.3) * Math.min(1.6, strength));
    }

    readonly property var wallpaperGradient: json.wallpaper?.gradient ?? ["#16161e", "#2a3a6e", "#6b4fa3"]

    // Bundled next to the theme (copied in by nix/lock.nix).
    readonly property string fontUi: uiFont.status === FontLoader.Ready ? uiFont.name : "sans-serif"
    readonly property string fontIcons: iconFont.status === FontLoader.Ready ? iconFont.name : "Symbols Nerd Font"

    property FontLoader uiFont: FontLoader {
        source: Qt.resolvedUrl("../fonts/InterVariable.ttf")
    }

    property FontLoader iconFont: FontLoader {
        source: Qt.resolvedUrl("../fonts/SymbolsNerdFont-Regular.ttf")
    }

    function withAlpha(c, a) {
        const q = typeof c === "string" ? Qt.color(c) : c;
        return Qt.rgba(q.r, q.g, q.b, a);
    }

    // Use the first candidate that reads and parses.
    function load(candidates) {
        if (candidates.length === 0)
            return;
        const c = String(candidates[0]); // Qt.resolvedUrl() gives a url, not a string
        const url = c.startsWith("/") ? "file://" + c : c;
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            try {
                if (xhr.responseText) {
                    root.json = JSON.parse(xhr.responseText);
                    return;
                }
            } catch (e) {
                console.warn(`studio greeter: ${url}: ${e}`);
            }
            root.load(candidates.slice(1));
        };
        try {
            xhr.open("GET", url);
            xhr.send();
        } catch (e) {
            console.warn(`studio greeter: cannot read ${url}: ${e}`);
            root.load(candidates.slice(1));
        }
    }
}
