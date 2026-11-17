import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Desktop & Dock: which of the desktop's surfaces are on, each
// with its switch (Features) and a row into its page. A switched-off one
// stays listed, dimmed, so it's one click from coming back.
ColumnLayout {
    id: overview
    spacing: 12

    readonly property var surfaces: [
        { id: "dock", feature: "dock", label: "Dock" },
        { id: "island", feature: "island", label: "Dynamic Island" },
        { id: "desktopmenu", feature: "desktopMenu", label: "Desktop Menu" },
        { id: "quickpanel", feature: "quickPanel", label: "Quick Panel" },
        { id: "radialmenu", feature: "radialMenu", label: "Radial Menu" }
    ]

    function cap(s) {
        return s ? s.charAt(0).toUpperCase() + s.slice(1) : "";
    }

    PageIntro {
        icon: "󱂬"
        badge: "blue"
        title: "Desktop & Dock"
        description: "The dock, the Dynamic Island and the menus and palettes at the pointer"
        facts: overview.surfaces.map(s => ({ label: s.label, on: Features.on(s.feature) }))
    }

    SettingsCard {
        SettingsNavRow {
            page: "dock"
            value: {
                const hide = Settings.dock.autoHide;
                const when = hide === "never" || hide === false ? "" : " · auto-hides";
                return `${overview.cap(Settings.dock.position)} · ${Math.round(Settings.dock.iconSize)} px${when}`;
            }
        }
        SettingsNavRow {
            page: "island"
            value: (Settings.island.style === "floating" ? "Floating pill" : "Attached") + (Settings.island.fill === "glass" ? " · glass" : "")
        }
        SettingsNavRow {
            page: "desktopmenu"
        }
        SettingsNavRow {
            page: "quickpanel"
        }
        SettingsNavRow {
            page: "radialmenu"
        }
    }

    SettingsCard {
        SettingsNavRow {
            page: "menubar"
            summary: "Menu bar controls and the Control Center live in Menu Bar"
        }
    }
}
