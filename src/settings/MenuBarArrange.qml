import QtQuick
import QtQuick.Layouts
import Quickshell.Services.SystemTray
import qs.components
import qs.services

// Settings → Menu Bar → arranging the status area (Bartender / Ice, and
// Golden Gate's own model): show or hide every control and readout, their
// order, "only when active", tray icons pinned or tucked behind », drawn
// as templates or in color; the clock; the Control Center layout.
ColumnLayout {
    id: page
    spacing: 12

    // Bar-capable items, in bar order (available ones).
    readonly property var items: Controls.barOrder.filter(id => Controls.available(id) || id.startsWith("readout.") && Features.on("barReadouts"))

    SettingsCard {
        PageHeader {
            title: "Menu bar items"
            SettingsButton {
                text: "Reset"
                onClicked: Controls.resetBar()
            }
        }

        Text {
            Layout.fillWidth: true
            text: "Left to right as in the bar. Super-drag an item in the bar to move it, or drag it off the bar to remove it. Items that don't fit move behind »."
            wrapMode: Text.WordWrap
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }

        Repeater {
            model: page.items

            delegate: RowLayout {
                id: line
                required property string modelData
                required property int index
                readonly property var c: Controls.control(modelData)
                readonly property bool shown: Controls.onBar(modelData)
                readonly property string mode: Controls.activeOnlyMode(modelData)
                Layout.fillWidth: true
                spacing: 10

                Rectangle {
                    Layout.preferredWidth: 28
                    Layout.preferredHeight: 28
                    radius: 14
                    color: Theme.withAlpha(Theme.text, line.shown ? 0.14 : 0.06)
                    Icon {
                        anchors.centerIn: parent
                        text: line.modelData.startsWith("readout.") ? "󰍛" : Controls.iconOf(line.modelData)
                        size: 13
                        opacity: line.shown ? 1 : 0.4
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                        Layout.fillWidth: true
                        text: line.c?.label ?? line.modelData
                        color: Theme.text
                        opacity: line.shown ? 1 : 0.5
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: text !== ""
                        text: line.mode === "always" ? "Shown only while in use" : line.modelData.startsWith("readout.") ? "Readout (Settings → System)" : ""
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 10
                    }
                }

                // Only when active.
                Text {
                    visible: line.mode === "option" || line.mode === "default"
                    text: "When active"
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                }
                SettingsSwitch {
                    visible: line.mode === "option" || line.mode === "default"
                    scale: 0.8
                    checked: Controls.activeOnly(line.modelData)
                    onToggled: on => Controls.setActiveOnly(line.modelData, on)
                }

                // Order.
                Repeater {
                    model: [{ glyph: "󰅃", d: -1 }, { glyph: "󰅀", d: 1 }]
                    delegate: Rectangle {
                        required property var modelData
                        Layout.preferredWidth: 24
                        Layout.preferredHeight: 24
                        radius: 12
                        color: arrow.containsMouse ? Theme.withAlpha(Theme.text, 0.14) : "transparent"
                        opacity: line.shown ? 1 : 0.3
                        Icon {
                            anchors.centerIn: parent
                            text: parent.modelData.glyph
                            size: 13
                        }
                        MouseArea {
                            id: arrow
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: line.shown
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Controls.stepBarItem(line.modelData, parent.modelData.d)
                        }
                    }
                }

                SettingsSwitch {
                    checked: line.shown
                    onToggled: on => Controls.setOnBar(line.modelData, on)
                }
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: "Status icons (tray)"
        }
        Text {
            Layout.fillWidth: true
            text: SystemTray.items.values.length === 0 ? "No app has a status icon right now." : "Pinned icons sit in the bar; tucked ones live behind ». Like macOS, icons are drawn in the bar's color unless you show them in color."
            wrapMode: Text.WordWrap
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }

        Repeater {
            model: SystemTray.items

            delegate: RowLayout {
                id: tray
                required property var modelData
                readonly property bool tucked: Controls.isTrayTucked(modelData)
                readonly property string duplicate: Controls.trayDuplicateOf(modelData)
                readonly property bool colored: Controls.trayColor.includes(modelData.id)
                Layout.fillWidth: true
                spacing: 10

                Rectangle {
                    Layout.preferredWidth: 28
                    Layout.preferredHeight: 28
                    radius: 14
                    color: Theme.withAlpha(Theme.text, 0.14)
                    TemplateIcon {
                        anchors.centerIn: parent
                        size: 16
                        source: tray.modelData.icon
                        color: Theme.text
                        template: !tray.colored
                    }
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                        Layout.fillWidth: true
                        text: tray.modelData.tooltipTitle || tray.modelData.title || tray.modelData.id
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: tray.duplicate !== ""
                        text: `Does what Loft's ${Controls.control(tray.duplicate)?.label ?? ""} does — tucked by default`
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 10
                        elide: Text.ElideRight
                    }
                }
                Text {
                    text: "In color"
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                }
                SettingsSwitch {
                    scale: 0.8
                    checked: tray.colored
                    onToggled: on => Controls.setTrayColor(tray.modelData.id, on)
                }
                SettingsSegmented {
                    options: [{ value: false, label: "Bar" }, { value: true, label: "»" }]
                    current: tray.tucked
                    onActivated: v => Controls.setTrayTucked(tray.modelData.id, v)
                }
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: "Clock"
        }
        SettingsRow {
            label: "Show the time"
            hint: "The time also lives in the island; the bar shows the date by default"
            SettingsSwitch {
                checked: Settings.menubar.clockTime === true
                onToggled: on => AppMenu.setPref("clockTime", on)
            }
        }
        SettingsRow {
            visible: Settings.menubar.clockTime === true
            label: "24-hour time"
            SettingsSwitch {
                checked: Settings.menubar.clock24 === true
                onToggled: on => AppMenu.setPref("clock24", on)
            }
        }
    }

    SettingsCard {
        visible: Features.on("controlcenter")
        PageHeader {
            title: "Control Center"
            SettingsButton {
                text: "Reset layout"
                onClicked: Controls.ccReset()
            }
            SettingsButton {
                text: "Edit Controls…"
                onClicked: {
                    Panels.settingsOpen = false;
                    Panels.toggleControlCenter(Displays.activeName);
                    Panels.ccEditing = true;
                }
            }
        }
        Text {
            Layout.fillWidth: true
            text: "Drag to reorder, − removes, ⤢ resizes; the gallery adds controls and pins them to the menu bar."
            wrapMode: Text.WordWrap
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
    }
}
