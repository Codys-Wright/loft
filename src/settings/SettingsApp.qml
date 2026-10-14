import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.components
import qs.services

// Studio Settings: a floating glass window (like macOS System Settings) that
// edits the runtime overrides (Settings → overrides/shell.json). Everything
// applies live; `studio save` will promote it into Nix defaults.
// Open with Cmd+, (Mod+Comma), the Control Center, or IPC settings toggle.
Scope {
    id: root

    readonly property bool open: Panels.settingsOpen
    // The open page lives in Panels so IPC (`themes open`) can choose it.
    readonly property string section: Panels.settingsSection

    readonly property var sections: [
        { id: "appearance", icon: "󰏘", label: "Appearance" },
        { id: "wallpaper", icon: "󰸉", label: "Wallpaper" },
        { id: "dock", icon: "󱂬", label: "Dock", feature: "dock" },
        { id: "island", icon: "󰟜", label: "Dynamic Island", feature: "island" },
        { id: "displays", icon: "󰍹", label: "Displays" },
        { id: "input", icon: "󰌌", label: "Keyboard & Mouse" },
        { id: "layout", icon: "󰕰", label: "Layout & Motion" },
        { id: "keybinds", icon: "󰘳", label: "Keybinds" },
        { id: "system", icon: "󰍛", label: "System" },
        { id: "features", icon: "󰐱", label: "Features" },
        { id: "about", icon: "󰋼", label: "About" }
    ]

    IpcHandler {
        target: "settings"

        function toggle(): void {
            Panels.settingsOpen = !Panels.settingsOpen;
        }

        // Open on a page. No arguments: quickshell's ipc CLI can't pass
        // them together with --path.
        function displays(): void {
            root.show("displays");
        }
        function input(): void {
            root.show("input");
        }
        function layout(): void {
            root.show("layout");
        }
        function keybinds(): void {
            root.show("keybinds");
        }

        function features(): void {
            root.show("features");
        }
    }

    // The niri pages show live state: re-read it whenever they're opened.
    function refreshNiri() {
        if (!open)
            return;
        if (section === "keybinds")
            NiriSettings.refreshBinds();
        else if (["displays", "input", "layout"].includes(section))
            NiriSettings.refresh();
    }
    onOpenChanged: refreshNiri()
    onSectionChanged: refreshNiri()

    function show(section) {
        Panels.settingsSection = section;
        Panels.settingsOpen = true;
    }

    // Settings → Displays → Identify.
    Variants {
        model: Quickshell.screens
        IdentifyOverlay {}
    }

    // ── Row building blocks (SettingsRow.qml, …; shared with the niri pages)
    component Row_: SettingsRow {}
    component Switch_: SettingsSwitch {}
    component Slider_: SettingsSlider {}
    component Card: SettingsCard {}

    // ── Window ──────────────────────────────────────────────────────────
    FloatingWindow {
        id: window
        visible: root.open
        title: "Studio Settings"
        implicitWidth: 860
        implicitHeight: 600
        color: "transparent"
        // Closing the window (niri's close-window, Escape) clears the state.
        onVisibleChanged: if (!visible)
            Panels.settingsOpen = false

        BackgroundEffect.blurRegion: Theme.blur ? blur : null
        Region {
            id: blur
            item: frame
            radius: frame.radius
        }

        GlassSurface {
            id: frame
            anchors.fill: parent
            radius: 24
            strength: 1.7

            focus: root.open
            Keys.onEscapePressed: Panels.settingsOpen = false

            RowLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 12

                // Sidebar
                ColumnLayout {
                    Layout.preferredWidth: 200
                    Layout.maximumWidth: 200
                    Layout.fillHeight: true
                    spacing: 4

                    Text {
                        Layout.leftMargin: 10
                        Layout.topMargin: 6
                        Layout.bottomMargin: 8
                        text: "Settings"
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 18
                        font.weight: Font.DemiBold
                    }

                    Repeater {
                        // Sections of switched-off modules hide (Features page).
                        model: root.sections.filter(s => !s.feature || Features.on(s.feature))
                        delegate: Rectangle {
                            id: item
                            required property var modelData
                            readonly property bool current: root.section === modelData.id
                            Layout.fillWidth: true
                            Layout.preferredHeight: 36
                            radius: 10
                            color: current ? Theme.accent : mouse.containsMouse ? Theme.withAlpha(Theme.text, 0.08) : "transparent"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                spacing: 10

                                Icon {
                                    text: item.modelData.icon
                                    size: 15
                                    color: item.current ? Theme.bg : Theme.text
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: item.modelData.label
                                    color: item.current ? Theme.bg : Theme.text
                                    font.family: Theme.fontUi
                                    font.pixelSize: 13
                                }
                            }

                            MouseArea {
                                id: mouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Panels.settingsSection = item.modelData.id
                            }
                        }
                    }

                    Item {
                        Layout.fillHeight: true
                    }
                }

                // Content
                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredWidth: 560
                    contentHeight: pages.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: pages
                        width: parent.width
                        spacing: 12

                        Text {
                            Layout.topMargin: 6
                            text: root.sections.find(s => s.id === root.section)?.label ?? ""
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 22
                            font.weight: Font.DemiBold
                        }

                        // Appearance
                        Card {
                            visible: root.section === "appearance"

                            Row_ {
                                label: "Theme"
                                hint: ThemeManager.applying ? "Applying…" : ThemeManager.error || "Recolors the shell, niri, terminals, GTK and the launcher"
                            }

                            Flow {
                                Layout.fillWidth: true
                                spacing: 10

                                Repeater {
                                    model: ThemeManager.themes

                                    delegate: Rectangle {
                                        id: card
                                        required property var modelData
                                        readonly property var p: modelData.palette
                                        readonly property bool current: modelData.name === Theme.name

                                        width: 150
                                        height: 104
                                        radius: 14
                                        color: p.bg
                                        border.width: current ? 3 : 1
                                        border.color: current ? Theme.accent : Theme.glassBorder

                                        // A tiny desktop: wallpaper strip, glass bar, accent dots.
                                        Rectangle {
                                            anchors {
                                                left: parent.left
                                                right: parent.right
                                                top: parent.top
                                                margins: 8
                                            }
                                            height: 50
                                            radius: 8
                                            gradient: Gradient {
                                                orientation: Gradient.Horizontal
                                                GradientStop { position: 0; color: (card.modelData.wallpaper?.gradient ?? [])[0] ?? card.p.surface }
                                                GradientStop { position: 1; color: (card.modelData.wallpaper?.gradient ?? [])[2] ?? card.p.overlay }
                                            }

                                            Rectangle {
                                                anchors {
                                                    left: parent.left
                                                    right: parent.right
                                                    top: parent.top
                                                    margins: 5
                                                }
                                                height: 10
                                                radius: 5
                                                color: Theme.withAlpha(card.modelData.glass?.tint ?? card.p.bg, 0.6)
                                            }

                                            Row {
                                                anchors {
                                                    left: parent.left
                                                    bottom: parent.bottom
                                                    margins: 6
                                                }
                                                spacing: 4
                                                Repeater {
                                                    model: [card.p.accent, card.p.accent2, card.p.ok, card.p.warn, card.p.urgent]
                                                    delegate: Rectangle {
                                                        required property var modelData
                                                        width: 10
                                                        height: 10
                                                        radius: 5
                                                        color: modelData
                                                    }
                                                }
                                            }
                                        }

                                        Text {
                                            anchors {
                                                left: parent.left
                                                bottom: parent.bottom
                                                margins: 10
                                            }
                                            text: card.modelData.name
                                            color: card.p.text
                                            font.family: Theme.fontUi
                                            font.pixelSize: 13
                                            font.weight: card.current ? Font.Bold : Font.Medium
                                        }

                                        Text {
                                            anchors {
                                                right: parent.right
                                                bottom: parent.bottom
                                                margins: 10
                                            }
                                            text: card.modelData.polarity === "light" ? "󰖨" : "󰖔"
                                            color: card.p.subtext
                                            font.family: Theme.fontIcons
                                            font.pixelSize: 12
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: ThemeManager.apply(card.modelData.name)
                                        }
                                    }
                                }
                            }

                            Row_ {
                                label: "Background blur"
                                hint: Settings.appearance.blur < 0 ? "Following the theme" : "Overridden"
                                Switch_ {
                                    checked: Theme.blur
                                    onToggled: on => Settings.appearance.blur = on ? 1 : 0
                                }
                            }

                            Row_ {
                                label: "Glass opacity"
                                hint: Settings.appearance.glassOpacity < 0 ? "Following the theme" : "Overridden"
                                Slider_ {
                                    from: 0.1
                                    to: 0.95
                                    step: 0.01
                                    decimals: 2
                                    value: Theme.glassOpacity
                                    onMoved: v => Settings.appearance.glassOpacity = v
                                }
                            }

                            Text {
                                visible: Settings.appearance.blur >= 0 || Settings.appearance.glassOpacity >= 0
                                text: "Reset to theme"
                                color: Theme.accent
                                font.family: Theme.fontUi
                                font.pixelSize: 12
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        Settings.appearance.blur = -1;
                                        Settings.appearance.glassOpacity = -1;
                                    }
                                }
                            }
                        }

                        // Wallpaper
                        Card {
                            visible: root.section === "wallpaper"

                            Row_ {
                                label: "Current"
                                hint: Settings.wallpaper.path || "The theme's wallpaper"
                                Text {
                                    text: "Choose…"
                                    color: Theme.accent
                                    font.family: Theme.fontUi
                                    font.pixelSize: 13
                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -6
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: Panels.wallpaperPickerOpen = true
                                    }
                                }
                            }

                            Row_ {
                                label: "Folder"
                                hint: Settings.wallpaper.directory
                            }
                        }

                        // Dock
                        Card {
                            visible: root.section === "dock"

                            Row_ {
                                label: "Icon size"
                                Slider_ {
                                    from: 32
                                    to: 80
                                    step: 1
                                    suffix: " px"
                                    value: Settings.dock.iconSize
                                    onMoved: v => Settings.dock.iconSize = v
                                }
                            }

                            Row_ {
                                label: "Magnification"
                                Slider_ {
                                    from: 1
                                    to: 2
                                    step: 0.05
                                    decimals: 2
                                    suffix: "×"
                                    value: Settings.dock.magnification
                                    onMoved: v => Settings.dock.magnification = v
                                }
                            }

                            Row_ {
                                label: "Pinned apps"
                                hint: "× to unpin"
                            }

                            Flow {
                                Layout.fillWidth: true
                                spacing: 8

                                Repeater {
                                    model: Settings.dock.pinned
                                    delegate: Rectangle {
                                        id: pin
                                        required property string modelData
                                        required property int index
                                        width: pinRow.implicitWidth + 20
                                        height: 34
                                        radius: 17
                                        color: Theme.withAlpha(Theme.text, 0.08)

                                        RowLayout {
                                            id: pinRow
                                            anchors.centerIn: parent
                                            spacing: 8

                                            Image {
                                                Layout.preferredWidth: 20
                                                Layout.preferredHeight: 20
                                                source: Apps.icon(pin.modelData)
                                                sourceSize: Qt.size(40, 40)
                                            }
                                            Text {
                                                text: Apps.name(pin.modelData)
                                                color: Theme.text
                                                font.family: Theme.fontUi
                                                font.pixelSize: 12
                                            }
                                            Icon {
                                                text: "󰅖"
                                                size: 12
                                                color: Theme.subtext
                                                MouseArea {
                                                    anchors.fill: parent
                                                    anchors.margins: -6
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        const l = Array.from(Settings.dock.pinned);
                                                        l.splice(pin.index, 1);
                                                        Settings.dock.pinned = l;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Island
                        Card {
                            visible: root.section === "island"

                            Row_ {
                                label: "Overheat alert"
                                hint: "Border pulses red above this temperature"
                                Slider_ {
                                    from: 60
                                    to: 105
                                    step: 1
                                    suffix: " °C"
                                    value: Settings.island.maxTemp
                                    onMoved: v => Settings.island.maxTemp = v
                                }
                            }

                            Row_ {
                                label: "Load alert"
                                hint: "CPU or memory use that turns the border amber"
                                Slider_ {
                                    from: 0.5
                                    to: 1
                                    step: 0.01
                                    decimals: 2
                                    value: Settings.island.maxLoad
                                    onMoved: v => Settings.island.maxLoad = v
                                }
                            }

                            Row_ {
                                label: "Focus session"
                                Slider_ {
                                    from: 5
                                    to: 90
                                    step: 5
                                    suffix: " min"
                                    value: Settings.island.focusMinutes
                                    onMoved: v => Settings.island.focusMinutes = v
                                }
                            }
                        }

                        DisplaysPage {
                            Layout.fillWidth: true
                            visible: root.section === "displays"
                        }

                        InputPage {
                            Layout.fillWidth: true
                            visible: root.section === "input"
                        }

                        LayoutPage {
                            Layout.fillWidth: true
                            visible: root.section === "layout"
                        }

                        KeybindsPage {
                            Layout.fillWidth: true
                            visible: root.section === "keybinds"
                        }

                        FeaturesPage {
                            Layout.fillWidth: true
                            visible: root.section === "features"
                        }

                        SystemPage {
                            Layout.fillWidth: true
                            visible: root.section === "system"
                        }

                        // About
                        Card {
                            visible: root.section === "about"

                            Row_ {
                                label: "studio-linux"
                                hint: "niri + Quickshell · github.com/Codys-Wright/studio-linux"
                            }
                            Row_ {
                                label: "Settings file"
                                hint: Settings.file
                            }
                            Row_ {
                                label: "Design"
                                hint: "Liquid Glass components ported from javiiervm/dotfiles"
                            }
                        }
                    }
                }
            }
        }
    }
}
