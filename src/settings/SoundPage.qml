import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Pipewire
import qs.audio
import qs.components
import qs.services

// Settings → Sound: output and input devices, the mixer's options and
// favorites, microphone tools. Cards follow the Sound features that are on
// (Features page); devices and volumes are PipeWire's own state, the rest
// lives in Settings.sound.
ColumnLayout {
    id: page
    spacing: 12

    readonly property PwNode sink: Sound.defaultSink
    readonly property PwNode source: Sound.defaultSource

    // ── Output ──────────────────────────────────────────────────────────
    SettingsCard {
        PageHeader {
            title: "Output"
        }

        SettingsRow {
            label: "Output device"
            hint: Features.on("audioOutputs") ? "⌘⇧O cycles through outputs" : ""
            SettingsSelect {
                implicitWidth: 240
                options: Sound.sinks.map(n => ({
                            value: n.id,
                            label: Sound.label(n)
                        }))
                current: page.sink?.id
                placeholder: "No output"
                onActivated: id => Sound.setDefaultSink(Sound.sinks.find(n => n.id === id))
            }
        }

        SettingsRow {
            label: "Output volume"
            enabled: page.sink?.ready ?? false
            SettingsSlider {
                from: 0
                to: 100
                step: 1
                suffix: " %"
                value: (page.sink?.audio?.volume ?? 0) * 100
                onMoved: v => {
                    if (page.sink?.ready)
                        page.sink.audio.volume = v / 100;
                }
            }
        }

        SettingsRow {
            visible: Features.on("audioOutputs")
            label: "Lower volume when headphones disconnect"
            hint: "When headphones or a Bluetooth output go away, the next output starts quiet"
            SettingsSwitch {
                checked: Settings.sound.safeOnUnplug
                onToggled: on => Settings.sound.safeOnUnplug = on
            }
        }

        SettingsRow {
            visible: Features.on("audioOutputs")
            enabled: Settings.sound.safeOnUnplug
            label: "Safe volume"
            SettingsSlider {
                from: 5
                to: 80
                step: 5
                suffix: " %"
                value: Settings.sound.safeVolume * 100
                onMoved: v => Settings.sound.safeVolume = v / 100
            }
        }
    }

    // ── Mixer ───────────────────────────────────────────────────────────
    SettingsCard {
        visible: Features.on("mixer")

        PageHeader {
            title: "Volume mixer"
            SettingsButton {
                text: "Open mixer"
                onClicked: {
                    Panels.settingsOpen = false;
                    Sound.openMixer("");
                }
            }
        }

        Text {
            Layout.fillWidth: true
            text: "Right-click the volume icon in the menu bar, or the chevron on the Control Center's volume slider."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        SettingsRow {
            label: "Boost up to 150 %"
            hint: "Apps can be turned up past 100 % (amber above the mark)"
            SettingsSwitch {
                checked: Settings.sound.boost
                onToggled: on => Settings.sound.boost = on
            }
        }

        SettingsRow {
            label: "Level meters"
            hint: "Live levels for apps and the microphone while the mixer is open"
            SettingsSwitch {
                checked: Settings.sound.meters
                onToggled: on => Settings.sound.meters = on
            }
        }

        SettingsRow {
            label: "Favorites"
            hint: Settings.sound.pinned.length === 0 ? "Pin apps in the mixer to keep them on top, even when silent" : "Shown first in the mixer, in this order"
        }

        Repeater {
            model: Settings.sound.pinned
            delegate: Rectangle {
                id: fav
                required property string modelData
                required property int index
                Layout.fillWidth: true
                implicitHeight: 38
                radius: 10
                color: Theme.withAlpha(Theme.text, 0.06)

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 10
                        rightMargin: 10
                    }
                    spacing: 10

                    Image {
                        Layout.preferredWidth: 22
                        Layout.preferredHeight: 22
                        source: Sound.apps.find(a => a.key === fav.modelData)?.icon ?? Apps.icon(fav.modelData.toLowerCase())
                        sourceSize: Qt.size(44, 44)
                    }
                    Text {
                        Layout.fillWidth: true
                        text: fav.modelData
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }

                    Repeater {
                        model: [
                            { glyph: "󰁝", step: -1, on: fav.index > 0 },
                            { glyph: "󰁅", step: 1, on: fav.index < Settings.sound.pinned.length - 1 }
                        ]
                        delegate: Icon {
                            required property var modelData
                            text: modelData.glyph
                            size: 13
                            opacity: modelData.on ? 1 : 0.25
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -6
                                enabled: parent.modelData.on
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Sound.movePin(fav.modelData, parent.modelData.step)
                            }
                        }
                    }

                    Icon {
                        text: "󰅖"
                        size: 12
                        color: Theme.subtext
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Sound.togglePin(fav.modelData)
                        }
                    }
                }
            }
        }
    }

    // ── Input ───────────────────────────────────────────────────────────
    SettingsCard {
        visible: Features.on("micTools")

        PageHeader {
            title: "Input"
        }

        SettingsRow {
            label: "Input device"
            SettingsSelect {
                implicitWidth: 240
                options: Sound.sources.map(n => ({
                            value: n.id,
                            label: Sound.label(n)
                        }))
                current: page.source?.id
                placeholder: "No input"
                onActivated: id => Sound.setDefaultSource(Sound.sources.find(n => n.id === id))
            }
        }

        SettingsRow {
            label: "Input level"
            hint: Sound.micsMuted ? "Muted" : Sound.recording ? `In use by ${Sound.recordingApps.join(", ")}` : ""
            LevelMeter {
                Layout.preferredWidth: 240
                Layout.preferredHeight: 6
                node: page.source
                // Only meter while this page is on screen.
                active: page.visible && Panels.settingsOpen && !Sound.micsMuted
            }
        }

        SettingsRow {
            label: "Input volume"
            enabled: page.source?.ready ?? false
            SettingsSlider {
                from: 0
                to: 100
                step: 1
                suffix: " %"
                value: (page.source?.audio?.volume ?? 0) * 100
                onMoved: v => {
                    if (page.source?.ready)
                        page.source.audio.volume = v / 100;
                }
            }
        }

        SettingsRow {
            label: "Mute all microphones"
            hint: "⌘⇧M anywhere"
            SettingsSwitch {
                checked: Sound.micsMuted
                onToggled: on => Sound.setMicsMuted(on)
            }
        }

        SettingsRow {
            label: "Microphone in the menu bar"
            hint: "While an app is recording, or the microphones are muted"
            SettingsSwitch {
                checked: Settings.sound.micIndicator
                onToggled: on => Settings.sound.micIndicator = on
            }
        }
    }
}
