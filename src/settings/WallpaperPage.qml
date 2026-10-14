import QtQuick
import QtQuick.Layouts
import qs.services

// Settings → Wallpaper: the theme's collection ("From <theme>": its own and
// curated wallpapers), then everything else installed (and the wallpaper
// folder) ranked by how well it matches the theme's colors. Clicking one
// applies it for this theme; rotation and per-workspace cycle the collection
// when nothing is picked. All choices are remembered per theme (Vibes).
ColumnLayout {
    id: page
    spacing: 12

    property bool showAll: false
    readonly property int shown: 12

    function label(w) {
        const name = w.path.split("/").pop();
        return name.replace(/\.[^.]+$/, "");
    }

    function source(w) {
        if (w.origin === "own")
            return w.video ? "from a video" : "";
        if (w.source_pack === "")
            return "Folder";
        return w.source_pack;
    }

    SettingsCard {
        PageHeader {
            title: Vibes.chosenWallpaper !== "" ? "Chosen for " + Vibes.theme : "Following " + Vibes.theme
            SettingsButton {
                text: "Use theme default"
                enabled: Vibes.chosenWallpaper !== ""
                onClicked: Vibes.chooseWallpaper("")
            }
            SettingsButton {
                text: "Picker"
                icon: "󰸉"
                onClicked: Panels.wallpaperPickerOpen = true
            }
        }

        SettingsRow {
            label: "Rotate through the collection"
            hint: Vibes.chosenWallpaper !== "" ? "Paused: a wallpaper is chosen" : Vibes.collection.length > 1 ? `${Vibes.collection.length} wallpapers in ${Vibes.theme}'s collection` : "The collection has one wallpaper"
            SettingsSlider {
                from: 0
                to: 120
                step: 5
                value: Vibes.rotateMinutes
                format: v => v === 0 ? "Off" : `${v} min`
                onCommitted: v => Vibes.setChoice("rotate", v)
            }
        }

        SettingsRow {
            label: "A wallpaper per workspace"
            hint: "Each niri workspace shows its own wallpaper of the collection"
            SettingsSwitch {
                checked: Vibes.perWorkspace
                onToggled: on => Vibes.setChoice("perWorkspace", on)
            }
        }

        SettingsRow {
            label: "Folder"
            hint: Settings.wallpaper.directory + " · its images are ranked under Matching vibes"
            SettingsButton {
                text: Vibes.loading ? "Ranking…" : "Refresh"
                enabled: !Vibes.loading
                onClicked: Vibes.refresh()
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: "From " + Vibes.theme
        }

        Text {
            visible: Vibes.themeWallpapers.length === 0
            Layout.fillWidth: true
            text: Vibes.loading ? "Loading…" : "This theme has no wallpaper images (it uses its gradient)."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 12
        }

        Flow {
            Layout.fillWidth: true
            spacing: 10

            Repeater {
                model: Vibes.themeWallpapers
                delegate: VibeThumb {
                    required property var modelData
                    image: modelData.kind === "image" ? modelData.path : ""
                    title: page.label(modelData)
                    subtitle: modelData.origin === "curated" ? "Curated · " + modelData.source_pack : page.source(modelData)
                    badge: modelData.kind === "video" || modelData.video ? "video" : ""
                    available: modelData.kind === "image"
                    isDefault: modelData.path === Vibes.defaultWallpaper
                    selected: Vibes.isCurrentWallpaper(modelData.path)
                    onClicked: Vibes.chooseWallpaper(modelData.path)
                }
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: "Matching vibes"
            SettingsButton {
                visible: Vibes.matchingWallpapers.length > page.shown
                text: page.showAll ? "Show fewer" : `Show all ${Vibes.matchingWallpapers.length}`
                onClicked: page.showAll = !page.showAll
            }
        }

        Text {
            Layout.fillWidth: true
            text: Vibes.matchingWallpapers.length === 0 ? (Vibes.loading ? "Ranking…" : "Nothing else installed yet: `studio theme install …` adds packs.") : "Other installed themes' wallpapers and your folder, closest colors first"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }

        Flow {
            Layout.fillWidth: true
            spacing: 10

            Repeater {
                model: page.showAll ? Vibes.matchingWallpapers : Vibes.matchingWallpapers.slice(0, page.shown)
                delegate: VibeThumb {
                    required property var modelData
                    image: modelData.kind === "image" ? modelData.path : ""
                    title: page.label(modelData)
                    subtitle: page.source(modelData)
                    score: modelData.score ?? -1
                    badge: modelData.kind === "video" || modelData.video ? "video" : ""
                    available: modelData.kind === "image"
                    selected: Vibes.chosenWallpaper === modelData.path
                    onClicked: Vibes.chooseWallpaper(modelData.path)
                }
            }
        }
    }
}
