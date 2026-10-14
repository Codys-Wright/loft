import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Features: switch whole modules on or off ("install only what
// you use"). Off modules aren't loaded and their settings pages hide;
// turning one back on restores it as it was. Core modules always run.
ColumnLayout {
    id: page
    spacing: 12

    SettingsCard {
        PageHeader {
            title: "Presets"
        }

        SettingsRow {
            label: "Start from a preset"
            hint: "You can still switch single modules afterwards"

            Repeater {
                model: Object.keys(Features.presets)
                delegate: SettingsButton {
                    required property string modelData
                    text: modelData
                    onClicked: Features.applyPreset(modelData)
                }
            }
        }
    }

    Repeater {
        model: Features.groups.filter(g => Features.modules.some(m => m.group === g))

        delegate: SettingsCard {
            id: group
            required property string modelData
            Layout.fillWidth: true

            PageHeader {
                title: group.modelData
            }

            Repeater {
                model: Features.modules.filter(m => m.group === group.modelData)

                delegate: SettingsRow {
                    required property var modelData
                    Layout.fillWidth: true
                    label: modelData.label
                    hint: modelData.core ? `${modelData.description} · always on` : modelData.description

                    Icon {
                        text: modelData.icon
                        size: 16
                        color: Features.on(modelData.id) ? Theme.accent : Theme.subtext
                    }

                    SettingsSwitch {
                        visible: !modelData.core
                        checked: Features.on(modelData.id)
                        onToggled: on => Features.set(modelData.id, on)
                    }
                }
            }
        }
    }
}
