import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Spaces (docs/SPACES.md §6.4, P6): every space in Mod+N order,
// which workspace it puts on each display role and where that workspace is
// right now, with Activate and Open (which also starts the space's apps).
//
// Creating and editing: New Space (name + icon), New <template> (a Project:
// its parameters), New Space from Current Desktop (what each display shows
// now, `loft-niri space capture`), and per space the editor (SpaceEditor:
// name, icon, displays, dock, menu bar, Focus, startup, delete / archive),
// moving up / down (the ⌘N order). Writes go through Spaces → `loft-niri
// space save|patch|delete|reorder`, validated against the whole library
// before anything is written.
ColumnLayout {
    id: page
    spacing: 12

    // The space whose editor is open.
    property string selected: ""
    // "" | "new" | "capture" | a template id: the form open in the header.
    property string form: ""
    property string formName: ""
    property string formIcon: ""
    property var formParams: ({})
    property string formError: ""

    onVisibleChanged: if (visible)
        Spaces.reload()

    // "MPG491CX OLED (center)" for an output connector.
    function where(output) {
        const s = Displays.screens.find(x => x.name === output);
        return s ? DockData.displayLabel(s) : output;
    }

    function slug(s) {
        return String(s).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40);
    }

    // An id no space (or workspace) has yet.
    function freshId(name) {
        const stem = slug(name) || "space";
        const taken = id => Spaces.all.some(s => s.id === id || Object.values(s.displays ?? {}).includes(id));
        if (!taken(stem))
            return stem;
        for (let n = 2;; n++)
            if (!taken(`${stem}-${n}`))
                return `${stem}-${n}`;
    }

    function openForm(kind) {
        form = form === kind ? "" : kind;
        formName = "";
        formIcon = kind === "capture" ? "󰍹" : kind === "new" ? "󰕰" : (Spaces.templates.find(t => t.id === kind)?.icon ?? "");
        formParams = {};
        formError = "";
    }

    function finish(r) {
        if (r.ok) {
            form = "";
            formError = "";
            selected = r.id ?? "";
        } else {
            formError = r.error ?? "That didn't work";
        }
    }

    function submit() {
        const name = formName.trim();
        if (form === "new") {
            if (name === "") {
                formError = "Give the space a name";
                return;
            }
            Spaces.create({
                kind: "space",
                id: freshId(name),
                name: name,
                icon: formIcon,
                displays: {
                    main: {},
                    "*": "keep"
                }
            }, finish);
        } else if (form === "capture") {
            if (name === "") {
                formError = "Give the space a name";
                return;
            }
            Spaces.capture(name, formIcon, finish);
        } else if (form !== "") {
            const t = Spaces.templates.find(t => t.id === form);
            const params = {};
            for (const [k, def] of Object.entries(t?.params ?? {})) {
                const v = String(formParams[k] ?? "").trim();
                if (v !== "")
                    params[k] = v;
                else if (def.required) {
                    formError = `${def.label ?? k} is needed`;
                    return;
                }
            }
            Spaces.create({
                kind: "space-instance",
                template: form,
                params: params
            }, finish);
        }
    }

    // A template's parameters the form asks for (the text-like ones).
    readonly property var formFields: {
        const t = Spaces.templates.find(t => t.id === form);
        if (!t)
            return [];
        return Object.entries(t.params ?? {}).filter(([k, d]) => ["string", "dir", "url", "enum"].includes(d.type)).map(([k, d]) => Object.assign({ key: k }, d));
    }

    SettingsCard {
        PageHeader {
            title: "Spaces"

            SettingsButton {
                text: "Switcher"
                icon: "󰕰"
                onClicked: Spaces.toggleSwitcher("")
            }
        }

        Text {
            Layout.fillWidth: true
            text: "A space switches every display at once: its workspace on each display role, or keeps what a display shows. ⌘1…9 activate spaces in this order, ⌃⌘← → step through them, ⌃⌘S opens the switcher."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }

        Flow {
            Layout.fillWidth: true
            spacing: 8
            SettingsButton {
                text: "New Space"
                icon: "󰐕"
                primary: page.form === "new"
                onClicked: page.openForm("new")
            }
            Repeater {
                model: Spaces.templates
                delegate: SettingsButton {
                    required property var modelData
                    text: `New ${modelData.name ?? modelData.id}`
                    icon: modelData.icon ?? ""
                    primary: page.form === modelData.id
                    onClicked: page.openForm(modelData.id)
                }
            }
            SettingsButton {
                text: "New Space from Current Desktop"
                icon: "󰍹"
                primary: page.form === "capture"
                onClicked: page.openForm("capture")
            }
        }

        // ── The open form ────────────────────────────────────────────────
        ColumnLayout {
            Layout.fillWidth: true
            visible: page.form !== ""
            spacing: 10

            Text {
                Layout.fillWidth: true
                visible: page.form === "capture"
                text: "Each display's current workspace becomes this space's workspace on that display, with its windows as the space's apps (in column order, with their widths). Displays showing nothing are kept. Activating the space gathers the windows; Open starts the ones that aren't running."
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }

            SettingsRow {
                visible: page.formFields.length === 0
                label: "Name"
                SettingsTextField {
                    implicitWidth: 240
                    text: page.formName
                    placeholder: page.form === "capture" ? "e.g. Writing" : "e.g. Design"
                    onEdited: t => page.formName = t
                    onCommitted: t => page.formName = t
                }
            }

            Repeater {
                model: page.formFields
                delegate: SettingsRow {
                    id: paramRow
                    required property var modelData
                    label: modelData.label ?? modelData.key
                    hint: [modelData.hint ?? "", modelData.required ? "required" : ""].filter(s => s).join(" · ")
                    SettingsSelect {
                        visible: paramRow.modelData.type === "enum"
                        options: (paramRow.modelData.values ?? []).map(v => ({ value: v, label: v }))
                        current: page.formParams[paramRow.modelData.key] ?? paramRow.modelData.default ?? null
                        onActivated: v => {
                            const p = Object.assign({}, page.formParams);
                            p[paramRow.modelData.key] = v;
                            page.formParams = p;
                        }
                    }
                    SettingsTextField {
                        visible: paramRow.modelData.type !== "enum"
                        implicitWidth: 260
                        text: page.formParams[paramRow.modelData.key] ?? ""
                        placeholder: paramRow.modelData.type === "dir" ? "~/Development/…" : paramRow.modelData.type === "url" ? "https://…" : ""
                        onEdited: t => {
                            const p = Object.assign({}, page.formParams);
                            p[paramRow.modelData.key] = t;
                            page.formParams = p;
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: page.formFields.length === 0
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
                    current: page.formIcon
                    onPicked: icon => page.formIcon = icon
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    text: page.formError
                    color: Theme.warn
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                }
                SettingsButton {
                    text: "Cancel"
                    onClicked: page.form = ""
                }
                SettingsButton {
                    text: page.form === "capture" ? "Capture" : "Create"
                    primary: true
                    enabled: !Spaces.writing
                    onClicked: page.submit()
                }
            }
        }

        Text {
            Layout.fillWidth: true
            text: `Spaces are JSON files in ${Spaces.libraryDir || "(no library: LOFT_LIBRARY is off)"}; the first change copies the built-in ones there.`
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Repeater {
            model: Spaces.problems.concat(Spaces.editError && page.form === "" ? [Spaces.editError] : []).concat(Spaces.lastError ? [Spaces.lastError] : [])
            delegate: Text {
                required property var modelData
                Layout.fillWidth: true
                text: `⚠ ${modelData}`
                color: Theme.warn
                font.family: Theme.fontUi
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }
        }
    }

    Text {
        Layout.fillWidth: true
        visible: Spaces.loaded && Spaces.spaces.length === 0
        horizontalAlignment: Text.AlignHCenter
        text: "No spaces — is loft-niri on PATH?"
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 13
    }

    Repeater {
        model: Spaces.spaces

        delegate: SettingsCard {
            id: card
            required property var modelData
            required property int index
            readonly property bool isActive: modelData.id === Spaces.activeId
            readonly property bool editing: page.selected === modelData.id
            readonly property var roles: {
                const d = modelData.displays ?? {};
                const keys = Object.keys(d).filter(r => r !== "*");
                keys.sort((a, b) => (a === "main" ? -1 : b === "main" ? 1 : a.localeCompare(b)));
                return keys.map(r => ({ role: r, workspace: d[r] }));
            }
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                // Move up / down in ⌘N order.
                ColumnLayout {
                    spacing: 0
                    Repeater {
                        model: [{ glyph: "󰅃", delta: -1 }, { glyph: "󰅀", delta: 1 }]
                        delegate: Icon {
                            id: arrowIcon
                            required property var modelData
                            readonly property bool can: modelData.delta < 0 ? card.index > 0 : card.index < Spaces.spaces.length - 1
                            text: modelData.glyph
                            size: 13
                            color: can ? (arrow.containsMouse ? Theme.accent : Theme.subtext) : Theme.withAlpha(Theme.subtext, 0.3)
                            MouseArea {
                                id: arrow
                                anchors.fill: parent
                                anchors.margins: -3
                                hoverEnabled: true
                                enabled: arrowIcon.can && !Spaces.writing
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Spaces.move(card.modelData.id, arrowIcon.modelData.delta)
                            }
                        }
                    }
                }

                IconBadge {
                    icon: card.modelData.icon || "󰕰"
                    badge: Spaces.badgeFor(card.modelData)
                    size: 30
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1

                    RowLayout {
                        spacing: 8
                        Text {
                            text: card.modelData.name
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 14
                            font.weight: Font.DemiBold
                        }
                        Rectangle {
                            visible: card.isActive
                            implicitWidth: activeLabel.implicitWidth + 12
                            implicitHeight: 18
                            radius: 9
                            color: Theme.withAlpha(Theme.accent, 0.22)
                            Text {
                                id: activeLabel
                                anchors.centerIn: parent
                                text: "Active"
                                color: Theme.accent
                                font.family: Theme.fontUi
                                font.pixelSize: 10
                                font.weight: Font.DemiBold
                            }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: [card.modelData.position ? `⌘${card.modelData.position}` : "", card.modelData.template ? `from ${card.modelData.template}` : "", card.modelData.id].filter(s => s).join("  ·  ")
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }

                SettingsButton {
                    text: card.editing ? "Done" : "Edit"
                    onClicked: page.selected = card.editing ? "" : card.modelData.id
                }
                SettingsButton {
                    visible: Spaces.canOpen
                    text: "Open"
                    onClicked: Spaces.open(card.modelData.id)
                }
                SettingsButton {
                    text: card.isActive ? "Bring Back" : "Activate"
                    primary: !card.isActive
                    onClicked: Spaces.focus(card.modelData.id)
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.glassBorder
            }

            // One line per display role: role → workspace → where it is now.
            Repeater {
                model: card.editing ? [] : card.roles

                delegate: RowLayout {
                    id: line
                    required property var modelData
                    readonly property bool keep: modelData.workspace === "keep"
                    readonly property var ws: keep ? null : (Niri.workspaces.find(w => w.name === modelData.workspace) ?? null)
                    readonly property int windows: ws ? Niri.windowsOn(ws.id).length : 0
                    Layout.fillWidth: true
                    spacing: 10

                    Text {
                        Layout.preferredWidth: 70
                        text: line.modelData.role
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.weight: Font.Medium
                    }
                    Text {
                        Layout.preferredWidth: 150
                        text: line.keep ? "keeps what it shows" : line.modelData.workspace
                        color: line.keep ? Theme.subtext : Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.italic: line.keep
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: !line.keep
                        text: line.ws ? `${page.where(line.ws.output)}${line.ws.is_active ? " · showing" : ""}${line.windows > 0 ? ` · ${line.windows} window${line.windows === 1 ? "" : "s"}` : ""}` : "not created yet (on first activation)"
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }
            }

            Loader {
                Layout.fillWidth: true
                active: card.editing
                visible: active
                sourceComponent: SpaceEditor {
                    spaceId: card.modelData.id
                    onDeleted: page.selected = ""
                }
            }
        }
    }

    // ── Archived instances ───────────────────────────────────────────────
    SettingsCard {
        id: archivedCard
        readonly property var archived: Spaces.all.filter(s => s.archived)
        visible: archived.length > 0
        spacing: 6
        PageHeader {
            title: "Archived"
        }
        Repeater {
            model: archivedCard.archived
            delegate: RowLayout {
                id: archivedRow
                required property var modelData
                Layout.fillWidth: true
                spacing: 10
                IconBadge {
                    icon: archivedRow.modelData.icon || "󰕰"
                    badge: "gray"
                    size: 22
                }
                Text {
                    Layout.fillWidth: true
                    text: archivedRow.modelData.name
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                    elide: Text.ElideRight
                }
                SettingsButton {
                    text: "Restore"
                    onClicked: Spaces.patch(archivedRow.modelData.id, { archived: null })
                }
                SettingsButton {
                    text: "Delete"
                    onClicked: Spaces.remove(archivedRow.modelData.id)
                }
            }
        }
    }
}
