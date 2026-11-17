import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → General ▸ About: this computer (the same facts as the system
// menu's About This Computer, SystemInfo.qml), then Loft. Moved here from
// SettingsApp.qml unchanged.
ColumnLayout {
    id: page
    spacing: 12

    component Row_: SettingsRow {}
    component Card: SettingsCard {}

    // About: this computer (the same facts as the system
    // menu's About This Computer, SystemInfo.qml), then Loft.
    Card {
        id: aboutComputer
        onVisibleChanged: if (visible)
            SystemInfo.refresh()

        RowLayout {
            Layout.fillWidth: true
            Layout.bottomMargin: 4
            spacing: 14
            Icon {
                text: "\uf313"
                size: 44
                color: Theme.accent
            }
            ColumnLayout {
                Layout.fillWidth: true
                Layout.preferredWidth: 10000
                spacing: 2
                Text {
                    text: SystemInfo.host || "This Computer"
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 18
                    font.weight: Font.DemiBold
                }
                Text {
                    text: SystemInfo.os
                    visible: text !== ""
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                }
            }
            SettingsButton {
                visible: Features.on("systemMonitor")
                text: "More Info…"
                onClicked: {
                    SystemStats.monitorSection = "overview";
                    SystemStats.monitorOpen = true;
                }
            }
        }

        Repeater {
            model: SystemInfo.details
            delegate: Row_ {
                required property var modelData
                label: modelData[0]
                Text {
                    Layout.maximumWidth: 420
                    text: modelData[1]
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                    elide: Text.ElideMiddle
                    horizontalAlignment: Text.AlignRight
                }
            }
        }
    }

    Card {

        Row_ {
            label: "loft"
            hint: "niri + Quickshell · github.com/Codys-Wright/loft"
        }
        Row_ {
            label: "Settings file"
            hint: Settings.file
        }
        Row_ {
            label: "Design"
            hint: "Liquid Glass components ported from javiiervm/dotfiles"
        }
    }
}
