import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Notifications: Do Not Disturb (now, and on a schedule), how
// long banners stay, and per-app rules for every app that has notified
// (NotificationConfig; services/Notifications.qml applies them).
ColumnLayout {
    id: page
    spacing: 12

    readonly property var cfg: NotificationConfig

    component Note: Text {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 12
    }

    // Half-hour steps for the schedule.
    readonly property var times: {
        const l = [];
        for (let m = 0; m < 24 * 60; m += 30) {
            const h = Math.floor(m / 60), mm = m % 60;
            const v = `${String(h).padStart(2, "0")}:${String(mm).padStart(2, "0")}`;
            l.push({ value: v, label: Qt.formatTime(new Date(2000, 0, 1, h, mm), Qt.locale().timeFormat(Locale.ShortFormat)) });
        }
        return l;
    }

    // ── Do Not Disturb
    SettingsCard {
        objectName: "dnd"

        PageHeader {
            title: "Do Not Disturb"
        }
        SettingsRow {
            label: "Do Not Disturb"
            hint: page.cfg.dndScheduled ? `On by schedule until ${page.cfg.schedule.to}: notifications go to the history without a banner` : page.cfg.dndActive ? "On: notifications go to the history without a banner" : page.cfg.scheduleSkipped ? `Off until the schedule starts again (${page.cfg.schedule.from})` : "Off"
            SettingsSwitch {
                checked: page.cfg.dndActive
                onToggled: on => page.cfg.setDnd(on)
            }
        }
        SettingsRow {
            label: "On a schedule"
            hint: page.cfg.schedule.enabled ? "Every day" : "Off"
            SettingsSelect {
                implicitWidth: 100
                visible: page.cfg.schedule.enabled
                options: page.times
                current: page.cfg.schedule.from
                onActivated: v => page.cfg.schedule.from = v
            }
            Text {
                visible: page.cfg.schedule.enabled
                text: "to"
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 12
            }
            SettingsSelect {
                implicitWidth: 100
                visible: page.cfg.schedule.enabled
                options: page.times
                current: page.cfg.schedule.to
                onActivated: v => page.cfg.schedule.to = v
            }
            SettingsSwitch {
                checked: page.cfg.schedule.enabled
                onToggled: on => page.cfg.schedule.enabled = on
            }
        }
        SettingsRow {
            label: "Allow critical notifications"
            hint: "A low battery, a failing disk: shown even during Do Not Disturb"
            SettingsSwitch {
                checked: page.cfg.allowCritical
                onToggled: on => page.cfg.allowCritical = on
            }
        }
        Note {
            visible: Features.on("spaces")
            text: "A space's Focus can turn Do Not Disturb on and let some apps through (Settings → Spaces)."
        }
    }

    // ── Banners
    SettingsCard {
        objectName: "banners"

        PageHeader {
            title: "Banners"
            SettingsButton {
                text: "Show a test"
                onClicked: Notifications.show({
                    appName: "Loft",
                    appIcon: "preferences-system-notifications",
                    summary: "This is a notification",
                    body: `It stays ${page.cfg.bannerSeconds} s; hovering holds it.`,
                    image: "",
                    actions: []
                })
            }
        }
        SettingsRow {
            label: "Banners stay for"
            hint: "Hovering holds a banner; with several waiting they go faster"
            SettingsSegmented {
                options: [{ value: 2, label: "2 s" }, { value: 3, label: "3 s" }, { value: 5, label: "5 s" }, { value: 8, label: "8 s" }]
                current: page.cfg.bannerSeconds
                onActivated: v => page.cfg.bannerSeconds = v
            }
        }
        SettingsRow {
            label: "History"
            hint: Notifications.history.length === 0 ? "Empty" : `${Notifications.history.length} notification${Notifications.history.length === 1 ? "" : "s"} in the Notification Center`
            SettingsButton {
                text: "Clear"
                enabled: Notifications.history.length > 0
                onClicked: Notifications.clearHistory()
            }
        }
    }

    // ── Apps
    SettingsCard {
        id: appsCard
        objectName: "apps"

        readonly property var apps: Object.keys(page.cfg.seen).sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()))

        PageHeader {
            title: "Apps"
        }
        Note {
            text: appsCard.apps.length === 0 ? "Apps show up here once they send a notification." : "Off: the app's notifications are dropped. Banners off: they go to the history quietly."
        }

        RowLayout {
            visible: appsCard.apps.length > 0
            Layout.fillWidth: true
            Item {
                Layout.fillWidth: true
            }
            Repeater {
                model: ["Banners", "Allow"]
                delegate: Text {
                    required property string modelData
                    Layout.preferredWidth: 52
                    horizontalAlignment: Text.AlignHCenter
                    text: modelData
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                }
            }
            Item {
                Layout.preferredWidth: 24
            }
        }

        Repeater {
            model: appsCard.apps
            delegate: RowLayout {
                id: appRow
                required property string modelData
                readonly property var rule: page.cfg.rule(modelData)
                readonly property var info: page.cfg.seen[modelData] ?? {}
                Layout.fillWidth: true
                spacing: 10

                AppIcon {
                    Layout.preferredWidth: 22
                    Layout.preferredHeight: 22
                    pixelSize: 44
                    appId: appRow.info.icon || appRow.modelData
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1
                    Text {
                        Layout.fillWidth: true
                        text: appRow.modelData
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        text: !appRow.rule.allow ? "Off" : !appRow.rule.banners ? "History only" : "Banners and history"
                        color: appRow.rule.allow ? Theme.subtext : Theme.warn
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                    }
                }
                Item {
                    Layout.preferredWidth: 52
                    implicitHeight: bannerSwitch.implicitHeight
                    SettingsSwitch {
                        id: bannerSwitch
                        anchors.centerIn: parent
                        enabled: appRow.rule.allow
                        opacity: enabled ? 1 : 0.4
                        checked: appRow.rule.banners
                        onToggled: on => page.cfg.setRule(appRow.modelData, "banners", on)
                    }
                }
                Item {
                    Layout.preferredWidth: 52
                    implicitHeight: allowSwitch.implicitHeight
                    SettingsSwitch {
                        id: allowSwitch
                        anchors.centerIn: parent
                        checked: appRow.rule.allow
                        onToggled: on => page.cfg.setRule(appRow.modelData, "allow", on)
                    }
                }
                Text {
                    Layout.preferredWidth: 24
                    horizontalAlignment: Text.AlignHCenter
                    text: "󰅖"
                    color: forgetArea.containsMouse ? Theme.text : Theme.subtext
                    font.family: Theme.fontIcons
                    font.pixelSize: 14
                    MouseArea {
                        id: forgetArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page.cfg.forget(appRow.modelData)
                    }
                }
            }
        }
    }

    // ── Elsewhere
    SettingsCard {
        visible: Features.on("phone")
        PageHeader {
            title: "iPhone"
            SettingsButton {
                text: "Phone…"
                onClicked: Panels.openSettings("phone")
            }
        }
        Note {
            text: "The phone's notifications can be turned off as a whole in Settings → Phone; each iPhone app also gets its own row above (\"Instagram · iPhone\")."
        }
    }
}
