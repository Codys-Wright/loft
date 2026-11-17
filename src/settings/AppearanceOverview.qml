import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services

// Settings → Appearance, top: the theme, light/dark, glass at a glance with
// the wallpaper of the first display, then the sub-pages (Wallpaper, Lock
// Screen). The theme chooser and glass settings follow (AppearancePage).
ColumnLayout {
    id: overview
    spacing: 12

    readonly property string screen: Quickshell.screens[0]?.name ?? ""
    readonly property string wallpaper: Vibes.wallpaperFor(screen)
    readonly property bool still: /\.(png|jpe?g|webp|avif|bmp|gif)$/i.test(wallpaper)

    readonly property string lockName: {
        if (Vibes.chosenLock === "builtin" || (Vibes.chosenLock === "" && Vibes.defaultLock === ""))
            return "Loft (built-in)";
        const path = Vibes.chosenLock || Vibes.defaultLock;
        const l = Vibes.locks.find(x => x.path === path);
        return l ? l.name : path.split("/").pop();
    }

    PageIntro {
        icon: "󰏘"
        badge: "graphite"
        title: ThemeManager.label || Theme.name
        description: "Theme, light or dark, glass, wallpaper and lock screen"
        facts: [
            { label: Theme.dark ? "Dark" : "Light", on: true },
            { label: Theme.reduceTransparency ? "Reduced transparency" : "Glass", on: !Theme.reduceTransparency },
            { label: "Blur", on: Theme.blur },
            { label: "Menu bar background", on: Theme.barBackground }
        ]

        // The wallpaper now on the first display.
        Rectangle {
            implicitWidth: 132
            implicitHeight: 82
            radius: 10
            color: Theme.withAlpha(Theme.text, 0.08)
            border.width: 1
            border.color: Theme.glassBorder

            Item {
                anchors.fill: parent
                anchors.margins: 3
                clip: true
                Image {
                    anchors.fill: parent
                    visible: overview.still && status === Image.Ready
                    source: overview.still ? Vibes.url(overview.wallpaper) : ""
                    sourceSize: Qt.size(320, 200)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }
            }
            Icon {
                anchors.centerIn: parent
                visible: !overview.still
                text: overview.wallpaper !== "" ? "󰕧" : "󰸉"
                size: 22
                color: Theme.subtext
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: Panels.settingsSection = "wallpaper"
            }
        }
    }

    SettingsCard {
        SettingsNavRow {
            page: "wallpaper"
            value: Vibes.chosenWallpaper !== "" ? "Chosen" : Vibes.perWorkspace ? "Per workspace" : `Following ${ThemeManager.label || Theme.name}`
        }
        SettingsNavRow {
            page: "lockscreen"
            value: overview.lockName
        }
    }
}
