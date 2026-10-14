import QtQuick
import QtQuick.Layouts
import qs.components
import qs.desktopmenu
import qs.services

// Settings → Desktop Menu: what a right-click on the wallpaper shows.
// Items (and the separators between them) can be shown, hidden and moved;
// saved as Settings.desktopMenu.items. Items of a switched-off module stay
// listed but don't appear in the menu. "Edit Menu…" is always last.
ColumnLayout {
    id: page
    spacing: 12

    SettingsCard {
        SettingsRow {
            label: "Right-click the desktop"
            hint: "A menu at the pointer when you right-click the wallpaper"
            SettingsSwitch {
                checked: Features.on("desktopMenu")
                onToggled: on => Features.set("desktopMenu", on)
            }
        }

        SettingsRow {
            label: "Preview"
            hint: "Opens the menu in the middle of this display (Esc closes)"
            SettingsButton {
                text: "Show Menu"
                enabled: Features.on("desktopMenu")
                onClicked: DesktopMenu.openCentered(Niri.focusedWorkspace?.output ?? "")
            }
        }
    }

    SettingsCard {
        spacing: 2

        PageHeader {
            Layout.bottomMargin: 8
            title: "Items"
            SettingsButton {
                text: "Reset"
                enabled: (Settings.desktopMenu?.items ?? null) !== null
                onClicked: DesktopMenu.resetLayout()
            }
        }

        Repeater {
            model: DesktopMenu.layout

            delegate: Item {
                id: row
                required property var modelData
                required property int index
                readonly property var item: DesktopMenu.entry(modelData.id)
                readonly property bool sep: item.separator === true
                readonly property bool featureOn: DesktopMenu.available(item)
                readonly property bool shown: modelData.shown

                Layout.fillWidth: true
                implicitHeight: sep ? 30 : 42

                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: hover.containsMouse ? Theme.withAlpha(Theme.text, 0.05) : "transparent"
                }

                MouseArea {
                    id: hover
                    anchors.fill: parent
                    hoverEnabled: true
                }

                // Separator: a caption and a hairline across the row.
                Text {
                    id: sepLabel
                    visible: row.sep
                    anchors {
                        left: parent.left
                        leftMargin: 38
                        verticalCenter: parent.verticalCenter
                    }
                    text: "Separator"
                    color: Theme.subtext
                    opacity: row.shown ? 1 : 0.5
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                }

                Rectangle {
                    visible: row.sep
                    anchors {
                        left: sepLabel.right
                        right: controls.left
                        leftMargin: 10
                        rightMargin: 16
                        verticalCenter: parent.verticalCenter
                    }
                    height: 1
                    color: Theme.withAlpha(Theme.text, row.shown ? 0.3 : 0.12)
                }

                RowLayout {
                    visible: !row.sep
                    anchors {
                        left: parent.left
                        right: controls.left
                        leftMargin: 10
                        rightMargin: 16
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: 10
                    opacity: row.shown && row.featureOn ? 1 : 0.5

                    Icon {
                        Layout.preferredWidth: 18
                        text: row.item.icon ?? ""
                        size: 14
                        color: Theme.subtext
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1

                        Text {
                            Layout.fillWidth: true
                            text: row.item.label + (row.item.submenu ? "  ▸" : "")
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 13
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: row.featureOn ? (row.item.hint ?? "") : `Not in the menu: ${Features.module(row.item.feature)?.label ?? row.item.feature} is off (Features)`
                            color: row.featureOn ? Theme.subtext : Theme.warn
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
                        onClicked: DesktopMenu.move(row.modelData.id, -1)
                    }
                    MoveButton {
                        glyph: "󰁅"
                        enabled: row.index < DesktopMenu.layout.length - 1
                        onClicked: DesktopMenu.move(row.modelData.id, 1)
                    }
                    SettingsSwitch {
                        Layout.leftMargin: 6
                        checked: row.shown
                        onToggled: on => DesktopMenu.setShown(row.modelData.id, on)
                    }
                }
            }
        }

        // The fixed last item.
        Item {
            Layout.fillWidth: true
            implicitHeight: 34

            Text {
                anchors {
                    left: parent.left
                    leftMargin: 38
                    verticalCenter: parent.verticalCenter
                }
                text: "Edit Menu…  ·  always last"
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 12
            }
        }
    }

    // Up / down arrow button.
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
}
