pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The active theme: palette + glass state that every component reads.
// Components never hardcode colors — everything goes through here.
//
// Source: $LOFT_THEME_FILE (set by the loft-shell wrapper / loft-dev),
// normally <state>/current/theme.json where `current` is a symlink to the
// active theme. Edits to that file apply live (watched). Re-pointing the
// symlink is NOT visible to the watcher (it follows the old target), so
// applying a theme also calls `qs ipc call theme reload`, which re-resolves
// the path. Defaults below are used for missing keys.
Singleton {
    id: root

    readonly property string file: Quickshell.env("LOFT_THEME_FILE") ?? ""

    readonly property string name: theme.name
    readonly property bool dark: theme.polarity !== "light"

    readonly property color bg: theme.palette.bg
    readonly property color surface: theme.palette.surface
    readonly property color overlay: theme.palette.overlay
    readonly property color paletteText: theme.palette.text
    readonly property color paletteSubtext: theme.palette.subtext
    // Text on panels and windows is always the palette's. Adapting it
    // globally to "the wallpaper" picked black text from one screen's
    // wallpaper for every surface on every screen (white-glow black text on
    // dark glass). Only the menu bar adapts, per screen (barTextFor), since
    // it sits directly on that screen's wallpaper; a surface that needs it
    // can opt in with onGlassFor(strength, screen).
    readonly property color text: paletteText
    readonly property color subtext: paletteSubtext
    readonly property color accent: theme.palette.accent
    readonly property color accent2: theme.palette.accent2
    readonly property color urgent: theme.palette.urgent
    readonly property color ok: theme.palette.ok
    readonly property color warn: theme.palette.warn

    // ── Liquid Glass (docs/DESIGN-GOLDEN-GATE.md) ───────────────────────
    // Every glass surface reads its material from here; nothing picks its
    // own opacity. Runtime choices (Settings.appearance) win over the theme.

    // Settings → Appearance → Reduce transparency: flat opaque fills, no blur.
    readonly property bool reduceTransparency: Settings.appearance.reduceTransparency === true

    // The Liquid Glass slider: 0 = ultraclear … 1 = fully tinted. The theme's
    // glass.opacity is its default. `glassPreview` (≥ 0) shows a value live
    // while the slider is dragged, without writing the settings file.
    property real glassPreview: -1
    readonly property real glassDefault: theme.glass.opacity
    readonly property real glass: clamp(glassPreview >= 0 ? glassPreview : Settings.appearance.glass >= 0 ? Settings.appearance.glass : glassDefault, 0, 1)

    readonly property bool blur: !reduceTransparency && (Settings.appearance.blur >= 0 ? Settings.appearance.blur === 1 : theme.glass.blur)
    // Fill opacity of a strength-1 surface. The slider maps 1:1 (so a theme's
    // default looks exactly as before), kept just off fully clear / opaque.
    readonly property real glassOpacity: reduceTransparency ? 1 : clamp(glass, 0.03, 0.95)
    // Tint strength: the theme's tint at and above its default, fading toward
    // a neutral clear glass as the slider goes toward ultraclear.
    readonly property real glassTintAmount: 0.3 + 0.7 * Math.min(1, glass / Math.max(0.05, glassDefault))
    readonly property color glassTint: mix(dark ? "#1f1f23" : "#f5f5f7", theme.glass.tint, glassTintAmount)
    readonly property color glassFill: withAlpha(glassTint, glassOpacity)
    readonly property color glassBorder: reduceTransparency ? withAlpha(overlay, 0.9) : withAlpha(theme.glass.border, theme.glass.borderOpacity)

    // Depth (Golden Gate): a darkened inner rim and a brighter top specular.
    readonly property real edgeDarken: theme.glass.edgeDarken >= 0 ? theme.glass.edgeDarken : dark ? 0.35 : 0.18
    readonly property real specular: theme.glass.specular >= 0 ? theme.glass.specular : dark ? 0.5 : 0.75
    readonly property color edgeColor: withAlpha("#000000", edgeDarken * 0.55)
    readonly property color specularColor: withAlpha("#ffffff", Math.min(1, specular * (dark ? 0.55 : 0.95)))
    readonly property color sheenColor: withAlpha("#ffffff", specular * (dark ? 0.09 : 0.2))
    // Inactive windows dim their glass slightly (GlassSurface.active).
    readonly property real inactiveDim: 0.07

    // Text shadow on glass: none at the theme's default and above, growing
    // as the glass gets clearer (legibility over the wallpaper); off with
    // Reduce transparency.
    readonly property real textShadowStrength: reduceTransparency ? 0 : clamp((glassDefault - glass) / Math.max(0.05, glassDefault), 0, 1)
    // Dark under light text, a light glow under dark text.
    readonly property color textShadow: luminance(text) > 0.3 ? withAlpha("#000000", 0.75 * textShadowStrength) : withAlpha("#ffffff", 0.45 * textShadowStrength)

    // Fill of a glass surface of the given strength (1 = as the theme says;
    // panels and windows use more).
    function glassAlpha(strength) {
        return reduceTransparency ? 1 : Math.min(0.97, glassOpacity * strength);
    }
    function fillFor(strength) {
        return reduceTransparency ? flatFill(strength) : withAlpha(glassTint, glassAlpha(strength));
    }
    // Clear glass (the dock, floating controls): a light frost rather than
    // the theme's tint, so the blurred wallpaper reads through — Golden
    // Gate's Liquid Glass. Follows the slider: clearer below the theme's
    // default, blending into the regular tinted glass toward fully tinted.
    function clearFillFor(strength) {
        if (reduceTransparency)
            return flatFill(strength);
        const a0 = (dark ? 0.12 : 0.3) * Math.min(1.6, strength) * (0.35 + 0.65 * Math.min(1, glass / Math.max(0.05, glassDefault)));
        const k = glass > glassDefault ? (glass - glassDefault) / Math.max(0.05, 1 - glassDefault) : 0;
        const c = mix("#ffffff", glassTint, k);
        return withAlpha(c, a0 + (glassAlpha(strength) - a0) * k);
    }
    // Reduce transparency: opaque theme colors. Windows (high strength) sit
    // near bg, cards and tiles inside them (low strength) nearer surface.
    function flatFill(strength) {
        return mix(bg, surface, clamp(1.15 - 0.45 * strength, 0.15, 0.9));
    }

    // ── Contrast-aware text ─────────────────────────────────────────────
    // What a glass surface of `strength` looks like over the wallpaper of
    // `screen` (WallpaperTone; "" = the first screen), and a text color that
    // reads on it: the theme's text when it does (≥ 4.5:1), else white or
    // black, whichever reads better.
    function glassBackdrop(strength, screen, clear) {
        if (reduceTransparency)
            return flatFill(strength);
        const wall = WallpaperTone.meanColor(screen ?? "") ?? (dark ? Qt.color("#000000") : Qt.color("#ffffff"));
        const fill = clear ? clearFillFor(strength) : withAlpha(glassTint, glassAlpha(strength));
        return mix(wall, Qt.rgba(fill.r, fill.g, fill.b, 1), fill.a);
    }
    function onGlassFor(strength, screen, clear) {
        return readableOn(glassBackdrop(strength, screen, clear), paletteText);
    }
    function onGlassSubtextFor(strength, screen) {
        const c = onGlassFor(strength, screen);
        return Qt.colorEqual(c, paletteText) ? paletteSubtext : withAlpha(c, 0.68);
    }
    // For a window-strength surface on the first screen.
    readonly property color onGlass: onGlassFor(1.7, "")
    readonly property color onGlassSubtext: onGlassSubtextFor(1.7, "")

    function readableOn(bgColor, preferred) {
        if (preferred !== undefined && contrast(preferred, bgColor) >= 4.5)
            return Qt.color(preferred);
        return contrast("#ffffff", bgColor) >= contrast("#000000", bgColor) ? Qt.color("#ffffff") : Qt.color("#1d1d1f");
    }
    function luminance(c) {
        const q = typeof c === "string" ? Qt.color(c) : c;
        const lin = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
        return 0.2126 * lin(q.r) + 0.7152 * lin(q.g) + 0.0722 * lin(q.b);
    }
    function contrast(a, b) {
        const la = luminance(a), lb = luminance(b);
        return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
    }

    // ── Menu bar ────────────────────────────────────────────────────────
    // Golden Gate: no background; text and icons turn light or dark with the
    // wallpaper under the bar (per output, WallpaperTone), with a soft
    // shadow. "Show menu bar background" brings the glass strip back.
    // Reduce transparency always gives the bar its (then flat) background.
    readonly property bool barBackground: reduceTransparency || (Settings.appearance.barBackground >= 0 ? Settings.appearance.barBackground === 1 : theme.bar.background)
    readonly property bool barAdaptiveText: Settings.appearance.barAdaptiveText >= 0 ? Settings.appearance.barAdaptiveText === 1 : theme.bar.adaptiveText
    // Whether the bar on `screen` uses dark text.
    function barDarkTextFor(screen) {
        if (barBackground)
            return luminance(onGlassFor(0.8, screen, true)) < 0.4;
        if (!barAdaptiveText)
            return !dark;
        const l = WallpaperTone.barLuminance(screen ?? "");
        // Unknown (not sampled yet / no ffmpeg): follow the theme.
        return l < 0 ? !dark : l > 0.3;
    }
    function barTextFor(screen) {
        if (barBackground)
            return onGlassFor(0.8, screen, true);
        if (!barAdaptiveText)
            return text;
        return barDarkTextFor(screen) ? withAlpha("#000000", 0.85) : Qt.color("#ffffff");
    }
    function barSubtextFor(screen) {
        return withAlpha(barTextFor(screen), 0.62);
    }
    // The color of text drawn on a pill of barTextFor (e.g. the active workspace).
    function barOnTextFor(screen) {
        return barDarkTextFor(screen) ? Qt.color("#ffffff") : Qt.color("#1d1d1f");
    }
    function barShadowFor(screen) {
        if (barBackground)
            return "transparent";
        return barDarkTextFor(screen) ? withAlpha("#ffffff", 0.35) : withAlpha("#000000", 0.5);
    }
    // First-screen shorthands; per-output components use the *For(screen) forms.
    readonly property color barText: barTextFor("")
    readonly property color barSubtext: barSubtextFor("")
    readonly property color barShadow: barShadowFor("")

    // ── Shape ───────────────────────────────────────────────────────────
    // Shell surfaces (legacy glass.radius), then Golden Gate's radii: one
    // radius for every window (niri's rule uses the same token), panels and
    // popovers, controls.
    readonly property real radius: theme.glass.radius
    readonly property real windowRadius: theme.shape.windowRadius >= 0 ? theme.shape.windowRadius : theme.radii.window
    readonly property real panelRadius: theme.shape.panelRadius
    readonly property real controlRadius: theme.shape.controlRadius

    // Traffic lights (close / hide / full screen): Aqua colors, the same in
    // every theme; grey in an inactive window.
    readonly property color trafficClose: "#ff5f57"
    readonly property color trafficHide: "#febc2e"
    readonly property color trafficZoom: "#28c840"
    readonly property color trafficInactive: withAlpha(paletteText, 0.22)

    // Sidebar icon badges (System Settings style): the Apple system colors,
    // light and dark variants.
    function badgeColor(name) {
        const c = {
            red: ["#ff3b30", "#ff453a"],
            orange: ["#ff9500", "#ff9f0a"],
            yellow: ["#ffcc00", "#ffd60a"],
            green: ["#34c759", "#30d158"],
            mint: ["#00c7be", "#63e6e2"],
            teal: ["#30b0c7", "#40c8e0"],
            cyan: ["#32ade6", "#64d2ff"],
            blue: ["#007aff", "#0a84ff"],
            indigo: ["#5856d6", "#5e5ce6"],
            purple: ["#af52de", "#bf5af2"],
            pink: ["#ff2d55", "#ff375f"],
            brown: ["#a2845e", "#ac8e68"],
            gray: ["#8e8e93", "#8e8e93"],
            graphite: ["#3a3a3c", "#48484a"]
        }[name] ?? null;
        return c ? Qt.color(c[dark ? 1 : 0]) : accent;
    }

    readonly property var wallpaperGradient: theme.wallpaper.gradient
    // A theme pack's wallpaper image, relative to the pack (theme.json's dir).
    readonly property string wallpaperImage: theme.wallpaper.image ? (theme.wallpaper.image.startsWith("/") ? theme.wallpaper.image : file.replace(/[^/]*$/, "") + theme.wallpaper.image) : ""

    // Fonts ship with the shell (store paths from the wrapper) so it looks the
    // same on any machine; fall back to whatever the system has.
    readonly property string fontUi: uiFont.status === FontLoader.Ready ? uiFont.name : "Adwaita Sans"
    readonly property string fontIcons: iconFont.status === FontLoader.Ready ? iconFont.name : "JetBrainsMono Nerd Font"

    FontLoader {
        id: uiFont
        source: Quickshell.env("LOFT_UI_FONT") ? "file://" + Quickshell.env("LOFT_UI_FONT") : ""
    }

    FontLoader {
        id: iconFont
        source: Quickshell.env("LOFT_ICON_FONT") ? "file://" + Quickshell.env("LOFT_ICON_FONT") : ""
    }

    function withAlpha(c, a) {
        const q = typeof c === "string" ? Qt.color(c) : c;
        return Qt.rgba(q.r, q.g, q.b, a);
    }

    // Linear blend from a (t = 0) to b (t = 1), opaque.
    function mix(a, b, t) {
        const p = typeof a === "string" ? Qt.color(a) : a;
        const q = typeof b === "string" ? Qt.color(b) : b;
        return Qt.rgba(p.r + (q.r - p.r) * t, p.g + (q.g - p.g) * t, p.b + (q.b - p.b) * t, 1);
    }

    function clamp(v, lo, hi) {
        return Math.max(lo, Math.min(hi, v));
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
        // A rewrite by `loft theme apply` can briefly remove the file.
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
                // -1: the polarity's default (older rendered themes lack them).
                property real edgeDarken: -1
                property real specular: -1
            }

            property JsonObject shape: JsonObject {
                // -1: radii.window (older rendered themes).
                property real windowRadius: -1
                property real panelRadius: 18
                property real controlRadius: 8
            }

            property JsonObject radii: JsonObject {
                property real window: 12
            }

            property JsonObject bar: JsonObject {
                property bool adaptiveText: true
                property bool background: false
            }

            property JsonObject wallpaper: JsonObject {
                property list<string> gradient: ["#16161e", "#2a3a6e", "#6b4fa3"]
                property string image: ""
            }
        }
    }
}
