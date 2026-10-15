import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Spaces: one space's editor (docs/SPACES.md §5, §6.4). Every
// change is a JSON merge patch through Spaces.patch → `loft-niri space
// patch`, which validates it against the whole library before writing (an
// instance's patch lands in its `overrides`). `space` is the row of
// `loft-niri space list --json` (looked up by id in Spaces.all: a model's
// modelData would turn its lists into sequence wrappers); `doc` the
// resolved document.
ColumnLayout {
    id: ed
    required property string spaceId
    readonly property var space: Spaces.all.find(s => s.id === spaceId) ?? ({ id: spaceId, name: "", displays: {}, doc: {} })
    readonly property var doc: space.doc ?? {}
    readonly property bool isInstance: !!space.template
    property bool confirmDelete: false
    signal deleted

    spacing: 12

    function patch(p) {
        Spaces.patch(space.id, p);
    }

    // "MPG491CX OLED (center)" for an output connector.
    function where(output) {
        const s = Displays.screens.find(x => x.name === output);
        return s ? DockData.displayLabel(s) : output;
    }

    component Section: Text {
        Layout.fillWidth: true
        Layout.topMargin: 4
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
        font.weight: Font.DemiBold
        font.capitalization: Font.AllUppercase
    }

    component Chip: Rectangle {
        id: chip
        property string text
        property bool selected: false
        property bool removable: false
        signal clicked
        implicitWidth: chipRow.implicitWidth + 16
        implicitHeight: 24
        radius: 12
        color: selected ? Theme.withAlpha(Theme.accent, 0.35) : chipHover.containsMouse ? Theme.withAlpha(Theme.text, 0.12) : Theme.withAlpha(Theme.text, 0.07)
        border.width: selected ? 1 : 0
        border.color: Theme.withAlpha(Theme.accent, 0.6)
        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 5
            Text {
                text: chip.text
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 11
                anchors.verticalCenter: parent.verticalCenter
            }
            Icon {
                visible: chip.removable
                text: "󰅖"
                size: 10
                color: Theme.subtext
                anchors.verticalCenter: parent.verticalCenter
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

    // ── Name and icon ────────────────────────────────────────────────────
    SettingsRow {
        label: "Name"
        hint: ed.isInstance ? `From the “${ed.space.template}” template; a name here overrides it` : ""
        SettingsTextField {
            implicitWidth: 220
            text: ed.space.name
            onCommitted: t => {
                const v = t.trim();
                if (v !== "" && v !== ed.space.name)
                    ed.patch({ name: v });
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 16
        Text {
            Layout.alignment: Qt.AlignTop
            Layout.topMargin: 6
            text: "Icon"
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 13
        }
        SpaceIconPicker {
            Layout.fillWidth: true
            current: ed.space.icon ?? ""
            onPicked: icon => ed.patch({ icon: icon })
        }
    }

    // ── Displays ─────────────────────────────────────────────────────────
    Section {
        text: "Displays"
    }
    Text {
        Layout.fillWidth: true
        text: "What the space shows on each display, by role (where the display sits, not its connector). “Keep” leaves a display alone when the space activates, so a chat on the side stays visible."
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }

    // Roles to offer: the ones the space binds, plus each live display's own.
    readonly property var roleRows: {
        const d = doc.displays ?? {};
        const set = ["main"];
        for (const r of Object.keys(d))
            if (r !== "*" && !set.includes(r))
                set.push(r);
        for (const disp of Spaces.layout) {
            const r = (disp.roles ?? [])[0];
            if (r && r !== "*" && !set.includes(r))
                set.push(r);
        }
        return set.sort((a, b) => (a === "main" ? -1 : b === "main" ? 1 : a.localeCompare(b)));
    }
    readonly property var extraRoles: {
        const all = ["left", "right", "top", "bottom", "left-2", "right-2", "portrait", "landscape", "ultrawide"];
        for (const disp of Spaces.layout)
            for (const r of disp.roles ?? [])
                if (r !== "*" && !all.includes(r))
                    all.push(r);
        return all.filter(r => !roleRows.includes(r)).map(r => ({ value: r, label: r }));
    }

    Repeater {
        model: ed.roleRows
        delegate: RowLayout {
            id: roleRow
            required property string modelData
            readonly property string role: modelData
            readonly property var raw: (ed.doc.displays ?? {})[role]
            readonly property bool bound: raw !== undefined && raw !== null && raw !== "keep"
            readonly property var live: Spaces.layout.find(d => (d.roles ?? []).includes(role)) ?? null
            readonly property string ws: ed.space.displays?.[role] ?? ""
            readonly property int apps: bound ? (raw.apps ?? []).length : 0
            Layout.fillWidth: true
            spacing: 10

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                    text: roleRow.role
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                    font.weight: Font.Medium
                }
                Text {
                    Layout.fillWidth: true
                    text: [roleRow.live ? ed.where(roleRow.live.name) : "no display has this role now", roleRow.apps > 0 ? `${roleRow.apps} app${roleRow.apps === 1 ? "" : "s"}` : ""].filter(s => s).join("  ·  ")
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }
            SettingsTextField {
                visible: roleRow.bound
                implicitWidth: 150
                text: roleRow.raw?.workspace ?? ""
                placeholder: roleRow.ws || "workspace"
                onCommitted: t => {
                    const d = {};
                    d[roleRow.role] = { workspace: t.trim() || null };
                    ed.patch({ displays: d });
                }
            }
            SettingsSegmented {
                options: [{ value: "keep", label: "Keep" }, { value: "own", label: "Workspace" }]
                current: roleRow.bound ? "own" : "keep"
                onActivated: v => {
                    if ((v === "own") === roleRow.bound)
                        return;
                    const d = {};
                    d[roleRow.role] = v === "own" ? {} : "keep";
                    ed.patch({ displays: d });
                }
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Item {
            Layout.fillWidth: true
        }
        SettingsSelect {
            implicitWidth: 190
            placeholder: "Add a display role…"
            options: ed.extraRoles
            current: null
            onActivated: v => {
                const d = {};
                d[v] = {};
                ed.patch({ displays: d });
            }
        }
    }

    // ── Dock ─────────────────────────────────────────────────────────────
    Section {
        text: "Dock"
    }
    readonly property var dock: doc.dock ?? {}
    readonly property string dockMode: Array.isArray(dock.pinned) ? (dock.mode ?? "replace") : ""
    SettingsRow {
        label: "Pinned apps"
        hint: ({
                "": "The dock's own pinned apps",
                replace: "Only this space's apps",
                prepend: "This space's apps, then the dock's",
                append: "The dock's apps, then this space's"
            })[ed.dockMode]
        SettingsSegmented {
            options: [{ value: "", label: "Dock's" }, { value: "replace", label: "Space's" }, { value: "prepend", label: "Before" }, { value: "append", label: "After" }]
            current: ed.dockMode
            onActivated: v => ed.patch({ dock: v === "" ? { pinned: null, mode: null } : { pinned: Array.isArray(ed.dock.pinned) ? ed.dock.pinned : [], mode: v } })
        }
    }
    AppIdList {
        visible: ed.dockMode !== ""
        Layout.leftMargin: 12
        apps: Array.isArray(ed.dock.pinned) ? ed.dock.pinned : []
        emptyText: "No apps pinned for this space yet"
        onChanged: list => ed.patch({ dock: { pinned: list } })
    }
    SettingsRow {
        label: "Dock visibility"
        SettingsSegmented {
            options: [{ value: "", label: "As set" }, { value: "show", label: "Show" }, { value: "autohide", label: "Auto-hide" }, { value: "hidden", label: "Hidden" }]
            current: ed.dock.visible ?? ""
            onActivated: v => ed.patch({ dock: { visible: v === "" ? null : v } })
        }
    }

    // ── Menu bar ─────────────────────────────────────────────────────────
    Section {
        text: "Menu Bar"
    }
    SettingsRow {
        label: "Hide the menu bar"
        hint: "On the displays showing this space (games, full-screen work)"
        SettingsSwitch {
            checked: ed.doc.bar?.hidden === true
            onToggled: on => ed.patch({ bar: { hidden: on ? true : null } })
        }
    }
    readonly property var extras: Array.isArray(doc.menubar?.extras) ? doc.menubar.extras : null
    // What's on the menu bar now: the readouts, then the status items.
    readonly property var barItems: Array.from(Settings.system.readouts).map(k => ({
                id: `readout.${k}`,
                label: Controls.readoutLabels[k] ?? k
            })).concat(Controls.controls.filter(c => c.bar && c.id !== "controlcenter" && Controls.available(c.id) && Controls.onBar(c.id)))
    function extraOn(id) {
        const l = extras ?? [];
        return l.includes(id) || (id.startsWith("readout.") && l.includes(id.slice(8)));
    }
    SettingsRow {
        label: "Only some status items"
        hint: ed.extras === null ? "Every status item you have on the menu bar" : "The ones picked below (Control Center always stays)"
        SettingsSwitch {
            checked: ed.extras !== null
            onToggled: on => ed.patch({ menubar: { extras: on ? ed.barItems.map(c => c.id) : null } })
        }
    }
    Flow {
        visible: ed.extras !== null
        Layout.fillWidth: true
        Layout.leftMargin: 12
        spacing: 6
        Repeater {
            model: ed.barItems
            delegate: Chip {
                required property var modelData
                text: modelData.label
                selected: ed.extraOn(modelData.id)
                onClicked: {
                    const short = modelData.id.startsWith("readout.") ? modelData.id.slice(8) : "";
                    const l = (ed.extras ?? []).filter(x => x !== modelData.id && x !== short);
                    if (!selected)
                        l.push(modelData.id);
                    ed.patch({ menubar: { extras: l } });
                }
            }
        }
    }

    // ── Focus ────────────────────────────────────────────────────────────
    Section {
        text: "Focus"
    }
    readonly property var focusDoc: doc.focus ?? {}
    readonly property var allow: Array.isArray(focusDoc.allow) ? focusDoc.allow : []
    SettingsRow {
        label: "Do Not Disturb"
        hint: "On while this space is active; back as it was when you leave"
        SettingsSwitch {
            checked: ed.focusDoc.dnd === true
            onToggled: on => ed.patch({ focus: { dnd: on } })
        }
    }
    ColumnLayout {
        visible: ed.focusDoc.dnd === true
        Layout.fillWidth: true
        Layout.leftMargin: 12
        spacing: 6
        Text {
            text: "Allowed to notify anyway"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
        Flow {
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: ed.allow
                delegate: Chip {
                    required property string modelData
                    text: modelData
                    removable: true
                    onClicked: ed.patch({ focus: { allow: ed.allow.filter(a => a !== modelData) } })
                }
            }
            Text {
                visible: ed.allow.length === 0
                text: "Nobody"
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
            }
        }
        RowLayout {
            spacing: 8
            SettingsSelect {
                implicitWidth: 190
                placeholder: "Add a running app…"
                options: [...new Set(Niri.windows.map(w => Apps.name(w.app_id)).filter(n => n && !ed.allow.includes(n)))].sort().map(n => ({ value: n, label: n }))
                current: null
                onActivated: v => ed.patch({ focus: { allow: ed.allow.concat([v]) } })
            }
            SettingsTextField {
                id: allowField
                implicitWidth: 160
                placeholder: "or an app name"
                onCommitted: t => {
                    const v = t.trim();
                    if (v !== "" && !ed.allow.includes(v))
                        ed.patch({ focus: { allow: ed.allow.concat([v]) } });
                    allowField.clear();
                }
            }
        }
    }

    // ── Apps ─────────────────────────────────────────────────────────────
    Section {
        text: "Apps"
    }
    SettingsRow {
        label: "Start its apps"
        hint: "Open starts them any time; spaces without apps have nothing to start"
        SettingsSegmented {
            options: [{ value: "first-activate", label: "First switch" }, { value: "login", label: "At login" }, { value: "never", label: "Only on Open" }]
            current: ed.space.doc?.startup ?? "first-activate"
            onActivated: v => ed.patch({ startup: v === "first-activate" ? null : v })
        }
    }

    // ── Delete / archive ─────────────────────────────────────────────────
    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        color: Theme.glassBorder
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Text {
            Layout.fillWidth: true
            visible: ed.confirmDelete
            text: `Delete “${ed.space.name}”? Its windows stay where they are; the spaces after it move up a ⌘ number.`
            color: Theme.warn
            font.family: Theme.fontUi
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }
        Text {
            Layout.fillWidth: true
            visible: !ed.confirmDelete
            text: `${ed.space.id}.json in ${Spaces.libraryDir}${ed.isInstance ? "/instances" : ""}`
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 10
            elide: Text.ElideMiddle
        }
        SettingsButton {
            visible: ed.isInstance && !ed.confirmDelete
            text: "Archive"
            onClicked: ed.patch({ archived: true })
        }
        SettingsButton {
            visible: !ed.confirmDelete
            text: "Delete Space…"
            onClicked: ed.confirmDelete = true
        }
        SettingsButton {
            visible: ed.confirmDelete
            text: "Cancel"
            onClicked: ed.confirmDelete = false
        }
        SettingsButton {
            visible: ed.confirmDelete
            text: "Delete"
            primary: true
            onClicked: {
                ed.confirmDelete = false;
                Spaces.remove(ed.space.id, r => {
                    if (r.ok)
                        ed.deleted();
                });
            }
        }
    }
}
