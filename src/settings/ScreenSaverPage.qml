import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Screen Saver: how the screen saver looks (lock/ScreenSaver.qml,
// LockSleepConfig.screenSaver). When it starts is in Lock & Sleep.
ColumnLayout {
    id: page
    spacing: 12

    readonly property var look: LockSleepConfig.screenSaver

    readonly property var styles: [
        { value: "clock", label: "Clock", hint: "The wallpaper, darkened, under a large clock" },
        { value: "drift", label: "Drift", hint: "The wallpaper slowly pans and zooms; a small clock in the corner" },
        { value: "black", label: "Black", hint: "Black with a dim clock that moves now and then (kind to OLED screens)" }
    ]

    SettingsCard {
        PageHeader {
            title: "Screen Saver"
            SettingsButton {
                text: "Timing…"
                onClicked: Panels.openSettings("locksleep", "idle")
            }
            SettingsButton {
                text: "Preview"
                primary: true
                onClicked: Idle.previewSaver()
            }
        }
        SettingsRow {
            label: "Starts after"
            readonly property real secs: LockSleepConfig.seconds("screenSaver", Idle.power)
            hint: secs > 0 ? `${Math.round(secs / 60)} min idle ${Idle.hasBattery ? (Idle.onBattery ? "on battery" : "on power") : ""}` : "Never — choose a time in Lock & Sleep"
            hintColor: secs > 0 ? Theme.subtext : Theme.warn
        }
    }

    SettingsCard {
        PageHeader {
            title: "Style"
        }

        Flow {
            Layout.fillWidth: true
            spacing: 10

            Repeater {
                model: page.styles
                delegate: VibeThumb {
                    required property var modelData
                    title: modelData.label
                    subtitle: modelData.hint
                    selected: page.look.style === modelData.value
                    onClicked: page.look.style = modelData.value

                    // A small picture of the style.
                    Rectangle {
                        anchors.fill: parent
                        color: modelData.value === "black" ? "black" : "transparent"
                        Rectangle {
                            anchors.fill: parent
                            visible: modelData.value !== "black"
                            gradient: Gradient {
                                GradientStop { position: 0; color: Theme.wallpaperGradient[0] ?? Theme.bg }
                                GradientStop { position: 1; color: Theme.wallpaperGradient[2] ?? Theme.overlay }
                            }
                            Rectangle {
                                anchors.fill: parent
                                color: Qt.rgba(0, 0, 0, modelData.value === "clock" ? 0.4 : 0.15)
                            }
                        }
                        Text {
                            text: Qt.formatTime(new Date(), "H:mm")
                            color: "white"
                            opacity: modelData.value === "black" ? 0.55 : 0.92
                            font.family: Theme.fontUi
                            font.weight: Font.Bold
                            font.pixelSize: modelData.value === "drift" ? 14 : 26
                            x: modelData.value === "drift" ? 10 : modelData.value === "black" ? parent.width * 0.55 : (parent.width - width) / 2
                            y: modelData.value === "drift" ? parent.height - height - 8 : modelData.value === "black" ? parent.height * 0.2 : (parent.height - height) / 2
                        }
                    }
                }
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: "Show"
        }
        SettingsRow {
            label: "Clock and date"
            SettingsSwitch {
                checked: page.look.showClock
                onToggled: on => page.look.showClock = on
            }
        }
        SettingsRow {
            label: "Now Playing"
            hint: "The playing track under the clock"
            SettingsSwitch {
                checked: page.look.showMedia
                onToggled: on => page.look.showMedia = on
            }
        }
    }
}
