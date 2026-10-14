import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Spaces (docs/SPACES.md §6.4), read-only for now: every space
// in Mod+N order, which workspace it puts on each display role and where
// that workspace is right now, with Activate (and Open, which also starts
// the space's apps, once loft-niri has it). Creating and editing spaces is
// SPACES P6; until then they're JSON in the spaces library.
ColumnLayout {
    id: page
    spacing: 12

    onVisibleChanged: if (visible)
        Spaces.reload()

    // "MPG491CX OLED (center)" for an output connector.
    function where(output) {
        const s = Displays.screens.find(x => x.name === output);
        return s ? DockData.displayLabel(s) : output;
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

        Text {
            Layout.fillWidth: true
            text: `Spaces are JSON files in ${Spaces.libraryDir}. Creating and editing them here comes later.`
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Repeater {
            model: Spaces.problems
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

        Text {
            Layout.fillWidth: true
            visible: Spaces.lastError !== ""
            text: Spaces.lastError
            color: Theme.warn
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
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
            readonly property bool isActive: modelData.id === Spaces.activeId
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
                model: card.roles

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
        }
    }
}
