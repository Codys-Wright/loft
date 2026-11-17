import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Spaces & Windows: Spaces (on/off), the window layout and the
// per-app window rules at a glance, each a row into its page.
ColumnLayout {
    id: overview
    spacing: 12

    readonly property bool niri: Compositor.backend === "niri"
    readonly property int ruleCount: Object.keys(WindowRules.rules ?? {}).length
    readonly property int spaceCount: Spaces.spaces.length
    readonly property string kdeSpeed: {
        const f = KdeMotion.speed;
        return f === 0 ? "Instant" : f === 1 ? "Normal speed" : f > 1 ? "Slower" : "Faster";
    }

    PageIntro {
        icon: "󰖲"
        badge: "indigo"
        title: "Spaces & Windows"
        description: "Desktops for each kind of work, how windows are laid out and where each app's windows open"
        facts: [
            { label: Features.on("spaces") ? `${overview.spaceCount} space${overview.spaceCount === 1 ? "" : "s"}` : "Spaces", on: Spaces.enabled },
            overview.niri ? `Gaps ${NiriSettings.value("layout.gaps") ?? 16} px` : overview.kdeSpeed,
            { label: `${overview.ruleCount} window rule${overview.ruleCount === 1 ? "" : "s"}`, on: overview.ruleCount > 0 }
        ]
    }

    SettingsCard {
        SettingsNavRow {
            page: "spaces"
            available: !!Compositor.capabilities.spaces
            value: Spaces.enabled ? (Spaces.active?.name ?? "") : ""
        }
        // niri's layout (gaps, columns, struts, motion); under KWin, KWin's
        // animation speed and effects (KdeMotion, docs/KWIN.md §4.21).
        SettingsNavRow {
            page: "layout"
            summary: overview.niri ? (info?.summary ?? "") : "Animation speed and KWin's effects"
            value: overview.niri ? `Gaps ${NiriSettings.value("layout.gaps") ?? 16} px` : overview.kdeSpeed
        }
        SettingsNavRow {
            page: "windowrules"
            value: overview.ruleCount > 0 ? `${overview.ruleCount} app${overview.ruleCount === 1 ? "" : "s"}` : "None"
        }
    }
}
