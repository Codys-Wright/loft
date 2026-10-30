import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services

// Settings → Keyboard Remaps: Loft's keyboard layer, the macOS-style remaps
// xremap runs (⌘ as Ctrl in apps, Esc / Caps Lock hold = the window-manager
// key, ⌥ word navigation, per-app extras).
//
//   Remap Groups   every group on / off (its keys shown), back to default
//   Apps           per app: leave alone, the kinds of app it counts as
//                  (terminal, browser …), groups off just there, its own
//                  remaps (they win over every group)
//   Every App      remaps for all apps
//
// Writes go through KeyRemaps → `loft keys …`: checked before they're saved
// (refused with the reason, shown here), xremap reloads by itself. Agents use
// the same commands (and the loft_keys_* MCP tools).
ColumnLayout {
    id: page
    spacing: 12

    property string query: ""
    property string selected: ""
    // A group whose keys are shown.
    property string openGroup: ""

    property Flickable flick: null
    property bool shown: true
    readonly property bool active: visible && shown

    Component.onCompleted: {
        KeyRemaps.refresh();
        if (KeyRemaps.focusApp !== "")
            reveal(KeyRemaps.focusApp);
    }
    onVisibleChanged: {
        if (visible)
            KeyRemaps.refresh();
    }
    Connections {
        target: KeyRemaps
        function onFocusAppChanged() {
            if (KeyRemaps.focusApp !== "")
                page.reveal(KeyRemaps.focusApp);
        }
    }

    function reveal(app) {
        selected = app;
        query = "";
        search.clear();
        revealTimer.tries = 0;
        revealTimer.restart();
    }

    // Scroll the selected app's row into view once it is laid out.
    Timer {
        id: revealTimer
        property int tries: 0
        interval: 120
        onTriggered: {
            if (!page.visible || !page.flick || page.selected === "")
                return;
            for (let i = 0; i < appList.count; i++) {
                const it = appList.itemAt(i);
                if (it && it.app === page.selected && it.height > 0) {
                    const f = page.flick;
                    const y = it.mapToItem(f.contentItem, 0, 0).y;
                    f.contentY = Math.max(0, Math.min(y - 12, f.contentHeight - f.height));
                    return;
                }
            }
            if (++tries < 25)
                restart();
        }
    }

    function sourceText(s) {
        return s === "nix" ? "set in Nix" : s === "runtime" ? "yours" : "";
    }

    function groupHint(g) {
        const bits = [];
        if (g.description)
            bits.push(g.description);
        const a = g.application ?? {};
        if (a.only !== undefined)
            bits.push("only in " + [].concat(a.only).map(n => n.startsWith("@") ? (KeyRemaps.classes[n.slice(1)]?.name ?? n) : n).join(", "));
        const src = sourceText(g.onSource ?? (g.source !== "loft" ? g.source : ""));
        if (src)
            bits.push(src);
        return bits.join("  ·  ");
    }

    // The app list: the selected app, then apps with something set, then
    // open windows; filtered by the search. A string so the Repeater only
    // rebuilds when the list really changes (niri events re-run this).
    readonly property string appsKey: {
        if (!active)
            return "";
        const ids = KeyRemaps.knownApps();
        if (selected !== "" && !ids.includes(selected))
            ids.push(selected);
        const q = query.toLowerCase();
        const has = a => KeyRemaps.appRules[a] !== undefined || KeyRemaps.leftAlone(a);
        const names = {};
        for (const a of ids)
            names[a] = Apps.name(a);
        return ids.filter(a => q === "" || a.toLowerCase().includes(q) || names[a].toLowerCase().includes(q)).sort((a, b) => {
            const ra = has(a) ? 0 : 1, rb = has(b) ? 0 : 1;
            return ra - rb || names[a].localeCompare(names[b]);
        }).join("\n");
    }
    readonly property var apps: appsKey === "" ? [] : appsKey.split("\n")

    readonly property var installed: !active ? [] : Apps.entries.filter(e => !e.noDisplay).map(e => ({
                value: e.startupClass || e.id,
                label: e.name
            })).sort((a, b) => a.label.localeCompare(b.label))

    // ── Status ───────────────────────────────────────────────────────────
    SettingsCard {
        PageHeader {
            title: "Keyboard Layer"
        }

        SettingsRow {
            label: "Status"
            hint: !KeyRemaps.loaded ? "Reading…" : KeyRemaps.following ? "Running — xremap follows this page; changes apply as you make them" : "xremap isn't running Loft's keymap (programs.loft.keyboard.enable, loft-keys.service). Changes are kept and apply once it runs."
            hintColor: KeyRemaps.loaded && !KeyRemaps.following ? Theme.warn : Theme.subtext
            Text {
                text: KeyRemaps.busy ? "Saving…" : ""
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
            }
        }

        Text {
            Layout.fillWidth: true
            text: "Keys are remapped before apps see them, the way a Mac keyboard works: ⌘ (the Super key) runs app shortcuts — ⌘C copies, ⌘Q quits — and in terminals ⌘C / ⌘V copy and paste without sending Ctrl+C. Each app gets the groups meant for its kind (terminal, browser, file manager, editor). If an app misbehaves, fix it below under Apps instead of turning a group off everywhere. The window-manager shortcuts (Mod+…) are niri's: Keyboard Shortcuts."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Text {
            Layout.fillWidth: true
            visible: KeyRemaps.error !== ""
            text: KeyRemaps.error
            color: Theme.warn
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }
    }

    // ── Groups ───────────────────────────────────────────────────────────
    SettingsCard {
        spacing: 6
        PageHeader {
            title: "Remap Groups"
            Text {
                text: `${KeyRemaps.groups.filter(g => g.on !== false).length} of ${KeyRemaps.groups.length} on`
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 12
            }
        }

        Repeater {
            model: KeyRemaps.groups
            delegate: ColumnLayout {
                id: groupRow
                required property var modelData
                readonly property var g: modelData
                readonly property bool open: page.openGroup === g.id
                Layout.fillWidth: true
                spacing: 4

                Item {
                    Layout.fillWidth: true
                    implicitHeight: groupHead.implicitHeight
                    RowLayout {
                        id: groupHead
                        anchors {
                            left: parent.left
                            right: parent.right
                        }
                        spacing: 8
                        Icon {
                            text: groupRow.open ? "󰅀" : "󰅂"
                            size: 12
                            color: Theme.subtext
                        }
                        SettingsRow {
                            Layout.fillWidth: true
                            label: groupRow.g.name
                            hint: page.groupHint(groupRow.g)
                            RowLayout {
                                spacing: 8
                                Text {
                                    visible: groupRow.g.onSource === "runtime"
                                    text: "↺"
                                    color: Theme.accent
                                    font.family: Theme.fontUi
                                    font.pixelSize: 14
                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -4
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: KeyRemaps.setGroup(groupRow.g.id, "default")
                                    }
                                }
                                SettingsSwitch {
                                    checked: groupRow.g.on !== false
                                    onToggled: on => KeyRemaps.setGroup(groupRow.g.id, on ? "on" : "off")
                                }
                            }
                        }
                    }

                    // The row (left of its switch and ↺) shows / hides the keys.
                    MouseArea {
                        x: 0
                        y: 0
                        width: parent.width - 90
                        height: parent.height
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page.openGroup = groupRow.open ? "" : groupRow.g.id
                    }
                }

                // The group's keys.
                Flow {
                    Layout.fillWidth: true
                    Layout.leftMargin: 20
                    Layout.bottomMargin: 6
                    visible: groupRow.open
                    spacing: 6
                    Repeater {
                        model: groupRow.open ? Object.keys(groupRow.g.remap ?? {}) : []
                        delegate: KeyChip {
                            required property string modelData
                            from: KeyRemaps.pretty(modelData)
                            to: KeyRemaps.prettyAction(groupRow.g.remap[modelData])
                        }
                    }
                }
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
                onActivated: v => page.selected = v
            }
            SettingsTextField {
                id: idField
                implicitWidth: 140
                placeholder: "or an app id"
                onCommitted: t => {
                    if (t.trim() !== "")
                        page.selected = t.trim();
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
                readonly property var rec: KeyRemaps.rule(app)
                readonly property bool alone: KeyRemaps.leftAlone(app)
                readonly property var badges: KeyRemaps.summary(app)
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
                            delegate: Badge {}
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
                    spacing: 10

                    SettingsRow {
                        label: "Leave alone"
                        hint: "No remaps at all, and Loft's window shortcuts pause while it's focused — for games, VMs and remote desktops"
                        SettingsSwitch {
                            checked: appRow.alone
                            onToggled: on => KeyRemaps.setLeaveAlone(appRow.app, on)
                        }
                    }

                    SubHeader {
                        text: "Kind of app"
                    }
                    Text {
                        Layout.fillWidth: true
                        text: "Which groups it gets: a terminal gets ⌘C / ⌘V as copy and paste instead of Ctrl+C. Turn one on when Loft doesn't know the app."
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                    }
                    Repeater {
                        model: appRow.open ? Object.keys(KeyRemaps.classes) : []
                        delegate: SettingsRow {
                            id: classRow
                            required property string modelData
                            readonly property var cls: KeyRemaps.classes[modelData]
                            readonly property bool member: KeyRemaps.matches(appRow.app, cls.apps)
                            readonly property bool own: (appRow.rec.like ?? []).includes(modelData)
                            label: cls.name
                            hint: member && !own ? "On Loft's list" : ""
                            enabled: !(member && !own)
                            SettingsSwitch {
                                checked: classRow.member
                                onToggled: on => KeyRemaps.setClass(appRow.app, classRow.modelData, on)
                            }
                        }
                    }

                    SubHeader {
                        text: "Groups in this app"
                    }
                    Repeater {
                        model: appRow.open ? KeyRemaps.groupsFor(appRow.app) : []
                        delegate: SettingsRow {
                            id: inAppRow
                            required property var modelData
                            label: modelData.group.name
                            hint: modelData.why
                            enabled: modelData.group.on !== false && !appRow.alone
                            SettingsSwitch {
                                checked: inAppRow.modelData.applies
                                onToggled: on => KeyRemaps.setGroupInApp(appRow.app, inAppRow.modelData.group.id, on)
                            }
                        }
                    }

                    SubHeader {
                        text: "Its own remaps"
                    }
                    RemapList {
                        app: appRow.app
                        remaps: appRow.rec.remap ?? {}
                        emptyText: "None — they win over every group (e.g. ⌘K → ⌃K just here)"
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Item {
                            Layout.fillWidth: true
                        }
                        SettingsButton {
                            text: "Reset App"
                            enabled: KeyRemaps.appRules[appRow.app] !== undefined || appRow.alone
                            onClicked: KeyRemaps.resetApp(appRow.app)
                        }
                    }
                }
            }
        }
    }

    // ── Every app ────────────────────────────────────────────────────────
    SettingsCard {
        spacing: 6
        PageHeader {
            title: "Every App"
        }
        Text {
            Layout.fillWidth: true
            text: "Remaps in every app (except ones left alone), before the groups. An app's own remaps still win."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }
        RemapList {
            app: ""
            remaps: KeyRemaps.everywhere
            emptyText: "None"
        }
    }

    // ── Pieces ───────────────────────────────────────────────────────────
    component SubHeader: Text {
        Layout.fillWidth: true
        Layout.topMargin: 4
        color: Theme.text
        font.family: Theme.fontUi
        font.pixelSize: 12
        font.weight: Font.DemiBold
    }

    component Badge: Rectangle {
        required property string modelData
        implicitWidth: badgeText.implicitWidth + 14
        implicitHeight: 20
        radius: 10
        color: Theme.withAlpha(Theme.text, 0.09)
        Text {
            id: badgeText
            anchors.centerIn: parent
            text: parent.modelData
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
    }

    // "⌘C → ⌃C".
    component KeyChip: Rectangle {
        id: chip
        property string from
        property string to
        implicitWidth: chipRow.implicitWidth + 16
        implicitHeight: 24
        radius: 6
        color: Theme.withAlpha(Theme.text, 0.06)
        RowLayout {
            id: chipRow
            anchors.centerIn: parent
            spacing: 6
            Text {
                text: chip.from
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 12
                font.weight: Font.Medium
            }
            Text {
                text: "→"
                color: Theme.subtext
                font.pixelSize: 11
            }
            Text {
                text: chip.to
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 12
            }
        }
    }

    // A remap list with remove buttons and an add row (xremap key names).
    component RemapList: ColumnLayout {
        id: list
        property string app
        property var remaps: ({})
        property string emptyText
        property string fromText: ""
        property string toText: ""

        readonly property string scope: app || "*"

        function add() {
            const f = fromText.trim(), t = toText.trim();
            if (f === "" || t === "")
                return;
            KeyRemaps.addRemap(app, f, t);
        }

        // Saved (it's in the list now): empty the fields. A refused one keeps
        // what was typed, with the reason below.
        onRemapsChanged: {
            if (fromText.trim() !== "" && remaps[fromText.trim()] !== undefined) {
                fromField.clear();
                toField.clear();
                fromText = "";
                toText = "";
            }
        }
        Layout.fillWidth: true
        spacing: 6

        Text {
            visible: Object.keys(list.remaps).length === 0
            text: list.emptyText
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
        Repeater {
            model: Object.keys(list.remaps)
            delegate: RowLayout {
                id: remapRow
                required property string modelData
                Layout.fillWidth: true
                spacing: 8
                KeyChip {
                    from: KeyRemaps.pretty(modelData)
                    to: KeyRemaps.prettyAction(list.remaps[modelData])
                }
                Text {
                    Layout.fillWidth: true
                    text: `${modelData} → ${[].concat(list.remaps[modelData]).join(", ")}`
                    color: Theme.subtext
                    font.family: "monospace"
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }
                SettingsButton {
                    text: "Remove"
                    onClicked: KeyRemaps.removeRemap(list.app, remapRow.modelData)
                }
            }
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            SettingsTextField {
                id: fromField
                Layout.fillWidth: true
                placeholder: "From, e.g. Super_L-k"
                onEdited: t => list.fromText = t
            }
            Text {
                text: "→"
                color: Theme.subtext
            }
            SettingsTextField {
                id: toField
                Layout.fillWidth: true
                placeholder: "To, e.g. Ctrl-k (a,b = a sequence)"
                onEdited: t => list.toText = t
            }
            SettingsButton {
                text: "Add"
                primary: true
                enabled: list.fromText.trim() !== "" && list.toText.trim() !== ""
                onClicked: list.add()
            }
        }
        Text {
            Layout.fillWidth: true
            visible: KeyRemaps.error !== "" && KeyRemaps.errorScope === list.scope
            text: KeyRemaps.error
            color: Theme.warn
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }
        Text {
            Layout.fillWidth: true
            text: "Key names are evdev's: letters, digits, Esc, Enter, Backspace, Tab, Space, Left / Right / Up / Down, LeftBrace, Grave, F1–F24 … Modifiers: Super (⌘), Ctrl, Alt (⌥), Shift, with _L / _R for one side, joined with -."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 10
            wrapMode: Text.Wrap
        }
    }
}
