import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services
import qs.settings

// Utilities → Cleaner: reclaimable space (services/Cleaner.qml →
// `loft clean …`). Caches you pick are cleared after a confirm; messaging
// downloads past their retention go to the Trash; a weekly (etc.) systemd
// *user* timer can prune old cache files. The Nix store is only measured
// (a --print-dead dry run) — collecting garbage is a command you run
// yourself, with sudo for the system's generations.
ColumnLayout {
    id: page
    spacing: 12

    readonly property var s: Cleaner.scan
    readonly property var groups: ["Browsers", "Apps", "Developer", "Thumbnails", "System", "Loft", "Trash", "Keep"]
    readonly property var sched: s?.schedule ?? null
    readonly property string home: s?.home ?? Quickshell.env("HOME")

    function tilde(p) {
        return p && p.startsWith(home) ? "~" + p.slice(home.length) : p;
    }
    function date(t) {
        return t ? Qt.formatDate(new Date(t * 1000), "MMM d, yyyy") : "—";
    }

    component Sub: Text {
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
    }

    component Check: Rectangle {
        id: ck
        property bool checked
        signal toggled
        implicitWidth: 16
        implicitHeight: 16
        radius: 4
        color: checked ? Theme.accent : "transparent"
        border.width: checked ? 0 : 1
        border.color: Theme.withAlpha(Theme.text, 0.35)
        opacity: enabled ? 1 : 0.35
        Icon {
            anchors.centerIn: parent
            visible: ck.checked
            text: "󰄬"
            size: 11
            color: Theme.bg
        }
        MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.PointingHandCursor
            onClicked: ck.toggled()
        }
    }

    // Test runs point LOFT_TEST_HOME at a scratch tree: say so loudly.
    Rectangle {
        Layout.fillWidth: true
        visible: page.s?.testHome === true
        implicitHeight: 30
        radius: 8
        color: Theme.withAlpha(Theme.warn, 0.18)
        Text {
            anchors.centerIn: parent
            width: parent.width - 24
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideMiddle
            text: `Test home (LOFT_TEST_HOME): ${page.home}`
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
    }

    // ── At a glance ──────────────────────────────────────────────────────
    RowLayout {
        Layout.fillWidth: true
        spacing: 10

        Repeater {
            model: [
                {
                    icon: "󰃢",
                    badge: "orange",
                    title: "Caches & Trash",
                    value: Cleaner.formatBytes(page.s?.cacheBytes),
                    caption: page.s ? `${Cleaner.caches.filter(c => c.bytes > 0).length} locations` : "scanning…"
                },
                {
                    icon: "󱄅",
                    badge: "blue",
                    title: "Nix store garbage",
                    value: page.s?.store ? Cleaner.formatBytes(page.s.store.deadBytes) : "—",
                    caption: Cleaner.storeScanning ? Cleaner.storeStage : page.s?.store ? `${page.s.store.deadPaths.toLocaleString(Qt.locale(), "f", 0)} dead paths · ${Updates.ago(page.s.store.checkedAt)}` : "not measured yet"
                },
                {
                    icon: "󰋚",
                    badge: "purple",
                    title: "Old generations",
                    value: page.s ? String((page.s.generations ?? []).reduce((a, g) => a + g.older, 0)) : "—",
                    caption: page.s ? (page.s.generations ?? []).map(g => `${g.older} ${g.id}`).join(" · ") : ""
                }
            ]
            delegate: GlassSurface {
                required property var modelData
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                implicitHeight: 86
                radius: 16
                strength: 0.9
                showHighlight: false
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 12
                    spacing: 2
                    RowLayout {
                        spacing: 8
                        IconBadge {
                            icon: modelData.icon
                            badge: modelData.badge
                            size: 22
                        }
                        Text {
                            text: modelData.title
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                        }
                    }
                    Text {
                        text: modelData.value
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 22
                        font.weight: Font.Light
                    }
                    Sub {
                        Layout.fillWidth: true
                        text: modelData.caption
                        font.pixelSize: 10
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }

    Text {
        Layout.fillWidth: true
        visible: Cleaner.notice !== ""
        text: Cleaner.notice
        color: Theme.ok
        font.family: Theme.fontUi
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }

    // ── Caches ───────────────────────────────────────────────────────────
    SettingsCard {
        spacing: 2

        PageHeader {
            title: "Caches"
            SettingsButton {
                primary: Cleaner.selectedIds.length > 0
                enabled: Cleaner.selectedIds.length > 0 && !Cleaner.clearing
                text: Cleaner.selectedIds.length > 0 ? `Clear ${Cleaner.selectedIds.length} (${Cleaner.formatBytes(Cleaner.selectedBytes)})…` : "Clear Selected…"
                onClicked: Cleaner.askClear(Cleaner.selectedIds, Cleaner.selectedIds.length === 1 ? (Cleaner.caches.find(c => c.id === Cleaner.selectedIds[0])?.label ?? "1 cache") : `${Cleaner.selectedIds.length} caches`, Cleaner.selectedBytes)
            }
        }

        Sub {
            visible: Cleaner.scanning && !page.s
            text: "Measuring…"
        }

        Repeater {
            model: page.groups.filter(g => Cleaner.caches.some(c => c.group === g))
            delegate: ColumnLayout {
                id: grp
                required property string modelData
                readonly property var rows: Cleaner.caches.filter(c => c.group === modelData)
                readonly property bool keep: modelData === "Keep"
                readonly property bool allOn: rows.every(r => Cleaner.selected[r.id])
                Layout.fillWidth: true
                Layout.topMargin: 6
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 8
                    Layout.rightMargin: 10
                    spacing: 10
                    Check {
                        enabled: !grp.keep
                        checked: !grp.keep && grp.allOn
                        onToggled: Cleaner.selectGroup(grp.modelData, !grp.allOn)
                    }
                    Text {
                        Layout.fillWidth: true
                        text: grp.keep ? "Kept (clear these from their apps)" : grp.modelData
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 10
                        font.capitalization: Font.AllUppercase
                        font.letterSpacing: 0.4
                    }
                    Sub {
                        text: Cleaner.formatBytes(grp.rows.reduce((a, r) => a + r.bytes, 0))
                    }
                }

                Repeater {
                    model: grp.rows
                    delegate: Rectangle {
                        id: crow
                        required property var modelData
                        Layout.fillWidth: true
                        implicitHeight: 30
                        radius: 8
                        color: ch.hovered ? Theme.withAlpha(Theme.text, 0.07) : "transparent"
                        opacity: grp.keep ? 0.6 : 1
                        HoverHandler {
                            id: ch
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: !grp.keep
                            onClicked: Cleaner.toggle(crow.modelData.id)
                        }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 8
                            anchors.rightMargin: 10
                            spacing: 10
                            Check {
                                enabled: !grp.keep
                                checked: Cleaner.selected[crow.modelData.id] === true
                                onToggled: Cleaner.toggle(crow.modelData.id)
                            }
                            Text {
                                Layout.preferredWidth: 220
                                text: crow.modelData.label
                                color: Theme.text
                                font.family: Theme.fontUi
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                            Sub {
                                Layout.fillWidth: true
                                text: page.tilde(crow.modelData.path) + (crow.modelData.kind === "trash" ? ` · ${crow.modelData.files} item${crow.modelData.files === 1 ? "" : "s"}` : "")
                                font.pixelSize: 10
                                elide: Text.ElideMiddle
                            }
                            Text {
                                Layout.preferredWidth: 70
                                horizontalAlignment: Text.AlignRight
                                text: Cleaner.formatBytes(crow.modelData.bytes)
                                color: crow.modelData.bytes > 1e9 ? Theme.warn : Theme.text
                                font.family: Theme.fontUi
                                font.pixelSize: 12
                                font.features: {
                                    "tnum": 1
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ── Nix store ────────────────────────────────────────────────────────
    SettingsCard {
        spacing: 6

        PageHeader {
            title: "Nix store & generations"
            SettingsButton {
                text: Cleaner.storeScanning ? "Measuring…" : page.s?.store ? "Measure Again" : "Measure Garbage"
                enabled: !Cleaner.storeScanning
                onClicked: Cleaner.scanStore()
            }
        }

        Sub {
            Layout.fillWidth: true
            text: Cleaner.storeScanning ? `${Cleaner.storeStage} — takes a few minutes; nothing is deleted.` : page.s?.store ? `${Cleaner.formatBytes(page.s.store.deadBytes)} in ${page.s.store.deadPaths.toLocaleString(Qt.locale(), "f", 0)} store paths nothing uses any more — freed by any garbage collection. Measured ${Updates.ago(page.s.store.checkedAt)} in ${Math.round(page.s.store.seconds)} s.` : "Measuring lists what garbage collection would free (nix-store --gc --print-dead, a dry run) and what only older generations keep alive."
            wrapMode: Text.Wrap
        }

        Repeater {
            model: page.s?.generations ?? []
            delegate: RowLayout {
                required property var modelData
                readonly property var held: page.s?.store?.heldByOlderGenerations?.[modelData.id] ?? null
                Layout.fillWidth: true
                Layout.leftMargin: 4
                spacing: 10
                IconBadge {
                    icon: modelData.id === "system" ? "󱄅" : modelData.id === "home-manager" ? "󰋜" : "󰀄"
                    badge: modelData.id === "system" ? "blue" : modelData.id === "home-manager" ? "teal" : "indigo"
                    size: 22
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                        text: modelData.label
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                    }
                    Sub {
                        Layout.fillWidth: true
                        text: `${modelData.count} generation${modelData.count === 1 ? "" : "s"} · current #${modelData.current} · oldest ${page.date(modelData.oldest)}` + (modelData.needsRoot ? " · removing needs sudo" : "")
                        font.pixelSize: 10
                        elide: Text.ElideRight
                    }
                }
                Text {
                    text: held ? `${Cleaner.formatBytes(held.bytes)} held` : `${modelData.older} older`
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                }
            }
        }

        Text {
            Layout.topMargin: 6
            text: "Run yourself"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 10
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 0.4
        }
        Repeater {
            model: page.s?.commands ?? []
            delegate: Rectangle {
                required property var modelData
                Layout.fillWidth: true
                implicitHeight: 40
                radius: 8
                color: Theme.withAlpha(Theme.text, 0.05)
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 8
                    spacing: 8
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Text {
                            Layout.fillWidth: true
                            text: modelData.command
                            color: modelData.sudo ? Theme.warn : Theme.text
                            font.family: "monospace"
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                        Sub {
                            Layout.fillWidth: true
                            text: modelData.label
                            font.pixelSize: 10
                            elide: Text.ElideRight
                        }
                    }
                    SettingsButton {
                        icon: "󰆏"
                        text: "Copy"
                        onClicked: Cleaner.copy(modelData.command)
                    }
                }
            }
        }
    }

    // ── Messaging downloads ──────────────────────────────────────────────
    SettingsCard {
        spacing: 6

        PageHeader {
            title: "Messaging downloads"
        }
        Sub {
            Layout.fillWidth: true
            text: "Files older than the limit move to the Trash (on demand, or with the schedule below)."
            wrapMode: Text.Wrap
        }

        Repeater {
            model: page.s?.retention ?? []
            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 10
                Icon {
                    text: "󰉍"
                    size: 15
                    color: Theme.accent
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                        Layout.fillWidth: true
                        text: modelData.path
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        elide: Text.ElideMiddle
                    }
                    Sub {
                        text: !modelData.exists ? "folder not found" : `${modelData.files} of ${modelData.totalFiles} files older than ${modelData.days} days · ${Cleaner.formatBytes(modelData.bytes)}`
                        font.pixelSize: 10
                    }
                }
                SettingsSelect {
                    options: [7, 14, 30, 60, 90, 180].map(d => ({
                                value: d,
                                label: `${d} days`
                            }))
                    current: modelData.days
                    onActivated: v => Cleaner.setRetention(modelData.path, v)
                }
                SettingsButton {
                    text: "Trash Now"
                    enabled: modelData.files > 0
                    onClicked: Cleaner.askClear([modelData.id], `${modelData.files} old file${modelData.files === 1 ? "" : "s"} in ${modelData.path}`, modelData.bytes, true)
                }
                SettingsButton {
                    icon: "󰅖"
                    text: ""
                    onClicked: Cleaner.removeRetention(modelData.path)
                }
            }
        }

        Flow {
            Layout.fillWidth: true
            spacing: 6
            visible: (page.s?.suggestedRetention ?? []).length > 0
            Repeater {
                model: page.s?.suggestedRetention ?? []
                delegate: SettingsButton {
                    required property string modelData
                    icon: "󰐕"
                    text: `${modelData} · 30 days`
                    onClicked: Cleaner.setRetention(modelData, 30)
                }
            }
        }
        Sub {
            visible: (page.s?.retention ?? []).length === 0 && (page.s?.suggestedRetention ?? []).length === 0
            text: "No messaging download folders found (Telegram Desktop, WhatsApp, Signal, Discord under ~/Downloads)."
            font.pixelSize: 10
        }
    }

    // ── Schedule ─────────────────────────────────────────────────────────
    SettingsCard {
        id: schedCard
        spacing: 6

        readonly property var cur: page.sched ?? {
            every: "weekly",
            olderThanDays: 30,
            categories: ["group:Thumbnails", "group:Browsers"],
            trashDays: 30,
            retention: true
        }
        function apply(patch) {
            Cleaner.setSchedule(Object.assign({}, cur, patch));
        }

        SettingsRow {
            label: "Clean up automatically"
            hint: page.sched ? `systemd user timer (loft-cleaner.timer), ${page.sched.every}` : "Prunes old files in the caches you pick — never the Nix store"
            SettingsSwitch {
                checked: page.sched !== null
                onToggled: on => Cleaner.setSchedule(on ? schedCard.cur : null)
            }
        }
        SettingsRow {
            visible: page.sched !== null
            label: "How often"
            SettingsSegmented {
                options: [
                    {
                        value: "daily",
                        label: "Daily"
                    },
                    {
                        value: "weekly",
                        label: "Weekly"
                    },
                    {
                        value: "monthly",
                        label: "Monthly"
                    }
                ]
                current: schedCard.cur.every
                onActivated: v => schedCard.apply({
                        every: v
                    })
            }
        }
        SettingsRow {
            visible: page.sched !== null
            label: "Delete cache files older than"
            SettingsSelect {
                options: [7, 14, 30, 60, 90].map(d => ({
                            value: d,
                            label: `${d} days`
                        }))
                current: schedCard.cur.olderThanDays
                onActivated: v => schedCard.apply({
                        olderThanDays: v
                    })
            }
        }
        SettingsRow {
            visible: page.sched !== null
            label: "Caches"
            Flow {
                Layout.preferredWidth: 380
                spacing: 6
                layoutDirection: Qt.RightToLeft
                Repeater {
                    model: ["Browsers", "Apps", "Developer", "Thumbnails", "System", "Loft"]
                    delegate: Rectangle {
                        required property string modelData
                        readonly property bool on: (schedCard.cur.categories ?? []).includes("group:" + modelData)
                        implicitWidth: gl.implicitWidth + 18
                        implicitHeight: 24
                        radius: 12
                        color: on ? Theme.accent : Theme.withAlpha(Theme.text, 0.08)
                        Text {
                            id: gl
                            anchors.centerIn: parent
                            text: modelData
                            color: parent.on ? Theme.bg : Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                const id = "group:" + modelData;
                                const cats = (schedCard.cur.categories ?? []).filter(c => c !== id);
                                if (!parent.on)
                                    cats.push(id);
                                schedCard.apply({
                                    categories: cats
                                });
                            }
                        }
                    }
                }
            }
        }
        SettingsRow {
            visible: page.sched !== null
            label: "Empty Trash items older than 30 days"
            SettingsSwitch {
                checked: !!schedCard.cur.trashDays
                onToggled: on => schedCard.apply({
                        trashDays: on ? 30 : 0
                    })
            }
        }
        SettingsRow {
            visible: page.sched !== null
            label: "Apply messaging-download limits"
            SettingsSwitch {
                checked: schedCard.cur.retention === true
                onToggled: on => schedCard.apply({
                        retention: on
                    })
            }
        }
    }
}
