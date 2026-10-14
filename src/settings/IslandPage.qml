import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Dynamic Island: page order and visibility, calendars, timers,
// downloads, AI agents, lyrics and the alert thresholds
// (Settings.island; pages: IslandPages).
ColumnLayout {
    id: page
    spacing: 12

    readonly property var isl: Settings.island

    component Hint: Text {
        Layout.fillWidth: true
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }

    component MoveButton: Rectangle {
        id: btn
        property string glyph
        signal clicked

        implicitWidth: 28
        implicitHeight: 26
        radius: 8
        color: hit.containsMouse && enabled ? Theme.withAlpha(Theme.text, 0.16) : Theme.withAlpha(Theme.text, 0.08)
        opacity: enabled ? 1 : 0.3

        Icon {
            anchors.centerIn: parent
            text: btn.glyph
            size: 14
            color: Theme.text
        }

        MouseArea {
            id: hit
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }

    // ── Pages ───────────────────────────────────────────────────────────
    SettingsCard {
        PageHeader {
            title: "Pages"
            SettingsButton {
                text: "Reset"
                onClicked: IslandPages.reset()
            }
        }

        Hint {
            text: "Hover the island to expand it; scroll to switch pages. Collapsed, it shows (first wins): alerts and banners, live activities, the next event when it's close, now playing, the time."
        }

        Repeater {
            model: IslandPages.order

            delegate: Item {
                id: row
                required property var modelData
                required property int index
                readonly property var info: IslandPages.info(modelData.id)

                Layout.fillWidth: true
                implicitHeight: 42

                RowLayout {
                    anchors {
                        left: parent.left
                        right: controls.left
                        leftMargin: 6
                        rightMargin: 16
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: 10
                    opacity: row.modelData.shown ? 1 : 0.5

                    Icon {
                        Layout.preferredWidth: 18
                        text: row.info?.icon ?? ""
                        size: 14
                        color: Theme.subtext
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Text {
                            Layout.fillWidth: true
                            text: row.info?.label ?? row.modelData.id
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 13
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: row.info?.hint ?? ""
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                    }
                }

                RowLayout {
                    id: controls
                    anchors {
                        right: parent.right
                        rightMargin: 6
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: 6

                    MoveButton {
                        glyph: "󰁝"
                        enabled: row.index > 0
                        onClicked: IslandPages.move(row.modelData.id, -1)
                    }
                    MoveButton {
                        glyph: "󰁅"
                        enabled: row.index < IslandPages.order.length - 1
                        onClicked: IslandPages.move(row.modelData.id, 1)
                    }
                    SettingsSwitch {
                        Layout.leftMargin: 6
                        checked: row.modelData.shown
                        onToggled: on => IslandPages.setShown(row.modelData.id, on)
                    }
                }
            }
        }
    }

    // ── Calendar ────────────────────────────────────────────────────────
    SettingsCard {
        PageHeader {
            title: "Calendar"
            SettingsButton {
                text: "Refresh"
                onClicked: Agenda.refresh(true)
            }
        }

        SettingsRow {
            label: "Calendars"
            hint: Agenda.sources.length ? `Reading: ${Agenda.sources.map(s => ({ khal: "khal", vdirsyncer: "vdirsyncer", eds: "Evolution", ics: "ICS" })[s] ?? s).join(", ")} · ${Agenda.events.length} events today and tomorrow` : "Automatic: khal or vdirsyncer calendars if configured, else Evolution Data Server (GNOME accounts)"
            SettingsSelect {
                options: [
                    { value: "auto", label: "Automatic" },
                    { value: "khal", label: "khal" },
                    { value: "vdirsyncer", label: "vdirsyncer" },
                    { value: "eds", label: "Evolution (GNOME)" },
                    { value: "none", label: "Only ICS below" }
                ]
                current: page.isl.calendarSource
                onActivated: v => page.isl.calendarSource = v
            }
        }

        SettingsRow {
            label: "ICS calendars"
            hint: "A file, or an http(s) / webcal link (refreshed every 15 min)"
            SettingsTextField {
                implicitWidth: 260
                placeholder: "https://…/basic.ics or ~/cal.ics"
                onCommitted: t => {
                    const v = t.trim();
                    if (v !== "" && !Array.from(page.isl.calendarIcs).includes(v))
                        page.isl.calendarIcs = Array.from(page.isl.calendarIcs).concat([v]);
                    text = "";
                }
            }
        }

        Repeater {
            model: Array.from(page.isl.calendarIcs)
            delegate: RowLayout {
                required property string modelData
                Layout.fillWidth: true
                Layout.leftMargin: 6
                spacing: 8
                Icon {
                    text: "󰃭"
                    size: 13
                    color: Theme.subtext
                }
                Text {
                    Layout.fillWidth: true
                    // Secret iCal links carry a token: show the host only.
                    text: /^(https?|webcal):\/\//i.test(modelData) ? modelData.replace(/^(\w+:\/\/[^/]+).*$/, "$1/…") : modelData
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                    elide: Text.ElideMiddle
                }
                SettingsButton {
                    text: "Remove"
                    onClicked: page.isl.calendarIcs = Array.from(page.isl.calendarIcs).filter(s => s !== modelData)
                }
            }
        }

        SettingsRow {
            label: "Next event in the island"
            hint: "How long before it starts the collapsed island shows it"
            SettingsSlider {
                from: 5
                to: 60
                step: 5
                suffix: " min"
                value: page.isl.eventSoonMinutes
                onMoved: v => page.isl.eventSoonMinutes = v
            }
        }
    }

    // ── Timers ──────────────────────────────────────────────────────────
    SettingsCard {
        PageHeader {
            title: "Timers & Focus"
        }

        SettingsRow {
            label: "Focus session"
            SettingsSlider {
                from: 5
                to: 90
                step: 5
                suffix: " min"
                value: page.isl.focusMinutes
                onMoved: v => page.isl.focusMinutes = v
            }
        }

        SettingsRow {
            label: "Alarm sound"
            hint: "When a timer ends (its banner shows even in Do Not Disturb)"
            SettingsSwitch {
                checked: page.isl.timerSound
                onToggled: on => page.isl.timerSound = on
            }
        }

        Hint {
            text: "Start timers from the Timers page, or anywhere: loft island timer 25m tea · loft island stopwatch · Spotlight: >loft island timer 10m"
        }
    }

    // ── Downloads ───────────────────────────────────────────────────────
    SettingsCard {
        PageHeader {
            title: "Downloads"
        }

        SettingsRow {
            label: "Show downloads"
            hint: "Progress in the island, then Open / Show in Files / drag out"
            SettingsSwitch {
                checked: page.isl.downloads
                onToggled: on => page.isl.downloads = on
            }
        }

        SettingsRow {
            label: "Folder"
            hint: Downloads.watching !== "" ? `Watching ${Downloads.watching}` : "Empty = your Downloads folder"
            SettingsTextField {
                implicitWidth: 240
                text: page.isl.downloadsDir
                placeholder: "~/Downloads"
                onCommitted: t => page.isl.downloadsDir = t.trim()
            }
        }
    }

    // ── AI agents ───────────────────────────────────────────────────────
    SettingsCard {
        PageHeader {
            title: "AI Agents"
        }

        SettingsRow {
            label: "Claude Code & Codex usage"
            hint: "Token counts from their logs on this computer"
            SettingsSwitch {
                checked: page.isl.ai
                onToggled: on => page.isl.ai = on
            }
        }

        Hint {
            text: "Reads ~/.claude/projects and ~/.codex/sessions: usage numbers, model names and project folder names only — never prompts, replies or file contents. Costs are estimates at API prices (a subscription doesn't pay them). Nothing leaves this computer."
        }

        SettingsRow {
            label: "Running agents in the island"
            hint: "A sparkle and a count next to the time while sessions run"
            SettingsSwitch {
                checked: page.isl.aiIndicator
                onToggled: on => page.isl.aiIndicator = on
            }
        }
    }

    // ── Now Playing ─────────────────────────────────────────────────────
    SettingsCard {
        PageHeader {
            title: "Now Playing"
        }

        SettingsRow {
            label: "Lyrics"
            hint: "Synced lyrics on the media page, from lrclib.net"
            SettingsSwitch {
                checked: page.isl.lyrics
                onToggled: on => page.isl.lyrics = on
            }
        }

        Hint {
            text: "When on, each playing track's artist, title, album and length is sent to lrclib.net (answers are cached)."
        }
    }

    // ── Alerts ──────────────────────────────────────────────────────────
    SettingsCard {
        PageHeader {
            title: "Alerts"
        }

        SettingsRow {
            label: "Overheat alert"
            hint: "Border pulses red above this temperature"
            SettingsSlider {
                from: 60
                to: 105
                step: 1
                suffix: " °C"
                value: page.isl.maxTemp
                onMoved: v => page.isl.maxTemp = v
            }
        }

        SettingsRow {
            label: "Load alert"
            hint: "CPU or memory use that turns the border amber"
            SettingsSlider {
                from: 0.5
                to: 1
                step: 0.01
                decimals: 2
                value: page.isl.maxLoad
                onMoved: v => page.isl.maxLoad = v
            }
        }
    }
}
