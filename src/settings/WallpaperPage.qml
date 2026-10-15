import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.services

// Settings → Wallpaper: the theme's collection ("From <theme>": its own and
// curated wallpapers), then everything else installed (and the wallpaper
// folder) ranked by how well it matches the theme's colors. Clicking one
// applies it for this theme; rotation and per-workspace cycle the collection
// when nothing is picked. All choices are remembered per theme (Vibes).
// The Library card browses ~/Documents/Loft (Library) by topic, color
// family + tone, or the theme an image goes with. Displays & Workspaces
// (WallpaperDisplays) picks per display / workspace and manages sets.
ColumnLayout {
    id: page
    spacing: 12

    property bool showAll: false
    readonly property int shown: 12

    // ── Library browsing ────────────────────────────────────────────────
    property string browse: "topic" // topic | color | theme
    property string topicSel: "" // a topic, or "pack:" for the packs' images
    property string colorSel: ""
    property string toneSel: ""
    property string themeSel: "" // "" = the active theme
    property bool libShowAll: false
    readonly property int libShown: 18

    readonly property string topicCur: topicSel !== "" ? topicSel : (Library.topics[0]?.name ?? "pack:")
    readonly property string themeCur: themeSel !== "" ? themeSel : Vibes.theme
    readonly property var libItems: browse === "topic" ? (topicCur === "pack:" ? Library.ofPack("") : Library.ofTopic(topicCur)) : browse === "color" ? Library.ofColor(colorSel, toneSel) : Library.ofTheme(themeCur)

    onVisibleChanged: if (visible)
        Library.refresh()

    function label(w) {
        const short = Library.byPath[w.path]?.short;
        if (short)
            return short;
        const name = w.path.split("/").pop();
        return name.replace(/\.[^.]+$/, "");
    }

    function source(w) {
        if (w.origin === "own")
            return w.video ? "from a video" : "";
        if (w.topic)
            return w.topic;
        if (w.source_pack === "")
            return "Folder";
        return w.source_pack;
    }

    // Per display / per workspace, auto matching and sets.
    WallpaperDisplays {}

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
            label: "Wallpapers move with workspaces"
            hint: WorkspaceWallpapers.supported ? "Each workspace's wallpaper slides with it when you switch, and shows behind it in the overview" : "Needs Loft's niri (niri-loft, per-workspace layers); this niri swaps the wallpaper when you switch"
            SettingsSwitch {
                enabled: WorkspaceWallpapers.supported
                checked: WorkspaceWallpapers.supported && Settings.wallpaper.moveWithWorkspaces
                onToggled: on => Settings.wallpaper.moveWithWorkspaces = on
            }
        }

        SettingsRow {
            label: "Video wallpapers"
            hint: VideoWallpapers.stillOnly ? "Live wallpapers show their still frame" : VideoWallpapers.playingCount > 0 ? `${VideoWallpapers.playingCount} playing · ${VideoWallpapers.decodePath}` : VideoWallpapers.globalReason !== "" ? `Paused: ${VideoWallpapers.globalReason}` : "Live wallpapers play on the workspace you see, and hold their frame everywhere else"
            SettingsSegmented {
                options: [
                    { value: "play", label: "Play" },
                    { value: "still", label: "Still frame" }
                ]
                current: Settings.wallpaper.video
                onActivated: v => Settings.wallpaper.video = v
            }
        }

        SettingsRow {
            visible: !VideoWallpapers.stillOnly
            label: "    Pause while a window fills the screen"
            hint: "Not only fullscreen opaque windows (those always pause it): any window covering most of the screen"
            SettingsSwitch {
                checked: Settings.wallpaper.pauseWhenMaximized
                onToggled: on => Settings.wallpaper.pauseWhenMaximized = on
            }
        }

        SettingsRow {
            visible: !VideoWallpapers.stillOnly
            label: "    Pause on battery or in power saver"
            SettingsSwitch {
                checked: Settings.wallpaper.pauseOnBattery
                onToggled: on => Settings.wallpaper.pauseOnBattery = on
            }
        }

        SettingsRow {
            visible: !VideoWallpapers.stillOnly
            label: "    Pause when idle"
            hint: "After this long without input (and always while locked)"
            SettingsSlider {
                from: 0
                to: 30
                step: 1
                value: Settings.wallpaper.pauseWhenIdleMinutes
                format: v => v === 0 ? "Never" : `${v} min`
                onCommitted: v => Settings.wallpaper.pauseWhenIdleMinutes = v
            }
        }

        SettingsRow {
            visible: !VideoWallpapers.stillOnly
            label: "    Play display-sized copies"
            hint: "Each screen plays a copy of just the part it shows, made once in the background (NVENC on NVIDIA) and cached; the originals are untouched"
            SettingsSwitch {
                checked: Settings.wallpaper.smallerCopies
                onToggled: on => Settings.wallpaper.smallerCopies = on
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
                    thumbnail: modelData.thumb ?? ""
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
        visible: Library.exists || (Library.data === null && Library.loading)

        PageHeader {
            title: "Library"
            SettingsSegmented {
                options: [
                    {
                        value: "topic",
                        label: "Topic"
                    },
                    {
                        value: "color",
                        label: "Color"
                    },
                    {
                        value: "theme",
                        label: "Theme"
                    }
                ]
                current: page.browse
                onActivated: v => {
                    page.browse = v;
                    page.libShowAll = false;
                }
            }
            SettingsButton {
                text: Library.loading ? "Sorting…" : "Sort"
                icon: "󰒺"
                enabled: !Library.loading
                onClicked: {
                    Library.refresh();
                    Vibes.refresh();
                }
            }
        }

        Text {
            Layout.fillWidth: true
            text: Library.error !== "" ? Library.error : `${Library.rootDir.replace(Quickshell.env("HOME"), "~")} · ${Library.images.length} images · ` + (page.browse === "topic" ? "your topic folders and the theme packs' images" : page.browse === "color" ? "by dominant color family and lightness" : "the images closest to each theme's colors")
            color: Library.error !== "" ? Theme.urgent : Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            elide: Text.ElideMiddle
        }

        // Filter chips for the chosen dimension.
        Flow {
            Layout.fillWidth: true
            spacing: 6

            Repeater {
                model: page.browse === "topic" ? Library.topics.map(t => ({
                            value: t.name,
                            label: t.name,
                            count: t.count
                        })).concat(Library.packs.length ? [
                        {
                            value: "pack:",
                            label: "Theme packs",
                            count: Library.packs.reduce((n, p) => n + p.count, 0)
                        }
                    ] : []) : page.browse === "color" ? [
                    {
                        value: "",
                        label: "All",
                        count: Library.images.length
                    }
                ].concat(Library.colors.map(c => ({
                                value: c.name,
                                label: c.name,
                                count: c.count,
                                dot: Library.familyColors[c.name] ?? ""
                            }))) : Library.themes.map(t => ({
                            value: t.name,
                            label: t.name,
                            count: t.images.length,
                            dot: t.palette?.accent ?? ""
                        }))
                delegate: FilterChip {
                    required property var modelData
                    label: modelData.label
                    count: modelData.count
                    dot: modelData.dot ?? ""
                    selected: modelData.value === (page.browse === "topic" ? page.topicCur : page.browse === "color" ? page.colorSel : page.themeCur)
                    onClicked: {
                        if (page.browse === "topic")
                            page.topicSel = modelData.value;
                        else if (page.browse === "color")
                            page.colorSel = modelData.value;
                        else
                            page.themeSel = modelData.value;
                        page.libShowAll = false;
                    }
                }
            }
        }

        SettingsRow {
            visible: page.browse === "color"
            label: "Tone"
            hint: "Dark suits dark themes and keeps glass readable"
            SettingsSegmented {
                options: [
                    {
                        value: "",
                        label: "All"
                    }
                ].concat(Library.tones.map(t => ({
                            value: t.name,
                            label: `${t.name} ${Library.ofColor(page.colorSel, t.name).length}`
                        })))
                current: page.toneSel
                onActivated: v => {
                    page.toneSel = v;
                    page.libShowAll = false;
                }
            }
        }

        Text {
            visible: page.libItems.length === 0
            Layout.fillWidth: true
            text: Library.loading ? "Sorting the library…" : "Nothing here."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 12
        }

        Flow {
            Layout.fillWidth: true
            spacing: 10

            Repeater {
                model: page.libShowAll ? page.libItems : page.libItems.slice(0, page.libShown)
                delegate: VibeThumb {
                    required property var modelData
                    image: modelData.path
                    thumbnail: modelData.thumb ?? ""
                    title: modelData.short ?? modelData.name
                    subtitle: modelData.colors.join(" + ") + " · " + modelData.tone + (page.browse === "topic" ? "" : " · " + (modelData.source === "pack" ? "pack" : modelData.topic))
                    score: page.browse === "theme" && modelData.origin === "match" ? modelData.score : -1
                    badge: page.browse === "theme" && modelData.origin !== "match" ? modelData.origin : ""
                    selected: Vibes.chosenWallpaper === modelData.path
                    onClicked: Vibes.chooseWallpaper(modelData.path)
                }
            }
        }

        SettingsButton {
            visible: page.libItems.length > page.libShown
            text: page.libShowAll ? "Show fewer" : `Show all ${page.libItems.length}`
            onClicked: page.libShowAll = !page.libShowAll
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
            text: Vibes.matchingWallpapers.length === 0 ? (Vibes.loading ? "Ranking…" : "Nothing else installed yet: `loft theme install …` adds packs.") : "Other installed themes' wallpapers and your folder, closest colors first"
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
                    thumbnail: modelData.thumb ?? ""
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

    // A pill for the library filters: optional color dot, label, count.
    component FilterChip: Rectangle {
        id: chip
        property string label
        property int count: -1
        property string dot: ""
        property bool selected: false
        signal clicked

        implicitWidth: chipRow.implicitWidth + 20
        implicitHeight: 26
        radius: 13
        color: selected ? Theme.accent : chipHover.containsMouse ? Theme.withAlpha(Theme.text, 0.16) : Theme.withAlpha(Theme.text, 0.08)

        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 6

            Rectangle {
                visible: chip.dot !== ""
                anchors.verticalCenter: parent.verticalCenter
                width: 10
                height: 10
                radius: 5
                color: chip.dot || "transparent"
                border.width: 1
                border.color: Theme.withAlpha(chip.selected ? Theme.bg : Theme.text, 0.35)
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: chip.label
                color: chip.selected ? Theme.bg : Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 12
                font.weight: chip.selected ? Font.DemiBold : Font.Normal
            }
            Text {
                visible: chip.count >= 0
                anchors.verticalCenter: parent.verticalCenter
                text: chip.count
                color: chip.selected ? Theme.withAlpha(Theme.bg, 0.75) : Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
            }
        }

        MouseArea {
            id: chipHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
    }
}
