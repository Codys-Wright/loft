import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services

// Settings → Window Rules: translucent windows (every app window frosted,
// the focused one too, with separate focused / unfocused opacity), the apps
// kept opaque, and per-app niri window rules (open floating / maximized /
// full screen, width, square corners, hidden from screen capture, Assign To).
//
// Read-only: the window-rules in the niri config — Loft's base.kdl, the
// theme's fragment and the user's own files, with file:line — per app and
// the rest (global / title rules) at the bottom.
//
// Writes go through WindowRules → loft-niri: stored in overrides/niri.json,
// rendered into overrides/niri.kdl (included last), checked with `niri
// validate` first and rolled back if niri rejects it.
ColumnLayout {
    id: page
    spacing: 12

    property string query: ""
    // The app whose editor is open.
    property string selected: ""
    property bool confirmRestore: false

    readonly property var g: WindowRules.glass
    readonly property var themeG: WindowRules.themeGlass
    readonly property var userG: WindowRules.userGlass

    // The Settings window's Flickable (SettingsApp), to scroll an app into view.
    property Flickable flick: null

    // Settings → Window Rules opened for an app (dock / app menu,
    // `windowrules open APP`): that app expanded and scrolled into view.
    property string revealApp: ""
    Connections {
        target: WindowRules
        function onFocusAppChanged() {
            if (WindowRules.focusApp !== "")
                page.reveal(WindowRules.focusApp);
        }
    }
    Component.onCompleted: {
        WindowRules.refresh();
        if (WindowRules.focusApp !== "")
            reveal(WindowRules.focusApp);
    }
    onVisibleChanged: {
        if (!visible)
            return;
        WindowRules.refresh();
        if (revealApp !== "")
            revealTimer.restart();
    }

    function reveal(app) {
        selected = app;
        query = "";
        search.clear();
        revealApp = app;
        revealTimer.tries = 0;
        revealTimer.restart();
    }

    // The page lays out after it becomes visible (and again when the list
    // refreshes), so look for the row a few times until it has a place.
    Timer {
        id: revealTimer
        property int tries: 0
        interval: 120
        onTriggered: {
            if (!page.visible || page.revealApp === "" || !page.flick)
                return;
            let row = null;
            for (let i = 0; i < appList.count; i++) {
                const it = appList.itemAt(i);
                if (it && it.app === page.revealApp)
                    row = it;
            }
            if (row && row.height > 0 && page.height > 0) {
                const f = page.flick;
                const y = row.mapToItem(f.contentItem, 0, 0).y;
                const view = f.height;
                // Its header near the top, the editor below it in view.
                const want = Math.max(0, Math.min(y - 12, f.contentHeight - view));
                f.contentY = want;
                if (++tries < 4) {
                    restart(); // once more after the editor's height settles
                    return;
                }
                page.revealApp = "";
                return;
            }
            if (++tries < 25)
                restart();
            else
                page.revealApp = "";
        }
    }

    function pct(v) {
        return Math.round(v * 100) + "%";
    }

    // The app list: the selected app, then apps with rules, then running
    // apps and apps your config names; filtered by the search.
    readonly property var apps: {
        const ids = WindowRules.knownApps();
        if (selected !== "" && !ids.includes(selected))
            ids.push(selected);
        const q = query.toLowerCase();
        const has = a => Object.keys(WindowRules.rule(a)).length > 0;
        return ids.filter(a => q === "" || a.toLowerCase().includes(q) || Apps.name(a).toLowerCase().includes(q)).sort((a, b) => {
            const ra = has(a) ? 0 : 1, rb = has(b) ? 0 : 1;
            return ra - rb || Apps.name(a).localeCompare(Apps.name(b));
        });
    }

    // Rules in the config that name no single app (global, title matches).
    readonly property var otherRules: WindowRules.configRules.filter(r => (r.app_ids ?? []).length === 0 || (r.app_ids ?? []).every(a => WindowRules.literal(a) === null))

    function originText(r) {
        const where = `${(r.file ?? "").replace(/^.*\//, "")}:${r.line}`;
        switch (r.origin) {
        case "loft":
            return `Loft · ${where}`;
        case "theme":
            return `Theme · ${where}`;
        }
        return `Your niri config · ${where}`;
    }

    function addApp(id) {
        if (!id)
            return;
        selected = id;
    }

    // Installed apps: { value: niri app id (StartupWMClass, else the entry id), label }.
    readonly property var installed: DesktopEntries.applications.values.filter(e => !e.noDisplay).map(e => ({
                value: e.startupClass || e.id,
                label: e.name
            })).sort((a, b) => a.label.localeCompare(b.label))

    // ── Translucent windows ──────────────────────────────────────────────
    SettingsCard {
        PageHeader {
            title: "Translucent Windows"
            SettingsButton {
                text: "Restore Defaults"
                enabled: Object.keys(WindowRules.userGlass).length > 0 || Object.keys(WindowRules.rules).length > 0
                onClicked: page.confirmRestore = true
            }
        }

        RowLayout {
            Layout.fillWidth: true
            visible: page.confirmRestore
            spacing: 8
            Text {
                Layout.fillWidth: true
                text: "Back to the theme's translucency and the built-in opaque list? Every per-app rule here (Assign To included) is removed."
                color: Theme.warn
                font.family: Theme.fontUi
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }
            SettingsButton {
                text: "Cancel"
                onClicked: page.confirmRestore = false
            }
            SettingsButton {
                text: "Restore"
                primary: true
                onClicked: {
                    page.confirmRestore = false;
                    WindowRules.reset();
                }
            }
        }

        SettingsRow {
            label: "Translucent windows"
            hint: page.userG.enabled !== undefined ? "Yours — every window shows a frosted blur of what's behind it" : themeG.enabled ? "Following the theme — every window shows a frosted blur of what's behind it" : "Off in this theme (or Reduce Transparency)"
            SettingsSwitch {
                checked: WindowRules.enabled
                onToggled: on => WindowRules.setGlass({ enabled: on })
            }
        }

        SettingsRow {
            label: "Focused window"
            hint: page.userG.focused !== undefined ? `Theme: ${page.pct(page.themeG.focused ?? 0.9)}` : "Following the theme"
            enabled: WindowRules.enabled
            SettingsSlider {
                from: 0.6
                to: 1
                step: 0.01
                value: page.g.focused ?? 0.9
                format: v => page.pct(v)
                onCommitted: v => WindowRules.setGlass({ focused: Math.round(v * 100) / 100 })
            }
        }

        SettingsRow {
            label: "Other windows"
            hint: page.userG.unfocused !== undefined ? `Theme: ${page.pct(page.themeG.unfocused ?? 0.8)}` : "Following the theme"
            enabled: WindowRules.enabled
            SettingsSlider {
                from: 0.5
                to: 1
                step: 0.01
                value: page.g.unfocused ?? 0.8
                format: v => page.pct(v)
                onCommitted: v => WindowRules.setGlass({ unfocused: Math.round(v * 100) / 100 })
            }
        }

        SettingsRow {
            label: "Blur behind windows"
            hint: "Off: plain see-through (cheaper on the GPU)"
            enabled: WindowRules.enabled
            SettingsSwitch {
                checked: page.g.blur === true
                onToggled: on => WindowRules.setGlass({ blur: on })
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Text {
                Layout.fillWidth: true
                text: "niri fades the whole window, text included. Apps that draw their own see-through background (a terminal's background opacity) look sharper with “App's own”. niri can't tell full-screen windows apart, so video players and games are kept opaque below; keep any other app opaque from its dock menu (Window Rules ▸ Keep Opaque) or here."
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }
            Text {
                visible: page.userG.enabled !== undefined || page.userG.focused !== undefined || page.userG.unfocused !== undefined || page.userG.blur !== undefined
                text: "Use the theme's"
                color: Theme.accent
                font.family: Theme.fontUi
                font.pixelSize: 12
                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: WindowRules.setGlass({ enabled: null, focused: null, unfocused: null, blur: null })
                }
            }
        }

        Repeater {
            model: (WindowRules.error ? [WindowRules.error] : []).concat(NiriSettings.error && NiriSettings.error !== WindowRules.error ? [NiriSettings.error] : [])
            delegate: Text {
                required property string modelData
                Layout.fillWidth: true
                text: modelData
                color: Theme.warn
                font.family: Theme.fontUi
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }
        }
    }

    // ── Apps ─────────────────────────────────────────────────────────────
    SettingsCard {
        spacing: 6

        PageHeader {
            title: "Apps"
            Text {
                text: `${page.apps.length}`
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 12
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Icon {
                text: "󰍉"
                size: 14
                color: Theme.subtext
            }
            SettingsTextField {
                id: search
                Layout.fillWidth: true
                placeholder: "Search apps and app ids"
                onEdited: t => page.query = t.trim()
            }
            SettingsSelect {
                implicitWidth: 170
                placeholder: "Add an app…"
                options: page.installed
                current: null
                onActivated: v => page.addApp(v)
            }
            SettingsTextField {
                id: idField
                implicitWidth: 140
                placeholder: "or an app id"
                onCommitted: t => {
                    page.addApp(t.trim());
                    idField.clear();
                }
            }
        }

        Repeater {
            id: appList
            model: page.apps

            delegate: ColumnLayout {
                id: appRow
                required property string modelData
                readonly property string app: modelData
                readonly property bool open: page.selected === app
                readonly property var rec: WindowRules.rule(app)
                readonly property var builtin: WindowRules.builtinFor(app)
                readonly property var badges: WindowRules.summary(app)
                readonly property bool running: Niri.windows.some(w => w.app_id === app)
                Layout.fillWidth: true
                spacing: 6

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 40
                    radius: 8
                    color: appRow.open ? Theme.withAlpha(Theme.accent, 0.14) : rowHover.hovered ? Theme.withAlpha(Theme.text, 0.05) : "transparent"

                    HoverHandler {
                        id: rowHover
                    }

                    RowLayout {
                        anchors {
                            fill: parent
                            leftMargin: 8
                            rightMargin: 8
                        }
                        spacing: 10

                        AppIcon {
                            Layout.preferredWidth: 24
                            Layout.preferredHeight: 24
                            appId: appRow.app
                            pixelSize: 48
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text {
                                Layout.fillWidth: true
                                text: Apps.name(appRow.app)
                                color: Theme.text
                                font.family: Theme.fontUi
                                font.pixelSize: 13
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                text: appRow.app + (appRow.running ? "  ·  open" : "")
                                color: Theme.subtext
                                font.family: "monospace"
                                font.pixelSize: 10
                                elide: Text.ElideRight
                            }
                        }
                        Repeater {
                            model: appRow.badges
                            delegate: Rectangle {
                                required property string modelData
                                implicitWidth: badge.implicitWidth + 14
                                implicitHeight: 20
                                radius: 10
                                color: Theme.withAlpha(Theme.text, 0.09)
                                Text {
                                    id: badge
                                    anchors.centerIn: parent
                                    text: parent.modelData
                                    color: Theme.text
                                    font.family: Theme.fontUi
                                    font.pixelSize: 11
                                }
                            }
                        }
                        Icon {
                            text: appRow.open ? "󰅀" : "󰅂"
                            size: 12
                            color: Theme.subtext
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page.selected = appRow.open ? "" : appRow.app
                    }
                }

                // ── The app's editor ─────────────────────────────────────
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 42
                    Layout.rightMargin: 8
                    Layout.bottomMargin: 8
                    visible: appRow.open
                    spacing: 12

                    SettingsRow {
                        visible: appRow.builtin !== null
                        label: "Built-in: kept opaque"
                        hint: appRow.builtin ? `${appRow.builtin.label} — on Loft's opaque list` : ""
                        SettingsSwitch {
                            checked: appRow.builtin?.on === true
                            onToggled: on => WindowRules.setDefaultOn(appRow.builtin.id, on)
                        }
                    }

                    SettingsRow {
                        label: "Transparency"
                        hint: {
                            switch (appRow.rec.glass) {
                            case "opaque":
                                return "Always opaque";
                            case "custom":
                                return "Its own opacity, even with translucent windows off";
                            case "native":
                                return "Opaque, blurred behind: for apps that draw their own see-through background";
                            }
                            return appRow.builtin?.on ? "Default: opaque (built-in list)" : WindowRules.enabled ? "Default: the global look" : "Default: opaque (translucent windows are off)";
                        }
                        SettingsSegmented {
                            options: [{ value: "", label: "Default" }, { value: "opaque", label: "Opaque" }, { value: "custom", label: "Custom" }, { value: "native", label: "App's own" }]
                            current: appRow.rec.glass ?? ""
                            onActivated: v => WindowRules.setRule(appRow.app, v === "custom" ? { glass: v, opacity: page.g.focused ?? 0.9, "opacity-unfocused": page.g.unfocused ?? 0.8 } : { glass: v === "" ? null : v })
                        }
                    }

                    SettingsRow {
                        visible: appRow.rec.glass === "custom"
                        label: "Focused"
                        SettingsSlider {
                            from: 0.3
                            to: 1
                            step: 0.01
                            value: appRow.rec.opacity ?? 0.9
                            format: v => page.pct(v)
                            onCommitted: v => WindowRules.setField(appRow.app, "opacity", Math.round(v * 100) / 100)
                        }
                    }
                    SettingsRow {
                        visible: appRow.rec.glass === "custom"
                        label: "Unfocused"
                        SettingsSlider {
                            from: 0.3
                            to: 1
                            step: 0.01
                            value: appRow.rec["opacity-unfocused"] ?? appRow.rec.opacity ?? 0.8
                            format: v => page.pct(v)
                            onCommitted: v => WindowRules.setField(appRow.app, "opacity-unfocused", Math.round(v * 100) / 100)
                        }
                    }

                    SettingsRow {
                        label: "Blur behind"
                        hint: appRow.rec.blur === undefined ? `Default: ${WindowRules.blurDefault(appRow.app) ? "on" : "off"}` : ""
                        SettingsSegmented {
                            options: [{ value: "default", label: "Default" }, { value: "on", label: "On" }, { value: "off", label: "Off" }]
                            current: appRow.rec.blur === undefined ? "default" : appRow.rec.blur ? "on" : "off"
                            onActivated: v => WindowRules.setField(appRow.app, "blur", v === "default" ? null : v === "on")
                        }
                    }

                    SettingsRow {
                        label: "Open floating"
                        SettingsSwitch {
                            checked: appRow.rec["open-floating"] === true
                            onToggled: on => WindowRules.setField(appRow.app, "open-floating", on ? true : null)
                        }
                    }
                    SettingsRow {
                        label: "Open maximized"
                        SettingsSwitch {
                            checked: appRow.rec["open-maximized"] === true
                            onToggled: on => WindowRules.setField(appRow.app, "open-maximized", on ? true : null)
                        }
                    }
                    SettingsRow {
                        label: "Open full screen"
                        SettingsSwitch {
                            checked: appRow.rec["open-fullscreen"] === true
                            onToggled: on => WindowRules.setField(appRow.app, "open-fullscreen", on ? true : null)
                        }
                    }
                    SettingsRow {
                        label: "Column width"
                        hint: "When it opens tiled"
                        SettingsSelect {
                            options: [{ value: 0, label: "Default" }, { value: 0.3333, label: "One third" }, { value: 0.5, label: "Half" }, { value: 0.6667, label: "Two thirds" }, { value: 1, label: "Full width" }]
                            current: appRow.rec["default-column-width"] ?? 0
                            onActivated: v => WindowRules.setField(appRow.app, "default-column-width", v === 0 ? null : v)
                        }
                    }
                    SettingsRow {
                        label: "Square corners"
                        SettingsSwitch {
                            checked: appRow.rec["square-corners"] === true
                            onToggled: on => WindowRules.setField(appRow.app, "square-corners", on ? true : null)
                        }
                    }
                    SettingsRow {
                        label: "Hide from screen capture"
                        hint: "Blacked out in screencasts (or in screenshots too)"
                        SettingsSelect {
                            options: [{ value: "", label: "Never" }, { value: "screencast", label: "Screencasts" }, { value: "screen-capture", label: "All capture" }]
                            current: appRow.rec["block-out-from"] ?? ""
                            onActivated: v => WindowRules.setField(appRow.app, "block-out-from", v === "" ? null : v)
                        }
                    }
                    SettingsRow {
                        visible: (appRow.rec["open-on-workspace"] ?? "") !== ""
                        label: "Assigned to"
                        hint: `Opens on “${appRow.rec["open-on-workspace"] ?? ""}” (the dock's Assign To)`
                        SettingsButton {
                            text: "Unassign"
                            onClicked: WindowRules.setField(appRow.app, "open-on-workspace", null)
                        }
                    }

                    // Rules from the niri config that name this app.
                    Repeater {
                        model: WindowRules.configRulesFor(appRow.app)
                        delegate: ConfigRule {}
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Item {
                            Layout.fillWidth: true
                        }
                        SettingsButton {
                            text: "Remove Rule"
                            enabled: Object.keys(appRow.rec).length > 0
                            onClicked: WindowRules.removeRule(appRow.app)
                        }
                    }
                }
            }
        }
    }

    // ── The built-in opaque list ─────────────────────────────────────────
    SettingsCard {
        spacing: 8
        PageHeader {
            title: "Kept Opaque by Default"
        }
        Text {
            Layout.fillWidth: true
            text: "See-through hurts here: video, games (full screen included), color and audio work. Turn one off to give it the global look."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }
        Repeater {
            model: WindowRules.defaults
            delegate: SettingsRow {
                required property var modelData
                label: modelData.label
                hint: (modelData.app_ids ?? []).map(a => WindowRules.literal(a) ?? a).concat((modelData.titles ?? []).map(t => `title ${t}`)).join("  ·  ")
                SettingsSwitch {
                    checked: modelData.on
                    onToggled: on => WindowRules.setDefaultOn(modelData.id, on)
                }
            }
        }
    }

    // ── Other rules (read-only) ──────────────────────────────────────────
    SettingsCard {
        visible: page.otherRules.length > 0
        spacing: 6
        PageHeader {
            title: "Other Rules"
        }
        Text {
            Layout.fillWidth: true
            text: "Window rules for all windows or by title, from Loft, the theme and your niri config. Edit them in their files."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }
        Repeater {
            model: page.otherRules
            delegate: ConfigRule {}
        }
    }

    // One window-rule from the config (read-only).
    component ConfigRule: Rectangle {
        required property var modelData
        Layout.fillWidth: true
        implicitHeight: col.implicitHeight + 12
        radius: 8
        color: Theme.withAlpha(Theme.text, 0.04)

        ColumnLayout {
            id: col
            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                leftMargin: 10
                rightMargin: 10
            }
            spacing: 2
            Text {
                Layout.fillWidth: true
                text: page.originText(modelData) + (modelData.origin === "config" && modelData.sets_opacity ? "  ·  its opacity wins over Translucent Windows" : "")
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                elide: Text.ElideMiddle
            }
            Text {
                Layout.fillWidth: true
                text: (modelData.matches.length ? modelData.matches.map(m => "match " + m).join("  |  ") : "all windows") + (modelData.excludes.length ? "  ·  except " + modelData.excludes.join(", ") : "")
                color: Theme.text
                font.family: "monospace"
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }
            Text {
                Layout.fillWidth: true
                text: modelData.settings.join("  ·  ")
                color: Theme.text
                font.family: "monospace"
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }
        }
    }
}
