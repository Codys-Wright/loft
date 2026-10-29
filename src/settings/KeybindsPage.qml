import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.palette
import qs.services

// Settings → Keyboard Shortcuts (macOS's Keyboard Shortcuts pane): every
// niri bind of the session — Loft's, the theme's and the user's own niri
// config — grouped (Loft, Screenshots, Windows, Workspaces, …), searchable.
//
// Click a shortcut to record a new one (a key niri already uses has to be
// typed: niri runs it before the window sees it). A combination another
// shortcut has asks first and then takes it over (that one shows as
// replaced). The check box turns a shortcut off; ↺ restores one; custom
// shortcuts run a Quick Panel action, a command or a niri action.
//
// Changes go through loft-niri (crates/loft-niri/src/shortcuts.rs): stored
// in <state>/overrides/niri.json, rendered into overrides/niri.kdl (included
// last, so it wins over every other file), checked with `niri validate`
// first and rolled back if niri rejects it. Theme changes and home-manager
// switches don't touch them.
//
// The second tab: Apps to leave alone (services/Shortcuts.qml).
ColumnLayout {
    id: page
    spacing: 12

    property string tab: "shortcuts"
    property string query: ""
    // all | changed | off
    property string filter: "all"

    // The row being recorded (id), and a combination waiting for "Replace?".
    property string recordingId: ""
    property var pending: null
    property string lastError: ""
    property bool confirmRestore: false

    readonly property var rows: NiriSettings.shortcuts
    readonly property var categoryOrder: ["Custom", "Loft", "Screenshots", "Windows", "Workspaces", "Displays", "Apps", "Media & Hardware", "System", "Other"]

    function changed(r) {
        return ["moved", "disabled", "replaced", "custom", "custom-off"].includes(r.state);
    }

    function isOff(r) {
        return ["disabled", "replaced", "custom-off"].includes(r.state);
    }

    readonly property var filtered: rows.filter(r => {
        if (filter === "changed" && !changed(r))
            return false;
        if (filter === "off" && !isOff(r))
            return false;
        if (query === "")
            return true;
        const q = query.toLowerCase();
        return [r.label, r.action_text, r.combo ?? "", r.default_combo ?? "", r.category, comboText(r.modifiers, r.trigger)].some(s => String(s).toLowerCase().includes(q));
    })

    // [{ category, rows }] in categoryOrder.
    readonly property var groups: categoryOrder.map(c => ({
                category: c,
                rows: filtered.filter(r => r.category === c)
            })).filter(g => g.rows.length > 0)

    readonly property int changedCount: rows.filter(changed).length

    // ── Combos ───────────────────────────────────────────────────────────
    // loft-niri's normalization (binds.rs `normalize`): canonical modifier
    // names and order, single characters upper-cased. "" when invalid.
    function canon(text) {
        const parts = String(text).trim().split("+").map(p => p.trim());
        const trigger = parts.pop() ?? "";
        if (trigger === "" || /[\s{}";=]/.test(trigger))
            return "";
        const order = ["Mod", "Super", "Ctrl", "Alt", "Shift", "ISO_Level3_Shift", "ISO_Level5_Shift"];
        const alias = { mod: "Mod", super: "Super", win: "Super", cmd: "Super", ctrl: "Ctrl", control: "Ctrl", alt: "Alt", opt: "Alt", option: "Alt", shift: "Shift", iso_level3_shift: "ISO_Level3_Shift", mod5: "ISO_Level3_Shift", iso_level5_shift: "ISO_Level5_Shift", mod3: "ISO_Level5_Shift" };
        const mods = [];
        for (const p of parts) {
            const m = alias[p.toLowerCase()];
            if (!m)
                return "";
            if (!mods.includes(m))
                mods.push(m);
        }
        mods.sort((a, b) => order.indexOf(a) - order.indexOf(b));
        let t = trigger;
        if ([...t].length === 1)
            t = t.toUpperCase();
        else if (t === t.toLowerCase())
            t = t[0].toUpperCase() + t.slice(1);
        return mods.concat([t]).join("+");
    }

    // ⌥⌘T; words get a "+" (Mod+⌥T, ⌃⇧+Esc).
    function comboText(mods, trigger) {
        const caps = (mods ?? []).concat([trigger ?? ""]).map(k => recorderNames.keyCap(k));
        let out = "";
        for (let i = 0; i < caps.length; i++)
            out += (i > 0 && (caps[i].length > 1 || caps[i - 1].length > 1) ? "+" : "") + caps[i];
        return out;
    }

    function comboTextOf(combo) {
        const parts = String(combo ?? "").split("+");
        return comboText(parts.slice(0, -1), parts[parts.length - 1]);
    }

    // The active shortcut on a combination, other than `exceptId`.
    function ownerOf(combo, exceptId) {
        const k = combo.toLowerCase();
        return rows.find(r => r.id !== exceptId && r.combo && r.combo.toLowerCase() === k && ["default", "moved", "custom"].includes(r.state)) ?? null;
    }

    function rowById(id) {
        return rows.find(r => r.id === id) ?? null;
    }

    function originText(r) {
        switch (r.origin) {
        case "loft":
            return "Loft";
        case "theme":
            return "Theme";
        case "custom":
            return "Custom";
        }
        return `Your niri config · ${(r.file ?? "").replace(/^.*\//, "")}:${r.line}`;
    }

    // ── Changes ──────────────────────────────────────────────────────────
    function run(ops) {
        lastError = "";
        NiriSettings.bindOps(ops, res => {
            if (!res.ok)
                page.lastError = shortError(res.error ?? "loft-niri failed");
        });
    }

    // `niri validate`'s report, down to its point (the change was rolled back).
    function shortError(e) {
        const key = /invalid key: ([^\n]+)/.exec(e);
        if (key)
            return `niri doesn't know the key “${key[1].trim()}” — nothing was changed.`;
        if (!e.startsWith("niri rejected"))
            return e;
        const points = e.split("\n").filter(l => l.includes("×")).map(l => l.replace(/^.*×\s*/, "").trim());
        return `niri rejected it (${points[points.length - 1] ?? "invalid config"}) — nothing was changed.`;
    }

    function startRecording(id) {
        pending = null;
        recordingId = id;
    }

    // A combination for row `id` (recorded or typed).
    function propose(id, combo) {
        recordingId = "";
        const c = canon(combo);
        const r = rowById(id);
        if (c === "" || !r) {
            lastError = `“${combo}” isn't a shortcut niri understands (e.g. Mod+Shift+T, Super+F5)`;
            return;
        }
        if (r.combo && r.combo.toLowerCase() === c.toLowerCase() && r.state !== "disabled")
            return;
        const owner = ownerOf(c, id);
        if (owner)
            pending = { id: id, combo: c, owner: owner };
        else
            run([{ op: "set", id: id, combo: c }]);
    }

    function confirmPending() {
        const p = pending;
        pending = null;
        if (p?.id === "new")
            addCustom(p.combo, true);
        else if (p)
            run([{ op: "set", id: p.id, combo: p.combo }]);
    }

    // ── Adding ───────────────────────────────────────────────────────────
    property bool adding: false
    // loft | command | niri
    property string addKind: "loft"
    property string addLoft: ""
    property string addCommand: ""
    property string addNiri: "toggle-overview"
    property string addNiriArg: ""
    property string addTitle: ""
    property string addCombo: ""

    readonly property var niriActions: [
        { value: "toggle-overview", label: "Overview" },
        { value: "close-window", label: "Close window" },
        { value: "fullscreen-window", label: "Full screen" },
        { value: "toggle-windowed-fullscreen", label: "Windowed full screen" },
        { value: "maximize-column", label: "Maximize column" },
        { value: "center-column", label: "Center column" },
        { value: "toggle-window-floating", label: "Float / tile window" },
        { value: "switch-focus-between-floating-and-tiling", label: "Focus floating / tiled" },
        { value: "switch-preset-column-width", label: "Next column width" },
        { value: "set-column-width", label: "Set column width…", arg: "50%" },
        { value: "consume-or-expel-window-left", label: "Join / split column (left)" },
        { value: "toggle-column-tabbed-display", label: "Tabbed column" },
        { value: "focus-column-left", label: "Focus column left" },
        { value: "focus-column-right", label: "Focus column right" },
        { value: "move-column-left", label: "Move column left" },
        { value: "move-column-right", label: "Move column right" },
        { value: "focus-workspace", label: "Focus workspace…", arg: "1" },
        { value: "move-column-to-workspace", label: "Move column to workspace…", arg: "1" },
        { value: "focus-workspace-previous", label: "Previous workspace" },
        { value: "focus-monitor-next", label: "Focus next display" },
        { value: "move-window-to-monitor-next", label: "Move window to next display" },
        { value: "screenshot", label: "niri screenshot (interactive)" },
        { value: "screenshot-screen", label: "niri screenshot screen" },
        { value: "power-off-monitors", label: "Turn displays off" },
        { value: "show-hotkey-overlay", label: "niri's hotkey overlay" }
    ]

    function addRecord() {
        switch (addKind) {
        case "loft":
            return addLoft === "" ? null : Shortcuts.actionRecord(addLoft, addTitle || Actions.label(addLoft));
        case "command":
            return addCommand.trim() === "" ? null : { action: "spawn-sh", args: [addCommand.trim()], title: addTitle || addCommand.trim() };
        case "niri":
            {
                const a = niriActions.find(x => x.value === addNiri);
                if (!a)
                    return null;
                const r = { action: addNiri, title: addTitle || a.label.replace(/…$/, "") };
                if (a.arg !== undefined) {
                    const v = addNiriArg.trim() || a.arg;
                    r.args = [/^-?\d+$/.test(v) ? parseInt(v) : v];
                }
                return r;
            }
        }
        return null;
    }

    function addCustom(combo, confirmed) {
        const c = canon(combo);
        const record = addRecord();
        if (c === "" || !record) {
            lastError = c === "" ? "Record or type a shortcut first" : "Pick what the shortcut does";
            return;
        }
        if (!confirmed) {
            const owner = ownerOf(c, "");
            if (owner) {
                pending = { id: "new", combo: c, owner: owner };
                return;
            }
        }
        run([{ op: "add", combo: c, record: record }]);
        adding = false;
        addLoft = "";
        addCommand = "";
        addTitle = "";
        addCombo = "";
    }

    // The recorder's key-cap names (one hidden instance, for comboText).
    ShortcutRecorder {
        id: recorderNames
        visible: false
    }

    // ── Tabs ─────────────────────────────────────────────────────────────
    SettingsSegmented {
        Layout.alignment: Qt.AlignHCenter
        options: [{ value: "shortcuts", label: "Shortcuts" }, { value: "leaveAlone", label: "Apps to Leave Alone" }]
        current: page.tab
        onActivated: v => {
            page.tab = v;
            page.recordingId = "";
        }
    }

    // ── Search, filter, add, restore ─────────────────────────────────────
    SettingsCard {
        visible: page.tab === "shortcuts"

        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Icon {
                text: "󰍉"
                size: 14
                color: Theme.subtext
            }
            SettingsTextField {
                Layout.fillWidth: true
                placeholder: "Search shortcuts, keys, actions"
                onEdited: t => page.query = t.trim()
            }
            SettingsSegmented {
                options: [{ value: "all", label: "All" }, { value: "changed", label: `Changed (${page.changedCount})` }, { value: "off", label: "Off" }]
                current: page.filter
                onActivated: v => page.filter = v
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Text {
                Layout.fillWidth: true
                text: `${page.rows.length} shortcuts · click one to change it. Changes are checked with niri validate and win over every niri file, your Nix config included.`
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }
            SettingsButton {
                text: "Add Shortcut…"
                icon: "󰐕"
                onClicked: {
                    page.adding = !page.adding;
                    page.recordingId = "";
                    page.pending = null;
                }
            }
            SettingsButton {
                text: "Restore Defaults"
                enabled: page.changedCount > 0
                onClicked: page.confirmRestore = true
            }
        }

        // Restore all?
        RowLayout {
            Layout.fillWidth: true
            visible: page.confirmRestore
            spacing: 8
            Text {
                Layout.fillWidth: true
                text: `Restore all ${page.changedCount} changed shortcuts? Custom shortcuts are removed.`
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
                    page.run([{ op: "reset_all" }]);
                }
            }
        }

        // Errors: ours (validation) and the config tree's.
        Repeater {
            model: (page.lastError ? [page.lastError] : []).concat(NiriSettings.bindsData.errors ?? [])
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

    // ── Add a custom shortcut ────────────────────────────────────────────
    SettingsCard {
        visible: page.tab === "shortcuts" && page.adding

        PageHeader {
            title: "New shortcut"
            SettingsButton {
                text: "Cancel"
                onClicked: page.adding = false
            }
            SettingsButton {
                text: "Add"
                primary: true
                onClicked: page.addCustom(page.addCombo, false)
            }
        }

        SettingsRow {
            label: "Shortcut"
            hint: "Click and press it, or type it (Mod+Ctrl+X)"
            RowLayout {
                spacing: 8
                ShortcutRecorder {
                    readonly property string c: page.canon(page.addCombo)
                    modifiers: c ? c.split("+").slice(0, -1) : []
                    trigger: c ? c.split("+").pop() : ""
                    placeholder: "Record"
                    recording: page.recordingId === "new"
                    onStartRequested: page.startRecording("new")
                    onCaptured: combo => {
                        page.recordingId = "";
                        page.addCombo = combo;
                    }
                    onCanceled: if (page.recordingId === "new")
                        page.recordingId = ""
                    onCleared: {
                        page.recordingId = "";
                        page.addCombo = "";
                    }
                }
                SettingsTextField {
                    implicitWidth: 150
                    placeholder: "or type it"
                    onCommitted: t => page.addCombo = t.trim()
                }
            }
        }

        SettingsRow {
            label: "Does"
            SettingsSegmented {
                options: [{ value: "loft", label: "Loft action" }, { value: "command", label: "Command" }, { value: "niri", label: "niri action" }]
                current: page.addKind
                onActivated: v => page.addKind = v
            }
        }

        // Loft action: the Quick Panel catalog.
        Text {
            Layout.fillWidth: true
            visible: page.addKind === "loft"
            text: page.addLoft ? `${Actions.label(page.addLoft)} — ${Actions.entry(page.addLoft)?.group ?? ""}` : "Pick an action below"
            color: page.addLoft ? Theme.text : Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 12
            font.weight: Font.Medium
        }
        ActionPicker {
            Layout.fillWidth: true
            visible: page.addKind === "loft"
            exclude: page.addLoft ? [page.addLoft] : []
            onPicked: id => page.addLoft = id
            onCanceled: page.adding = false
        }

        SettingsRow {
            visible: page.addKind === "command"
            label: "Command"
            hint: "Run with sh -c"
            SettingsTextField {
                implicitWidth: 320
                placeholder: "e.g. kitty -e htop"
                onEdited: t => page.addCommand = t
            }
        }

        SettingsRow {
            visible: page.addKind === "niri"
            label: "niri action"
            RowLayout {
                spacing: 8
                SettingsSelect {
                    implicitWidth: 240
                    options: page.niriActions
                    current: page.addNiri
                    onActivated: v => page.addNiri = v
                }
                SettingsTextField {
                    visible: page.niriActions.find(a => a.value === page.addNiri)?.arg !== undefined
                    implicitWidth: 90
                    placeholder: page.niriActions.find(a => a.value === page.addNiri)?.arg ?? ""
                    onEdited: t => page.addNiriArg = t
                }
            }
        }

        SettingsRow {
            label: "Name"
            hint: "Shown here and in niri's hotkey overlay"
            SettingsTextField {
                implicitWidth: 240
                placeholder: page.addKind === "loft" && page.addLoft ? Actions.label(page.addLoft) : "optional"
                onEdited: t => page.addTitle = t
            }
        }

        // The new combination is taken.
        ConflictBar {
            visible: page.pending?.id === "new"
        }
    }

    // ── The groups ───────────────────────────────────────────────────────
    Repeater {
        model: page.tab === "shortcuts" ? page.groups : []

        delegate: SettingsCard {
            id: group
            required property var modelData
            spacing: 2

            PageHeader {
                title: group.modelData.category
                Text {
                    text: `${group.modelData.rows.length}`
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                }
            }

            Repeater {
                model: group.modelData.rows

                delegate: ColumnLayout {
                    id: row
                    required property var modelData
                    readonly property var r: modelData
                    readonly property bool off: page.isOff(r)
                    Layout.fillWidth: true
                    spacing: 4

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: line.implicitHeight + 10
                        radius: 8
                        color: rowHover.hovered ? Theme.withAlpha(Theme.text, 0.05) : "transparent"

                        HoverHandler {
                            id: rowHover
                        }

                        RowLayout {
                            id: line
                            anchors {
                                left: parent.left
                                right: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 6
                                rightMargin: 6
                            }
                            spacing: 10

                            // On / off
                            Rectangle {
                                implicitWidth: 16
                                implicitHeight: 16
                                radius: 4
                                color: row.off ? "transparent" : Theme.accent
                                border.width: row.off ? 1.5 : 0
                                border.color: Theme.withAlpha(Theme.text, 0.35)
                                opacity: row.r.state === "replaced" ? 0.4 : 1
                                Text {
                                    anchors.centerIn: parent
                                    visible: !row.off
                                    text: "✓"
                                    color: Theme.bg
                                    font.pixelSize: 11
                                    font.weight: Font.Bold
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    enabled: row.r.state !== "replaced"
                                    onClicked: page.run([{ op: row.off ? "enable" : "disable", id: row.r.id }])
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1

                                Text {
                                    Layout.fillWidth: true
                                    text: row.r.label
                                    color: row.off ? Theme.subtext : Theme.text
                                    font.family: Theme.fontUi
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                    elide: Text.ElideRight
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: {
                                        const r = row.r;
                                        const notes = [page.originText(r)];
                                        if (r.state === "moved")
                                            notes.push(`was ${page.comboTextOf(r.default_combo)}${page.ownerOf(r.default_combo, r.id) ? "" : " (now off)"}`);
                                        if (r.state === "disabled")
                                            notes.push("off — the key does nothing");
                                        if (r.state === "replaced")
                                            notes.push(`replaced by “${page.rowById(r.replaced_by)?.label ?? r.replaced_by}”`);
                                        if ((r.also_defined ?? []).length > 0)
                                            notes.push(`also in ${r.also_defined.map(f => f.replace(/^.*\//, "")).join(", ")}`);
                                        if (r.loft)
                                            notes.push(`runs “${Actions.label(r.loft)}”`);
                                        else if (r.titled)
                                            notes.push(r.detail);
                                        return notes.join("  ·  ");
                                    }
                                    color: row.r.state === "replaced" || row.r.state === "disabled" ? Theme.warn : Theme.subtext
                                    font.family: Theme.fontUi
                                    font.pixelSize: 10
                                    elide: Text.ElideRight
                                }
                            }

                            ShortcutRecorder {
                                Layout.preferredWidth: 128
                                modifiers: row.r.modifiers
                                trigger: row.r.combo ? row.r.trigger : ""
                                dim: row.off
                                recording: page.recordingId === row.r.id
                                onStartRequested: page.startRecording(row.r.id)
                                onCaptured: combo => page.propose(row.r.id, combo)
                                onCleared: {
                                    page.recordingId = "";
                                    page.run([{ op: "disable", id: row.r.id }]);
                                }
                                onCanceled: if (page.recordingId === row.r.id)
                                    page.recordingId = ""
                            }

                            // Restore (changed defaults) / delete (custom).
                            Rectangle {
                                implicitWidth: 22
                                implicitHeight: 22
                                radius: 11
                                opacity: page.changed(row.r) ? 1 : 0
                                color: resetHover.containsMouse ? Theme.withAlpha(Theme.text, 0.14) : "transparent"
                                Icon {
                                    anchors.centerIn: parent
                                    text: row.r.id.startsWith("c:") ? "󰅖" : "󰑓"
                                    size: 12
                                    color: Theme.subtext
                                }
                                MouseArea {
                                    id: resetHover
                                    anchors.fill: parent
                                    enabled: page.changed(row.r)
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: page.run([{ op: "reset", id: row.r.id }])
                                }
                            }
                        }
                    }

                    // While recording: niri runs the combinations it has before
                    // this window sees them, so those can be typed.
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.leftMargin: 32
                        visible: page.recordingId === row.r.id
                        spacing: 8
                        Text {
                            text: "Or type it:"
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                        }
                        SettingsTextField {
                            id: typeField
                            Layout.fillWidth: true
                            placeholder: "e.g. Mod+Shift+T — keys niri already uses never reach this window"
                            onCommitted: t => {
                                if (t.trim() !== "")
                                    page.propose(row.r.id, t);
                                typeField.clear();
                            }
                        }
                    }

                    ConflictBar {
                        visible: page.pending?.id === row.r.id
                    }
                }
            }
        }
    }

    Text {
        Layout.fillWidth: true
        Layout.topMargin: 20
        visible: page.tab === "shortcuts" && page.groups.length === 0
        horizontalAlignment: Text.AlignHCenter
        text: page.rows.length === 0 ? "No shortcuts found — is the niri config readable?" : "No shortcuts match."
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 13
    }

    // "⌥⌘T is used by “Themes”. Replace?"
    component ConflictBar: Rectangle {
        Layout.fillWidth: true
        implicitHeight: conflictRow.implicitHeight + 14
        radius: 8
        color: Theme.withAlpha(Theme.warn, 0.12)
        border.width: 1
        border.color: Theme.withAlpha(Theme.warn, 0.35)

        RowLayout {
            id: conflictRow
            anchors {
                left: parent.left
                right: parent.right
                verticalCenter: parent.verticalCenter
                leftMargin: 12
                rightMargin: 8
            }
            spacing: 8
            Text {
                Layout.fillWidth: true
                text: page.pending ? `${page.comboTextOf(page.pending.combo)} is already used by “${page.pending.owner.label}” (${page.originText(page.pending.owner)}). Replace it? That one is switched off until you restore it.` : ""
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }
            SettingsButton {
                text: "Cancel"
                onClicked: page.pending = null
            }
            SettingsButton {
                text: "Replace"
                primary: true
                onClicked: page.confirmPending()
            }
        }
    }

    // ── Apps to leave alone ──────────────────────────────────────────────
    SettingsCard {
        visible: page.tab === "leaveAlone"

        PageHeader {
            title: "Apps to leave alone"
        }
        Text {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: "Games, virtual machines and remote desktops want the keyboard to themselves. While one of these apps is focused, Loft's remaps and window shortcuts stay out of the way."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 12
        }

        AppIdList {
            apps: Array.from(Shortcuts.leaveAlone)
            emptyText: "No apps — add a running game, VM viewer (virt-manager, GNOME Boxes) or remote desktop (Remmina, FreeRDP)"
            onChanged: l => Shortcuts.setLeaveAlone(l)
        }

        SettingsRow {
            label: "Pause Loft's window shortcuts in them"
            hint: "They do nothing while one of these apps is focused"
            SettingsSwitch {
                checked: Shortcuts.pauseShellShortcuts
                onToggled: on => Shortcuts.setPause(on)
            }
        }
        Text {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: "⌘Q (close, or hold to quit), Paste as Plain Text, Snippets, the Quick Panel, the Radial Menu, Arrange, and custom shortcuts' window and text actions. Spotlight, screenshots, the Control Center, Settings and the lock screen keep working."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }

        SettingsRow {
            readonly property bool wired: Shortcuts.xremapStatus !== "" && !Shortcuts.xremapStatus.startsWith("loft")
            label: "Keyboard remaps (xremap)"
            hint: wired ? `Following this list — ${Shortcuts.xremapStatus.replace(/^.*: /, "")}` : "xremap isn't running Loft's keymap"
        }
        Text {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: "Loft's keyboard layer (the macOS keys, Caps Lock / Esc as Mod, the symbol layer) is switched off in these apps. It runs as xremap on the config Loft renders (programs.loft.keyboard, loft-keys.service); `loft keys show` lists its groups, and `loft keys app <app id>` fixes one app's keys without turning everything off."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }

        Text {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: "niri itself still runs its own bindings in these apps (it can't hand a key to one app and not another). Apps that grab the keyboard — VM viewers and remote desktops usually do while focused (keyboard-shortcuts-inhibit) — get every key, niri's included, until they let go."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
    }
}
