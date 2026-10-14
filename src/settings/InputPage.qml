import QtQuick
import QtQuick.Layouts
import qs.services

// Settings → Input: keyboard (XKB layout, key repeat), mouse and touchpad.
// Values are niri's (NiriSettings); changes become runtime overrides.
ColumnLayout {
    id: page
    spacing: 12


    readonly property var accelOptions: [
        { value: "adaptive", label: "Adaptive" },
        { value: "flat", label: "Flat" }
    ]

    // Keyboard
    SettingsCard {
        PageHeader {
            title: "Keyboard"
            SettingsButton {
                visible: NiriSettings.anyOverridden("input.keyboard")
                text: "Reset"
                onClicked: NiriSettings.unset("input.keyboard")
            }
        }

        NiriRow {
            key: "input.keyboard.xkb.layout"
            extraHint: "XKB layouts, comma-separated (us,de)"
            SettingsTextField {
                text: NiriSettings.value("input.keyboard.xkb.layout") ?? ""
                placeholder: "system default"
                onCommitted: t => NiriSettings.set("input.keyboard.xkb.layout", t.trim())
            }
        }

        NiriRow {
            key: "input.keyboard.xkb.variant"
            SettingsTextField {
                text: NiriSettings.value("input.keyboard.xkb.variant") ?? ""
                placeholder: "none (e.g. dvorak)"
                onCommitted: t => NiriSettings.set("input.keyboard.xkb.variant", t.trim())
            }
        }

        NiriRow {
            key: "input.keyboard.xkb.options"
            SettingsTextField {
                text: NiriSettings.value("input.keyboard.xkb.options") ?? ""
                placeholder: "none (e.g. caps:escape)"
                onCommitted: t => NiriSettings.set("input.keyboard.xkb.options", t.trim())
            }
        }

        NiriRow {
            key: "input.keyboard.repeat-delay"
            SettingsSlider {
                from: 150
                to: 1000
                step: 10
                suffix: " ms"
                value: NiriSettings.value("input.keyboard.repeat-delay") ?? 600
                onCommitted: v => NiriSettings.set("input.keyboard.repeat-delay", Math.round(v))
            }
        }

        NiriRow {
            key: "input.keyboard.repeat-rate"
            SettingsSlider {
                from: 5
                to: 80
                step: 1
                suffix: " /s"
                value: NiriSettings.value("input.keyboard.repeat-rate") ?? 25
                onCommitted: v => NiriSettings.set("input.keyboard.repeat-rate", Math.round(v))
            }
        }
    }

    // Mouse and touchpad share their controls.
    Repeater {
        model: [
            { id: "mouse", title: "Mouse", extra: [] },
            { id: "touchpad", title: "Trackpad", extra: ["tap", "dwt"] }
        ]

        delegate: SettingsCard {
            id: dev
            required property var modelData
            readonly property string prefix: `input.${modelData.id}.`

            PageHeader {
                title: dev.modelData.title
                SettingsButton {
                    visible: NiriSettings.anyOverridden(dev.prefix)
                    text: "Reset"
                    onClicked: NiriSettings.unset(`input.${dev.modelData.id}`)
                }
            }

            NiriRow {
                key: dev.prefix + "accel-speed"
                SettingsSlider {
                    from: -1
                    to: 1
                    step: 0.05
                    value: NiriSettings.value(dev.prefix + "accel-speed") ?? 0
                    format: v => v === 0 ? "default" : (v > 0 ? "+" : "") + v.toFixed(2)
                    onCommitted: v => NiriSettings.set(dev.prefix + "accel-speed", Math.round(v * 100) / 100)
                }
            }

            NiriRow {
                key: dev.prefix + "accel-profile"
                SettingsSegmented {
                    options: page.accelOptions
                    current: NiriSettings.value(dev.prefix + "accel-profile") ?? "adaptive"
                    onActivated: v => NiriSettings.set(dev.prefix + "accel-profile", v)
                }
            }

            NiriRow {
                key: dev.prefix + "natural-scroll"
                extraHint: "Content follows your fingers"
                SettingsSwitch {
                    checked: NiriSettings.value(dev.prefix + "natural-scroll") ?? false
                    onToggled: on => NiriSettings.set(dev.prefix + "natural-scroll", on)
                }
            }

            Repeater {
                model: dev.modelData.extra
                delegate: NiriRow {
                    id: flag
                    required property string modelData
                    key: dev.prefix + modelData
                    SettingsSwitch {
                        checked: NiriSettings.value(flag.key) ?? false
                        onToggled: on => NiriSettings.set(flag.key, on)
                    }
                }
            }
        }
    }

    Text {
        Layout.fillWidth: true
        visible: NiriSettings.error !== ""
        text: NiriSettings.error
        color: Theme.urgent
        font.family: Theme.fontUi
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }
}
