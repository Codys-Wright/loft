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
// now, `loft-niri space capture`; KWin: the current Activity's windows),
// and per space the editor (SpaceEditor: name, icon, displays, dock, menu
// bar, Focus, startup, delete / archive),
// moving up / down (the ⌘N order). Writes go through Spaces → `loft-niri
// space save|patch|delete|reorder`, validated against the whole library
// before anything is written.
//
// KWin: the cards are the user's KDE Activities, in the order of their KDE
// "Switch to activity" keys. New Activity, the name (click to rename), the
// icon, the arrows (which move the ⌘ keys) and Remove… change the Activity
// in KDE itself (Spaces.editActivity → loft-kwin). Each can have Loft
// settings: a library document linked to it (Link… an existing one, or new
// ones), edited, unlinked or removed here. Linking only writes the
// document; the Activity isn't touched. A
// linked card lists which of its apps go to which display (`space specs`,
// Spaces.appsBySpace). Close Apps… (both) closes the space's apps after
// a confirmation (KWin: naming the windows it would close).
//
// niri: documents made only for a KDE Activity (`niri: false`) aren't
// Spaces here; they're listed in their own card, and can be made niri
// Spaces too. A niri Space linked to an Activity says so on its card.
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

    // Display name of a role's display, for the KWin app lines.
    function displayOf(name) {
        return name ? where(name) : "no display (skipped)";
    }

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
        const taken = id => Spaces.library.concat(Spaces.all).some(s => s.id === id || Object.values(s.displays ?? {}).includes(id));
        if (!taken(stem))
            return stem;
        for (let n = 2;; n++)
            if (!taken(`${stem}-${n}`))
                return `${stem}-${n}`;
    }

    function openForm(kind) {
        form = form === kind ? "" : kind;
        formName = "";
        formIcon = kind === "capture" ? "󰍹" : kind === "new" ? "󰕰" : kind === "activity" ? "activities" : (Spaces.templates.find(t => t.id === kind)?.icon ?? "");
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
        if (form === "activity") {
            if (name === "") {
                formError = "Give the Activity a name";
                return;
            }
            Spaces.editActivity({ op: "create", name: name, icon: formIcon }, r => {
                if (r.ok) {
                    form = "";
                    formError = "";
                } else {
                    formError = r.error ?? "That didn't work";
                }
            });
        } else if (form === "new") {
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
            // KWin: named like the current Activity unless given a name.
            if (name === "" && Spaces.byActivity) {
                Spaces.capture(Compositor.activityList.find(a => a.id === Compositor.currentActivity)?.name ?? "Activity", formIcon, finish);
                return;
            }
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
            text: Spaces.byActivity ? "Your spaces are your KDE Activities: each switches every display at once. Make, rename, re-icon, reorder and remove them here; Plasma sees the same Activities. Their order is their ⌘ numbers (KDE's “Switch to activity” shortcuts), so moving one moves its key. ⌘⇧N moves the focused window to one, ⌃← → switch the virtual desktops inside it (⌃⇧← → take the window along), ⌃⌘S opens the switcher. Loft adds a dock, menu bar, Focus, wallpapers or apps to an Activity only when you give it Loft settings here." : "A space switches every display at once: its workspace on each display role, or keeps what a display shows. ⌘1…9 activate spaces in this order, ⌃⌘← → step through them, ⌃⌘S opens the switcher."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 12
            wrapMode: Text.Wrap
        }

        Flow {
            Layout.fillWidth: true
            spacing: 8
            SettingsButton {
                // KWin: a new space is a new KDE Activity.
                visible: Spaces.byActivity
                text: "New Activity"
                icon: "󰐕"
                primary: page.form === "activity"
                onClicked: page.openForm("activity")
            }
            SettingsButton {
                visible: !Spaces.byActivity
                text: "New Space"
                icon: "󰐕"
                primary: page.form === "new"
                onClicked: page.openForm("new")
            }
            Repeater {
                model: Spaces.templates
                delegate: SettingsButton {
                    required property var modelData
                    visible: !Spaces.byActivity
                    text: `New ${modelData.name ?? modelData.id}`
                    icon: modelData.icon ?? ""
                    primary: page.form === modelData.id
                    onClicked: page.openForm(modelData.id)
                }
            }
            SettingsButton {
                // niri: each display's workspace; KWin: the current
                // Activity's windows, per display.
                text: Spaces.byActivity ? "Save This Activity's Apps" : "New Space from Current Desktop"
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
                visible: page.form === "activity"
                text: `A new KDE Activity, on the first free ⌘ number${Spaces.spaces.filter(s => s.position !== null && s.position !== undefined).length >= 10 ? " (all ten are taken: it gets none)" : ""}. It starts empty, with no Loft settings.`
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }

            Text {
                Layout.fillWidth: true
                visible: page.form === "capture"
                text: Spaces.byActivity ? "The windows of the current Activity become its Loft settings' apps, on the display role each one is on (left to right). Nothing moves, and the Activity itself isn't changed. Open (or its first activation in a session) starts the ones that aren't running." : "Each display's current workspace becomes this space's workspace on that display, with its windows as the space's apps (in column order, with their widths). Displays showing nothing are kept. Activating the space gathers the windows; Open starts the ones that aren't running."
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
                    placeholder: page.form === "capture" ? (Spaces.byActivity ? "the Activity's name" : "e.g. Writing") : page.form === "activity" ? "e.g. Writing" : "e.g. Design"
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
                    visible: page.form !== "activity"
                    current: page.formIcon
                    onPicked: icon => page.formIcon = icon
                }
                ActivityIconPicker {
                    Layout.fillWidth: true
                    visible: page.form === "activity"
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
                    enabled: !Spaces.writing && !Spaces.activityBusy
                    onClicked: page.submit()
                }
            }
        }

        Text {
            Layout.fillWidth: true
            text: Spaces.byActivity ? `Loft settings are JSON files in ${Spaces.libraryDir || "(no library: LOFT_LIBRARY is off)"}; the Activities themselves are KDE's.` : `Spaces are JSON files in ${Spaces.libraryDir || "(no library: LOFT_LIBRARY is off)"}; the first change copies the built-in ones there.`
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Repeater {
            model: Spaces.problems.concat(Spaces.editError && page.form === "" ? [Spaces.editError] : []).concat(Spaces.lastError ? [Spaces.lastError] : []).concat(Spaces.byActivity && Spaces.activityError && page.form === "" ? [Spaces.activityError] : [])
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
        text: Spaces.byActivity ? `No KDE Activities${Compositor.impl.activitiesError ? ": " + Compositor.impl.activitiesError : " (is kactivitymanagerd running?)"}` : "No spaces — is loft-niri on PATH?"
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
            // KWin: the apps of a linked Activity by role, from `space specs`:
            // [{ role, display, apps: "KWrite, Konsole" }], main first.
            readonly property var appLines: {
                const r = Spaces.appsBySpace[modelData.id];
                if (!Spaces.byActivity || !modelData.linked || !r)
                    return [];
                const by = {};
                for (const a of r.apps ?? []) {
                    const k = a.role || "main";
                    by[k] = by[k] ?? { role: k, display: a.display ?? "", apps: [] };
                    by[k].apps.push(a.app);
                }
                return Object.values(by).sort((a, b) => (a.role === "main" ? -1 : b.role === "main" ? 1 : a.role.localeCompare(b.role))).map(l => ({ role: l.role, display: l.display, apps: l.apps.join(", ") }));
            }
            readonly property var appNotes: Spaces.byActivity && modelData.linked ? (Spaces.appsBySpace[modelData.id]?.notes ?? []) : []
            // KWin: "" | "rename" | "icon" | "remove" (asking first).
            property string managing: ""
            readonly property var ownWindows: Spaces.byActivity ? Spaces.ownWindows(modelData.activity) : []
            readonly property var neighbour: {
                const i = card.index;
                return Spaces.spaces[i + 1] ?? Spaces.spaces[i - 1] ?? null;
            }
            readonly property var rulesNaming: Spaces.byActivity ? Object.entries(WindowRules.rules ?? {}).filter(([a, r]) => Spaces.sameName(r["open-on-activity"], card.modelData.name)).map(([a]) => a) : []
            function rename(t) {
                const name = t.trim();
                card.managing = "";
                if (name !== "" && name !== card.modelData.name)
                    Spaces.editActivity({ op: "rename", activity: card.modelData.activity, name: name });
            }
            // Close Apps…: "" | "asking" (KWin's dry run) | "confirm".
            property string closing: ""
            property var closeWindows: []
            Connections {
                target: Spaces
                function onCloseReport(r) {
                    if (r.space !== card.modelData.id)
                        return;
                    if (r.dryRun && card.closing === "asking") {
                        card.closeWindows = r.windows ?? [];
                        card.closing = "confirm";
                    } else if (!r.dryRun) {
                        card.closing = "";
                    }
                }
            }
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

                // Move up / down in ⌘N order (KWin: the Activities' keys move).
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
                                enabled: arrowIcon.can && !Spaces.writing && !Spaces.activityBusy
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
                    // KWin: click for the Activity's KDE icon.
                    MouseArea {
                        anchors.fill: parent
                        enabled: Spaces.byActivity
                        cursorShape: Qt.PointingHandCursor
                        onClicked: card.managing = card.managing === "icon" ? "" : "icon"
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1

                    RowLayout {
                        spacing: 8
                        Text {
                            visible: card.managing !== "rename"
                            text: card.modelData.name
                            color: nameHover.containsMouse ? Theme.accent : Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 14
                            font.weight: Font.DemiBold
                            // KWin: click to rename the Activity.
                            MouseArea {
                                id: nameHover
                                anchors.fill: parent
                                enabled: Spaces.byActivity
                                hoverEnabled: true
                                cursorShape: Qt.IBeamCursor
                                onClicked: card.managing = "rename"
                            }
                        }
                        SettingsTextField {
                            id: nameField
                            visible: card.managing === "rename"
                            implicitWidth: 200
                            text: card.modelData.name
                            onCommitted: t => card.rename(t)
                            onVisibleChanged: if (visible)
                                focusInput()
                            Keys.onEscapePressed: card.managing = ""
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
                        text: Spaces.byActivity ? [card.modelData.key ? card.modelData.key.replace("Meta+", "⌘") : "no KDE shortcut", card.modelData.linked ? `Loft settings: ${card.modelData.id}` : "no Loft settings"].join("  ·  ") : [card.modelData.position ? `⌘${card.modelData.position}` : "", card.modelData.template ? `from ${card.modelData.template}` : "", card.modelData.id, card.modelData.doc?.activity ? (/^[0-9a-f]{8}-[0-9a-f]{4}-/i.test(card.modelData.doc.activity) ? "also a KDE Activity under Plasma" : `also KDE Activity “${card.modelData.doc.activity}” under Plasma`) : ""].filter(s => s).join("  ·  ")
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }

                SettingsButton {
                    visible: !Spaces.byActivity || card.modelData.linked
                    text: card.editing ? "Done" : "Edit"
                    onClicked: page.selected = card.editing ? "" : card.modelData.id
                }
                // KWin, a plain Activity: give it Loft settings, new or one
                // of the library's that no Activity has yet.
                SettingsSelect {
                    visible: Spaces.byActivity && !card.modelData.linked
                    implicitWidth: 170
                    placeholder: "Add Loft Settings…"
                    current: null
                    enabled: !Spaces.writing
                    options: [{ value: "", label: "New settings" }].concat(Spaces.library.filter(d => !d.archived && !Spaces.all.some(x => x.linked && x.id === d.id)).map(d => ({ value: d.id, label: `Use “${d.name}”` })))
                    onActivated: v => {
                        const act = card.modelData.activity;
                        const done = r => {
                            if (r.ok)
                                page.selected = r.id ?? v;
                        };
                        if (v === "")
                            Spaces.linkNew(act, done);
                        else
                            Spaces.link(v, act, done);
                    }
                }
                SettingsButton {
                    visible: Spaces.canOpen && (!Spaces.byActivity || card.modelData.linked)
                    text: "Close Apps…"
                    enabled: card.closing === ""
                    onClicked: {
                        if (Spaces.byActivity) {
                            card.closing = "asking";
                            Spaces.close(card.modelData.id, true);
                        } else {
                            card.closeWindows = [];
                            card.closing = "confirm";
                        }
                    }
                }
                SettingsButton {
                    visible: Spaces.canOpen && (!Spaces.byActivity || card.modelData.linked)
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

            // KWin: the space is an Activity, on every display; rename,
            // re-icon or remove it here.
            RowLayout {
                Layout.fillWidth: true
                visible: Spaces.byActivity && !card.editing
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    readonly property int windows: Spaces.windowCount(card.modelData.id)
                    text: `KDE Activity · every display${card.isActive ? " · showing" : ""}${windows > 0 ? ` · ${windows} window${windows === 1 ? "" : "s"}` : ""}`
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
                SettingsButton {
                    text: "Rename"
                    enabled: !Spaces.activityBusy
                    onClicked: card.managing = card.managing === "rename" ? "" : "rename"
                }
                SettingsButton {
                    text: "Icon"
                    primary: card.managing === "icon"
                    enabled: !Spaces.activityBusy
                    onClicked: card.managing = card.managing === "icon" ? "" : "icon"
                }
                SettingsButton {
                    text: "Remove…"
                    enabled: !Spaces.activityBusy && Spaces.spaces.length > 1
                    onClicked: card.managing = card.managing === "remove" ? "" : "remove"
                }
            }

            // KWin: the Activity's KDE icon.
            ActivityIconPicker {
                Layout.fillWidth: true
                visible: Spaces.byActivity && card.managing === "icon"
                current: card.modelData.kdeIcon
                onPicked: icon => {
                    card.managing = "";
                    Spaces.editActivity({ op: "icon", activity: card.modelData.activity, icon: icon });
                }
            }

            // KWin: Remove…, after saying what happens.
            RowLayout {
                Layout.fillWidth: true
                visible: Spaces.byActivity && card.managing === "remove"
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    readonly property string to: card.neighbour ? `“${card.neighbour.name}”` : "another Activity"
                    readonly property int n: card.ownWindows.length
                    text: [`Remove the KDE Activity “${card.modelData.name}”?`, n > 0 ? `Its ${n} window${n === 1 ? "" : "s"} move${n === 1 ? "s" : ""} to ${to}${card.isActive ? ", and Loft switches there" : ""}.` : (card.isActive ? `Loft switches to ${to}.` : ""), card.modelData.linked ? `Its Loft settings (“${card.modelData.id}”) stay in your library; Add Loft Settings → Use gives them to another Activity.` : "", card.rulesNaming.length > 0 ? `Window rules opening on it (${card.rulesNaming.join(", ")}) wait for an Activity with that name.` : "", card.modelData.key ? `${card.modelData.key.replace("Meta+", "⌘")} becomes free for the next new Activity.` : "", "Plasma loses it too; this can't be undone."].filter(s => s).join(" ")
                    color: Theme.warn
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
                SettingsButton {
                    text: "Cancel"
                    onClicked: card.managing = ""
                }
                SettingsButton {
                    text: "Remove"
                    primary: true
                    enabled: !Spaces.activityBusy
                    onClicked: {
                        card.managing = "";
                        Spaces.editActivity({ op: "remove", activity: card.modelData.activity });
                    }
                }
            }

            // Close Apps… confirmation.
            RowLayout {
                Layout.fillWidth: true
                visible: card.closing === "confirm"
                spacing: 8
                Text {
                    Layout.fillWidth: true
                    readonly property var names: [...new Set(card.closeWindows.map(w => w.title || w.app))]
                    text: Spaces.byActivity ? (card.closeWindows.length === 0 ? `None of “${card.modelData.name}”'s apps has a window open in this Activity.` : `Close ${card.closeWindows.length} window${card.closeWindows.length === 1 ? "" : "s"} of “${card.modelData.name}”: ${names.join(", ")}? Apps with unsaved changes ask first. The KDE Activity and its other windows stay.`) : `Close the windows “${card.modelData.name}” opened or claimed? Apps with unsaved changes ask first; its other windows stay.`
                    color: Theme.warn
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                }
                SettingsButton {
                    text: "Cancel"
                    onClicked: card.closing = ""
                }
                SettingsButton {
                    visible: !Spaces.byActivity || card.closeWindows.length > 0
                    text: "Close"
                    primary: true
                    onClicked: {
                        Spaces.close(card.modelData.id, false);
                        card.closing = "";
                    }
                }
            }

            // KWin, a linked Activity: one line per display role, role →
            // its apps → the display it is on now.
            Repeater {
                model: card.editing ? [] : card.appLines
                delegate: RowLayout {
                    id: appLine
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        Layout.preferredWidth: 70
                        text: appLine.modelData.role
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.weight: Font.Medium
                    }
                    Text {
                        Layout.preferredWidth: 150
                        text: appLine.modelData.apps
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        text: page.displayOf(appLine.modelData.display)
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }
            }
            Repeater {
                model: card.editing ? [] : card.appNotes
                delegate: Text {
                    required property var modelData
                    Layout.fillWidth: true
                    text: modelData
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    font.italic: true
                    wrapMode: Text.Wrap
                }
            }

            // One line per display role: role → workspace → where it is now.
            Repeater {
                model: card.editing || Spaces.byActivity ? [] : card.roles

                delegate: RowLayout {
                    id: line
                    required property var modelData
                    readonly property bool keep: modelData.workspace === "keep"
                    readonly property var ws: keep ? null : (Compositor.workspaces.find(w => w.name === modelData.workspace) ?? null)
                    readonly property int windows: ws ? Compositor.windowsOn(ws.id).length : 0
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

    // ── niri: settings made for KDE Activities ───────────────────────────
    SettingsCard {
        id: kdeCard
        visible: Spaces.kdeOnly.length > 0
        spacing: 6
        PageHeader {
            title: "Only for KDE Activities"
        }
        Text {
            Layout.fillWidth: true
            text: "Loft settings made for a KDE Activity in a Plasma session. They aren't Spaces here (no ⌘ number, not in the switcher); Plasma uses them for their Activity."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }
        Repeater {
            model: Spaces.kdeOnly
            delegate: RowLayout {
                id: kdeRow
                required property var modelData
                Layout.fillWidth: true
                spacing: 10
                IconBadge {
                    icon: kdeRow.modelData.icon || "󰕰"
                    badge: "gray"
                    size: 22
                }
                Text {
                    Layout.fillWidth: true
                    text: `${kdeRow.modelData.name}  ·  ${kdeRow.modelData.doc?.activity ? `Activity “${kdeRow.modelData.doc.activity}”` : "no Activity"}  ·  ${kdeRow.modelData.id}`
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                    elide: Text.ElideRight
                }
                // A niri Space too: on main, unless it binds displays already.
                SettingsButton {
                    text: "Use as a Space Here"
                    enabled: !Spaces.writing
                    onClicked: Spaces.patch(kdeRow.modelData.id, Object.keys(kdeRow.modelData.displays ?? {}).some(r => kdeRow.modelData.displays[r] !== "keep") ? { niri: true } : { niri: true, displays: { main: {} } })
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
