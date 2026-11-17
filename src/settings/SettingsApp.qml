import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.components
import qs.services
import "settingsnav.js" as Nav

// Loft Settings: a floating glass window (like macOS System Settings) that
// edits the runtime overrides (Settings → overrides/shell.json). Everything
// applies live; `loft save` will promote it into Nix defaults.
// Open with Cmd+, (Mod+Comma), the Control Center, or IPC settings toggle.
Scope {
    id: root

    readonly property bool open: Panels.settingsOpen
    // The open page lives in Panels so IPC (`themes open`) can choose it.
    readonly property string section: Panels.settingsSection

    // The structure (grouped sidebar, sub-pages, ids, search keywords)
    // lives in settingsnav.js. Old flat ids are still page ids: a sub-page
    // like "wallpaper" opens under its parent (Appearance ▸ Wallpaper).
    readonly property string current: Nav.resolve(section) || "appearance"
    readonly property string parentPage: Nav.parentOf(current)
    readonly property string topPage: Nav.topOf(current)

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
        function keyremaps(): void {
            root.show("keyremaps");
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
        function general(): void {
            root.show("general");
        }
        // Any page by id (Spotlight's "… Settings" commands), old flat ids
        // included; sub-pages open under their parent.
        function open(section: string): void {
            const id = Nav.resolve(section);
            if (id !== "")
                root.show(id);
        }
    }

    // The niri pages show live state: re-read it whenever they're opened.
    // (Overviews show counts from them too: Keyboard & Mouse, Spaces &
    // Windows.)
    function refreshNiri() {
        if (!open)
            return;
        const s = current;
        if (s === "keybinds")
            NiriSettings.refreshBinds();
        else if (s === "windowrules")
            WindowRules.refresh();
        else if (s === "keyremaps")
            KeyRemaps.refresh();
        else if (s === "displays")
            Displays.refreshOutputs();
        else if (s === "layout") {
            NiriSettings.refresh();
            KdeMotion.reload();
        } else if (s === "input") {
            NiriSettings.refresh();
            NiriSettings.refreshBinds();
            KeyRemaps.refresh();
        } else if (s === "windows") {
            NiriSettings.refresh();
            KdeMotion.reload();
            WindowRules.refresh();
        }
    }
    onOpenChanged: refreshNiri()
    onCurrentChanged: {
        refreshNiri();
        // A new page starts at its top (a search hit scrolls after this).
        content.contentY = 0;
    }

    function show(section) {
        Panels.settingsSection = section;
        Panels.settingsOpen = true;
    }

    function back() {
        if (parentPage !== "")
            Panels.settingsSection = parentPage;
    }

    // ── Sidebar search: pages (labels + keywords, settingsnav.js) and the
    // settings on them (row labels and card titles, read from the pages).
    readonly property string query: chrome.searchText.trim()
    property var rowIndex: []
    readonly property var pageHits: query === "" ? [] : Nav.searchPages(query)
    readonly property var rowHits: {
        if (query === "")
            return [];
        const labels = new Set(pageHits.map(id => Nav.page(id).label.toLowerCase()));
        return Nav.searchRows(rowIndex, query, 30).filter(h => !labels.has(h.label.toLowerCase()));
    }
    onQueryChanged: if (query !== "")
        indexTimer.restart()

    Timer {
        id: indexTimer
        interval: 80
        onTriggered: root.rowIndex = root.buildIndex()
    }

    // SettingsRow / NiriRow (they have `hintColor`) and PageHeader titles
    // (`actions`) of every page slot, in page order.
    function buildIndex() {
        const out = [];
        const walk = (item, page) => {
            for (const c of item.children) {
                if (c.hintColor !== undefined && typeof c.label === "string") {
                    const l = c.label.trim();
                    if (l.length > 1)
                        out.push({ page: page, label: l, kind: "row", item: c });
                } else if (c.actions !== undefined && typeof c.title === "string" && c.title.trim().length > 1) {
                    out.push({ page: page, label: c.title.trim(), kind: "section", item: c });
                }
                walk(c, page);
            }
        };
        for (const slot of pages.children)
            if (typeof slot.page === "string" && slot.page !== "")
                walk(slot, slot.page);
        return out;
    }

    // Open a search hit: its page, scrolled to the row, which flashes.
    property var target: null
    function openHit(hit) {
        target = hit.item ?? null;
        Panels.settingsSection = hit.page;
        scrollTimer.restart();
    }

    Timer {
        id: scrollTimer
        interval: 60
        onTriggered: {
            const t = root.target;
            root.target = null;
            if (!t || !t.visible)
                return;
            const p = t.mapToItem(content.contentItem, 0, 0);
            content.contentY = Math.max(0, Math.min(p.y - 40, content.contentHeight - content.height));
            flash.x = p.x - 8;
            flash.y = p.y - 6;
            flash.width = t.width + 16;
            flash.height = t.height + 12;
            flashAnim.restart();
        }
    }

    function acceptSearch() {
        if (pageHits.length > 0)
            Panels.settingsSection = pageHits[0];
        else if (rowHits.length > 0)
            openHit(rowHits[0]);
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

    // One page (or sub-page) of the content column: shown while current.
    component PageSlot: ColumnLayout {
        property string page
        Layout.fillWidth: true
        spacing: 12
        visible: root.current === page
    }

    // ── Window ──────────────────────────────────────────────────────────
    FloatingWindow {
        id: window
        visible: root.open
        title: "Loft Settings"
        implicitWidth: 920
        implicitHeight: 660
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
            title: Nav.page(root.current)?.label ?? ""
            searchable: true
            onCloseRequested: Panels.settingsOpen = false
            onHideRequested: Panels.settingsOpen = false
            onSearchAccepted: root.acceptSearch()

            focus: root.open
            Keys.onEscapePressed: Panels.settingsOpen = false
            // ⌘[ / Alt+← : back to the parent page.
            Keys.onPressed: event => {
                if ((event.key === Qt.Key_BracketLeft && (event.modifiers & (Qt.ControlModifier | Qt.MetaModifier))) || (event.key === Qt.Key_Left && (event.modifiers & Qt.AltModifier))) {
                    root.back();
                    event.accepted = true;
                }
            }

            // Sub-pages: "‹ Parent" back to the overview they belong to.
            leading: SettingsButton {
                visible: root.parentPage !== ""
                icon: "󰅁"
                text: Nav.page(root.parentPage)?.label ?? ""
                onClicked: root.back()
            }

            sidebar: [
                // Grouped entries, a small gap between groups (no headers).
                // Off modules stay listed, greyed: their page turns them on.
                Repeater {
                    model: root.query === "" ? Nav.groups : []
                    delegate: ColumnLayout {
                        id: group
                        required property var modelData
                        required property int index
                        Layout.fillWidth: true
                        Layout.topMargin: index > 0 ? 10 : 0
                        spacing: 2

                        Repeater {
                            model: group.modelData
                            delegate: SidebarItem {
                                required property string modelData
                                readonly property var info: Nav.page(modelData)
                                icon: info.icon
                                badge: info.badge
                                label: info.label
                                dimmed: info.feature !== "" && !Features.on(info.feature)
                                current: root.topPage === modelData
                                windowActive: chrome.active
                                onClicked: Panels.settingsSection = modelData
                            }
                        }
                    }
                },

                // Search: matching pages, then matching settings.
                Repeater {
                    model: root.pageHits
                    delegate: SidebarItem {
                        required property string modelData
                        readonly property var info: Nav.page(modelData)
                        icon: info.icon
                        badge: info.badge
                        label: info.label
                        detail: info.parent !== "" ? Nav.page(info.parent).label : ""
                        dimmed: info.feature !== "" && !Features.on(info.feature)
                        current: root.current === modelData
                        windowActive: chrome.active
                        onClicked: Panels.settingsSection = modelData
                    }
                },
                Text {
                    visible: root.rowHits.length > 0
                    Layout.fillWidth: true
                    Layout.topMargin: root.pageHits.length > 0 ? 10 : 0
                    Layout.leftMargin: 8
                    text: "Settings"
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                },
                Repeater {
                    model: root.rowHits
                    delegate: SidebarItem {
                        required property var modelData
                        readonly property var info: Nav.page(modelData.page)
                        icon: info.icon
                        badge: info.badge
                        label: modelData.label
                        detail: info.label
                        windowActive: chrome.active
                        onClicked: root.openHit(modelData)
                    }
                },
                Text {
                    visible: root.query !== "" && root.pageHits.length === 0 && root.rowHits.length === 0
                    Layout.fillWidth: true
                    Layout.topMargin: 8
                    horizontalAlignment: Text.AlignHCenter
                    text: "No results"
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                }
            ]

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

                    // ── General ─────────────────────────────────────────
                    PageSlot {
                        page: "general"
                        GeneralOverview {
                            Layout.fillWidth: true
                        }
                    }
                    PageSlot {
                        page: "about"
                        AboutPage {
                            Layout.fillWidth: true
                        }
                    }
                    PageSlot {
                        page: "features"
                        FeaturesPage {
                            Layout.fillWidth: true
                        }
                    }
                    PageSlot {
                        page: "system"
                        SystemPage {
                            Layout.fillWidth: true
                        }
                    }

                    // ── Appearance ──────────────────────────────────────
                    PageSlot {
                        page: "appearance"
                        AppearanceOverview {
                            Layout.fillWidth: true
                        }
                        AppearancePage {
                            Layout.fillWidth: true
                        }
                    }
                    PageSlot {
                        page: "wallpaper"
                        WallpaperPage {
                            Layout.fillWidth: true
                        }
                    }
                    PageSlot {
                        page: "lockscreen"
                        LockScreenPage {
                            Layout.fillWidth: true
                        }
                    }

                    PageSlot {
                        page: "menubar"
                        MenuBarPage {
                            Layout.fillWidth: true
                        }
                    }

                    // ── Desktop & Dock ──────────────────────────────────
                    PageSlot {
                        page: "desktop"
                        DesktopOverview {
                            Layout.fillWidth: true
                        }
                    }
                    PageSlot {
                        page: "dock"
                        FeatureOffCard {
                            feature: "dock"
                        }
                        DockPage {
                            Layout.fillWidth: true
                            visible: Features.on("dock")
                        }
                    }
                    PageSlot {
                        page: "island"
                        FeatureOffCard {
                            feature: "island"
                        }
                        IslandPage {
                            Layout.fillWidth: true
                            visible: Features.on("island")
                        }
                    }
                    PageSlot {
                        page: "desktopmenu"
                        FeatureOffCard {
                            feature: "desktopMenu"
                        }
                        DesktopMenuPage {
                            Layout.fillWidth: true
                            visible: Features.on("desktopMenu")
                        }
                    }
                    PageSlot {
                        page: "quickpanel"
                        FeatureOffCard {
                            feature: "quickPanel"
                        }
                        QuickPanelPage {
                            Layout.fillWidth: true
                            visible: Features.on("quickPanel")
                        }
                    }

                    PageSlot {
                        page: "displays"
                        DisplaysPage {
                            Layout.fillWidth: true
                        }
                    }

                    // ── Spaces & Windows ────────────────────────────────
                    PageSlot {
                        page: "windows"
                        WindowsOverview {
                            Layout.fillWidth: true
                        }
                    }
                    PageSlot {
                        page: "spaces"
                        FeatureOffCard {
                            feature: "spaces"
                        }
                        SpacesPage {
                            Layout.fillWidth: true
                            visible: Features.on("spaces")
                        }
                    }
                    PageSlot {
                        page: "layout"
                        LayoutPage {
                            Layout.fillWidth: true
                        }
                    }
                    PageSlot {
                        page: "windowrules"
                        WindowRulesPage {
                            Layout.fillWidth: true
                            shown: root.open
                            flick: content
                        }
                    }

                    // ── Tools ───────────────────────────────────────────
                    PageSlot {
                        page: "spotlight"
                        SpotlightPage {
                            Layout.fillWidth: true
                        }
                    }
                    PageSlot {
                        page: "sound"
                        SoundPage {
                            Layout.fillWidth: true
                        }
                    }
                    PageSlot {
                        page: "capture"
                        FeatureOffCard {
                            feature: "capture"
                        }
                        CapturePage {
                            Layout.fillWidth: true
                            visible: Features.on("capture")
                        }
                    }
                    PageSlot {
                        page: "clipboard"
                        ClipboardPage {
                            Layout.fillWidth: true
                        }
                    }
                    PageSlot {
                        page: "everyday"
                        EverydayPage {
                            Layout.fillWidth: true
                        }
                    }
                    PageSlot {
                        page: "phone"
                        FeatureOffCard {
                            feature: "phone"
                        }
                        PhonePage {
                            Layout.fillWidth: true
                            visible: Features.on("phone")
                        }
                    }

                    // ── Keyboard & Mouse ────────────────────────────────
                    PageSlot {
                        page: "input"
                        KeyboardOverview {
                            Layout.fillWidth: true
                        }
                        InputPage {
                            Layout.fillWidth: true
                        }
                    }
                    PageSlot {
                        page: "keybinds"
                        KeybindsPage {
                            Layout.fillWidth: true
                        }
                    }
                    PageSlot {
                        page: "keyremaps"
                        KeyRemapsPage {
                            Layout.fillWidth: true
                            shown: root.open
                            flick: content
                        }
                    }
                    PageSlot {
                        page: "snippets"
                        FeatureOffCard {
                            feature: "snippets"
                        }
                        SnippetsPage {
                            Layout.fillWidth: true
                            visible: Features.on("snippets")
                        }
                    }
                }

                // A search hit's row flashes once it's scrolled to.
                Rectangle {
                    id: flash
                    radius: Theme.controlRadius
                    color: Theme.withAlpha(Theme.accent, 0.14)
                    border.width: 2
                    border.color: Theme.accent
                    opacity: 0
                    SequentialAnimation {
                        id: flashAnim
                        NumberAnimation {
                            target: flash
                            property: "opacity"
                            to: 1
                            duration: 120
                        }
                        PauseAnimation {
                            duration: 900
                        }
                        NumberAnimation {
                            target: flash
                            property: "opacity"
                            to: 0
                            duration: 500
                        }
                    }
                }
            }
        }
    }
}
