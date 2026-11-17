import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → General: this computer, how many modules are on, and rows into
// About, Features and Monitor & Alerts.
ColumnLayout {
    id: overview
    spacing: 12

    readonly property var optional: Features.modules.filter(m => !m.core)
    readonly property int onCount: optional.filter(m => Features.on(m.id)).length

    onVisibleChanged: if (visible)
        SystemInfo.refresh()

    PageIntro {
        icon: ""
        badge: "gray"
        title: SystemInfo.host || "This Computer"
        description: SystemInfo.os
        facts: [
            Compositor.backend === "kwin" ? "KDE Plasma (KWin)" : "niri",
            `${overview.onCount} of ${overview.optional.length} modules on`,
            { label: "System Monitor", on: Features.on("systemMonitor") },
            { label: "Alerts", on: Features.on("alerts") }
        ]
    }

    SettingsCard {
        SettingsNavRow {
            page: "about"
            value: SystemInfo.host
        }
        SettingsNavRow {
            page: "features"
            value: `${overview.onCount} on`
        }
        SettingsNavRow {
            page: "system"
        }
    }
}
