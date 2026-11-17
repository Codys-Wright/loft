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

    PageIntro {
        icon: "󰖲"
        badge: "indigo"
        title: "Spaces & Windows"
        description: "Desktops for each kind of work, how windows are laid out and where each app's windows open"
        facts: [
            { label: Features.on("spaces") ? `${overview.spaceCount} space${overview.spaceCount === 1 ? "" : "s"}` : "Spaces", on: Spaces.enabled },
            overview.niri ? `Gaps ${NiriSettings.value("layout.gaps") ?? 16} px` : "KWin layout",
            { label: `${overview.ruleCount} window rule${overview.ruleCount === 1 ? "" : "s"}`, on: overview.ruleCount > 0 }
        ]
    }

    SettingsCard {
        SettingsNavRow {
            page: "spaces"
            available: !!Compositor.capabilities.spaces
            value: Spaces.enabled ? (Spaces.active?.name ?? "") : ""
        }
        SettingsNavRow {
            page: "layout"
            value: overview.niri ? `Gaps ${NiriSettings.value("layout.gaps") ?? 16} px` : ""
        }
        SettingsNavRow {
            page: "windowrules"
            value: overview.ruleCount > 0 ? `${overview.ruleCount} app${overview.ruleCount === 1 ? "" : "s"}` : "None"
        }
    }
}
