import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.components
import qs.services

// Loft Settings: a floating glass window (like macOS System Settings) that
// edits the runtime overrides (Settings → overrides/shell.json). Everything
// applies live; `loft save` will promote it into Nix defaults.
// Open with Cmd+, (Mod+Comma), the Control Center, or IPC settings toggle.
Scope {
    id: root

    readonly property bool open: Panels.settingsOpen
    // The open page lives in Panels so IPC (`themes open`) can choose it.
    readonly property string section: Panels.settingsSection

    // Sidebar: icon + Theme.badgeColor name (System Settings style badges).
    readonly property var sections: [
        { id: "appearance", icon: "󰏘", badge: "graphite", label: "Appearance" },
        { id: "wallpaper", icon: "󰸉", badge: "cyan", label: "Wallpaper" },
        { id: "lockscreen", icon: "󰌾", badge: "indigo", label: "Lock Screen" },
        { id: "dock", icon: "󱂬", badge: "blue", label: "Dock", feature: "dock" },
        { id: "island", icon: "󰟜", badge: "purple", label: "Dynamic Island", feature: "island" },
        { id: "displays", icon: "󰍹", badge: "teal", label: "Displays" },
        { id: "spaces", icon: "󰕰", badge: "indigo", label: "Spaces", feature: "spaces" },
        { id: "input", icon: "󰌌", badge: "gray", label: "Keyboard & Mouse" },
        { id: "layout", icon: "󰕰", badge: "mint", label: "Layout & Motion" },
        { id: "keybinds", icon: "󰘳", badge: "graphite", label: "Keyboard Shortcuts" },
        { id: "windowrules", icon: "󰖲", badge: "teal", label: "Window Rules" },
        { id: "system", icon: "󰍛", badge: "gray", label: "System" },
        { id: "sound", icon: "󰕾", badge: "pink", label: "Sound" },
        { id: "capture", icon: "󰹑", badge: "orange", label: "Capture", feature: "capture" },
        { id: "features", icon: "󰐱", badge: "green", label: "Features" },
        { id: "clipboard", icon: "󰨸", badge: "yellow", label: "Clipboard & Files" },
        { id: "snippets", icon: "󱐋", badge: "brown", label: "Snippets", feature: "snippets" },
        { id: "phone", icon: "󰄜", badge: "green", label: "Phone", feature: "phone" },
        { id: "spotlight", icon: "󰍉", badge: "blue", label: "Spotlight" },
        { id: "everyday", icon: "󰅶", badge: "orange", label: "Everyday" },
        { id: "menubar", icon: "󰍜", badge: "graphite", label: "Menu Bar" },
        { id: "desktopmenu", icon: "󰍝", badge: "blue", label: "Desktop Menu", feature: "desktopMenu" },
        { id: "quickpanel", icon: "󰕮", badge: "orange", label: "Quick Panel", feature: "quickPanel" },
        { id: "radialmenu", icon: "󰫈", badge: "purple", label: "Radial Menu", feature: "radialMenu" },
        { id: "about", icon: "󰋼", badge: "gray", label: "About" }
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
        function windowrules(): void {
            root.show("windowrules");
        }

        function features(): void {
            root.show("features");
        }
        function desktopmenu(): void {
            root.show("desktopmenu");
        }
        function quickpanel(): void {
            root.show("quickpanel");
        }
        function radialmenu(): void {
            root.show("radialmenu");
        }
        function wallpaper(): void {
            root.show("wallpaper");
        }
        function lockscreen(): void {
            root.show("lockscreen");
        }
        function capture(): void {
            root.show("capture");
        }
        function island(): void {
            root.show("island");
        }
        function menubar(): void {
            root.show("menubar");
        }
        // Spotlight's Quicklinks (the launcher opens it after Create Quicklink).
        function spotlight(): void {
            root.show("spotlight");
        }
        function phone(): void {
            root.show("phone");
        }
        function dock(): void {
            root.show("dock");
        }
        function spaces(): void {
            root.show("spaces");
        }
        // Any page by id (Spotlight's "… Settings" commands).
        function open(section: string): void {
            if (root.sections.some(s => s.id === section))
                root.show(section);
        }
    }

    // The niri pages show live state: re-read it whenever they're opened.
    function refreshNiri() {
        if (!open)
            return;
        if (section === "keybinds")
            NiriSettings.refreshBinds();
        else if (section === "windowrules")
            WindowRules.refresh();
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
        title: "Loft Settings"
        implicitWidth: 880
        implicitHeight: 640
        color: "transparent"
        // Closing the window (niri's close-window, Escape) clears the state.
        onVisibleChanged: if (!visible)
            Panels.settingsOpen = false

        BackgroundEffect.blurRegion: blur
        Region {
            id: blur
            item: Theme.blur ? chrome.surface : null
            radius: chrome.radius
        }

        WindowChrome {
            id: chrome
            hostWindow: window
            title: root.sections.find(s => s.id === root.section)?.label ?? ""
            searchable: true
            onCloseRequested: Panels.settingsOpen = false
            onHideRequested: Panels.settingsOpen = false

            focus: root.open
            Keys.onEscapePressed: Panels.settingsOpen = false

            // Sections of switched-off modules hide (Features page); the
            // search field filters by name.
            sidebar: Repeater {
                model: root.sections.filter(s => (!s.feature || Features.on(s.feature)) && s.label.toLowerCase().includes(chrome.searchText.trim().toLowerCase()))
                delegate: SidebarItem {
                    required property var modelData
                    icon: modelData.icon
                    badge: modelData.badge
                    label: modelData.label
                    current: root.section === modelData.id
                    windowActive: chrome.active
                    onClicked: Panels.settingsSection = modelData.id
                }
            }

            // Content
            Flickable {
                id: content
                anchors.fill: parent
                anchors.leftMargin: 20
                anchors.rightMargin: 20
                contentHeight: pages.implicitHeight + 20
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: pages
                    width: parent.width
                    spacing: 12

                    // Appearance: Transparency + Blur first (the shell's own
                    // Liquid Glass slider is under its Advanced).
                    TransparencyCard {
                        visible: root.section === "appearance"
                    }

                    Card {
                        visible: root.section === "appearance"

                        Row_ {
                            label: "Reduce transparency"
                            hint: "Flat, opaque menus, panels and windows; no blur"
                            Switch_ {
                                checked: Theme.reduceTransparency
                                onToggled: on => Settings.appearance.reduceTransparency = on
                            }
                        }

                        Row_ {
                            label: "Shell blur"
                            hint: Theme.reduceTransparency ? "Off with Reduce transparency" : (Settings.appearance.blur < 0 ? "Following the theme" : "Overridden") + " · menus, panels and the dock blur what's behind them"
                            enabled: !Theme.reduceTransparency
                            Switch_ {
                                checked: Theme.blur
                                enabled: !Theme.reduceTransparency
                                onToggled: on => Settings.appearance.blur = on ? 1 : 0
                            }
                        }

                        Row_ {
                            label: "Show menu bar background"
                            hint: "Off: titles and icons sit on the wallpaper"
                            Switch_ {
                                checked: Theme.barBackground
                                onToggled: on => Settings.appearance.barBackground = on ? 1 : 0
                            }
                        }

                        Row_ {
                            label: "Adaptive menu bar text"
                            hint: Theme.barBackground ? "Only without the menu bar background" : "Light or dark from the wallpaper under the bar"
                            enabled: !Theme.barBackground
                            Switch_ {
                                checked: Theme.barAdaptiveText
                                enabled: !Theme.barBackground
                                onToggled: on => Settings.appearance.barAdaptiveText = on ? 1 : 0
                            }
                        }

                        Text {
                            visible: Settings.appearance.blur >= 0 || Settings.appearance.barBackground >= 0 || Settings.appearance.barAdaptiveText >= 0
                            text: "Reset to theme"
                            color: Theme.accent
                            font.family: Theme.fontUi
                            font.pixelSize: 12
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    Settings.appearance.blur = -1;
                                    Settings.appearance.barBackground = -1;
                                    Settings.appearance.barAdaptiveText = -1;
                                }
                            }
                        }

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
                                            right: polarityGlyph.left
                                            bottom: parent.bottom
                                            margins: 10
                                            rightMargin: 6
                                        }
                                        text: card.modelData.name
                                        color: card.p.text
                                        font.family: Theme.fontUi
                                        font.pixelSize: 13
                                        font.weight: card.current ? Font.Bold : Font.Medium
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        id: polarityGlyph
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

                    }

                    // Appearance → Spotify (programs.loft.spotify)
                    SpotifyCard {
                        visible: root.section === "appearance" && (SpotifyTheme.configured || SpotifyTheme.setUp)
                    }

                    WallpaperPage {
                        Layout.fillWidth: true
                        visible: root.section === "wallpaper"
                    }

                    LockScreenPage {
                        Layout.fillWidth: true
                        visible: root.section === "lockscreen"
                    }

                    DockPage {
                        Layout.fillWidth: true
                        visible: root.section === "dock"
                    }

                    IslandPage {
                        Layout.fillWidth: true
                        visible: root.section === "island"
                    }

                    DisplaysPage {
                        Layout.fillWidth: true
                        visible: root.section === "displays"
                    }

                    SpacesPage {
                        Layout.fillWidth: true
                        visible: root.section === "spaces"
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

                    WindowRulesPage {
                        Layout.fillWidth: true
                        visible: root.section === "windowrules"
                        shown: root.open
                        flick: content
                    }

                    FeaturesPage {
                        Layout.fillWidth: true
                        visible: root.section === "features"
                    }

                    SystemPage {
                        Layout.fillWidth: true
                        visible: root.section === "system"
                    }

                    SoundPage {
                        Layout.fillWidth: true
                        visible: root.section === "sound"
                    }

                    CapturePage {
                        Layout.fillWidth: true
                        visible: root.section === "capture"
                    }

                    MenuBarPage {
                        Layout.fillWidth: true
                        visible: root.section === "menubar"
                    }

                    DesktopMenuPage {
                        Layout.fillWidth: true
                        visible: root.section === "desktopmenu"
                    }

                    QuickPanelPage {
                        Layout.fillWidth: true
                        visible: root.section === "quickpanel"
                    }

                    RadialMenuPage {
                        Layout.fillWidth: true
                        visible: root.section === "radialmenu"
                    }

                    // About: this computer (the same facts as the system
                    // menu's About This Computer, SystemInfo.qml), then Loft.
                    Card {
                        id: aboutComputer
                        visible: root.section === "about"
                        onVisibleChanged: if (visible)
                            SystemInfo.refresh()

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.bottomMargin: 4
                            spacing: 14
                            Icon {
                                text: "\uf313"
                                size: 44
                                color: Theme.accent
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.preferredWidth: 10000
                                spacing: 2
                                Text {
                                    text: SystemInfo.host || "This Computer"
                                    color: Theme.text
                                    font.family: Theme.fontUi
                                    font.pixelSize: 18
                                    font.weight: Font.DemiBold
                                }
                                Text {
                                    text: SystemInfo.os
                                    visible: text !== ""
                                    color: Theme.subtext
                                    font.family: Theme.fontUi
                                    font.pixelSize: 12
                                }
                            }
                            SettingsButton {
                                visible: Features.on("systemMonitor")
                                text: "More Info…"
                                onClicked: {
                                    SystemStats.monitorSection = "overview";
                                    SystemStats.monitorOpen = true;
                                }
                            }
                        }

                        Repeater {
                            model: SystemInfo.details
                            delegate: Row_ {
                                required property var modelData
                                label: modelData[0]
                                Text {
                                    Layout.maximumWidth: 420
                                    text: modelData[1]
                                    color: Theme.text
                                    font.family: Theme.fontUi
                                    font.pixelSize: 12
                                    elide: Text.ElideMiddle
                                    horizontalAlignment: Text.AlignRight
                                }
                            }
                        }
                    }

                    Card {
                        visible: root.section === "about"

                        Row_ {
                            label: "loft"
                            hint: "niri + Quickshell · github.com/Codys-Wright/loft"
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

                    PhonePage {
                        Layout.fillWidth: true
                        visible: root.section === "phone"
                    }

                    ClipboardPage {
                        Layout.fillWidth: true
                        visible: root.section === "clipboard"
                    }

                    SnippetsPage {
                        Layout.fillWidth: true
                        visible: root.section === "snippets"
                    }

                    SpotlightPage {
                        Layout.fillWidth: true
                        visible: root.section === "spotlight"
                    }

                    EverydayPage {
                        Layout.fillWidth: true
                        visible: root.section === "everyday"
                    }
                }
            }
        }
    }
}
