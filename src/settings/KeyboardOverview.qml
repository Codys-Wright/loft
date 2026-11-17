import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Keyboard & Mouse, top: layout, key repeat and how many
// shortcuts and remaps are set, then the keyboard's sub-pages (Shortcuts,
// Remaps, Snippets). The keyboard / mouse / trackpad settings follow
// (InputPage).
ColumnLayout {
    id: overview
    spacing: 12

    readonly property bool kde: Compositor.backend === "kwin"
    readonly property string layout: kde ? "" : (NiriSettings.value("input.keyboard.xkb.layout") || "us")
    readonly property int delay: kde ? KdeInput.repeatDelay : (NiriSettings.value("input.keyboard.repeat-delay") ?? 600)
    readonly property int rate: kde ? KdeInput.repeatRate : (NiriSettings.value("input.keyboard.repeat-rate") ?? 25)
    readonly property int remapCount: Object.keys(KeyRemaps.everywhere ?? {}).length + Object.keys(KeyRemaps.appRules ?? {}).length
    readonly property int shortcutCount: NiriSettings.shortcuts.length

    PageIntro {
        icon: "󰌌"
        badge: "gray"
        title: "Keyboard & Mouse"
        description: "Layout, key repeat, pointer and trackpad, shortcuts, remaps and snippets"
        facts: [overview.layout !== "" ? `Layout ${overview.layout}` : null, `Repeat ${overview.delay} ms · ${overview.rate}/s`, { label: `${overview.remapCount} remap${overview.remapCount === 1 ? "" : "s"}`, on: overview.remapCount > 0 }, { label: "Snippets", on: Features.on("snippets") }].filter(f => f !== null)
    }

    SettingsCard {
        SettingsNavRow {
            page: "keybinds"
            value: overview.shortcutCount > 0 ? `${overview.shortcutCount} shortcuts` : ""
        }
        SettingsNavRow {
            page: "keyremaps"
            value: KeyRemaps.loaded ? (overview.remapCount > 0 ? `${overview.remapCount} set` : "None") : ""
        }
        SettingsNavRow {
            page: "snippets"
        }
    }
}
