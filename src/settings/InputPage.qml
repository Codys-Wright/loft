import QtQuick
import QtQuick.Layouts
import qs.services

// Settings → Input: keyboard (XKB layout, key repeat), mouse and touchpad.
// Values are niri's (NiriSettings); changes become runtime overrides. Under
// KWin the same controls write KDE's settings (KdeInput, docs/KWIN.md §4.12):
// layouts to kxkbrc, key repeat to kcminputrc, mouse and trackpad to each
// device through KWin, and only what the devices support is shown.
ColumnLayout {
    id: page
    spacing: 12

    readonly property bool kde: Compositor.backend === "kwin"

    // Pages stay loaded: read KDE's settings again each time this one shows
    // (a device plugged in, a change made in System Settings).
    onVisibleChanged: {
        if (visible && kde)
            KdeInput.reload();
    }

    // niri's labels for the switches only KDE's rows use.
    readonly property var kdeLabels: ({
        "tap": "Tap to click",
        "drag": "Tap and drag",
        "dwt": "Disable while typing",
        "left-handed": "Left-handed",
        "middle-emulation": "Middle-click emulation"
    })

    readonly property var accelOptions: [
        { value: "adaptive", label: "Adaptive" },
        { value: "flat", label: "Flat" }
    ]

    // Keyboard
    SettingsCard {
        PageHeader {
            title: "Keyboard"
            SettingsButton {
                visible: !page.kde && NiriSettings.anyOverridden("input.keyboard")
                text: "Reset"
                onClicked: NiriSettings.unset("input.keyboard")
            }
        }

        NiriRow {
            visible: !page.kde
            key: "input.keyboard.xkb.layout"
            extraHint: "XKB layouts, comma-separated (us,de)"
            SettingsTextField {
                text: NiriSettings.value("input.keyboard.xkb.layout") ?? ""
                placeholder: "system default"
                onCommitted: t => NiriSettings.set("input.keyboard.xkb.layout", t.trim())
            }
        }

        NiriRow {
            visible: !page.kde
            key: "input.keyboard.xkb.variant"
            SettingsTextField {
                text: NiriSettings.value("input.keyboard.xkb.variant") ?? ""
                placeholder: "none (e.g. dvorak)"
                onCommitted: t => NiriSettings.set("input.keyboard.xkb.variant", t.trim())
            }
        }

        NiriRow {
            visible: !page.kde
            key: "input.keyboard.xkb.options"
            SettingsTextField {
                text: NiriSettings.value("input.keyboard.xkb.options") ?? ""
                placeholder: "none (e.g. caps:escape)"
                onCommitted: t => NiriSettings.set("input.keyboard.xkb.options", t.trim())
            }
        }

        NiriRow {
            visible: !page.kde
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
            visible: !page.kde
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

        // KDE: kxkbrc, applied by KWin at once.
        SettingsRow {
            visible: page.kde
            label: "Keyboard layout"
            hint: "XKB layouts, comma-separated (us,de) · KDE's keyboard setting"
            SettingsTextField {
                text: KdeInput.xkbLayout
                placeholder: "system default"
                onCommitted: t => KdeInput.setXkb("layout", t.trim())
            }
        }

        SettingsRow {
            visible: page.kde
            label: "Layout variant"
            hint: "One per layout, comma-separated (,nodeadkeys)"
            SettingsTextField {
                text: KdeInput.xkbVariant
                placeholder: "none (e.g. dvorak)"
                onCommitted: t => KdeInput.setXkb("variant", t.trim())
            }
        }

        SettingsRow {
            visible: page.kde
            label: "XKB options"
            SettingsTextField {
                text: KdeInput.xkbOptions
                placeholder: "none (e.g. caps:escape)"
                onCommitted: t => KdeInput.setXkb("options", t.trim())
            }
        }

        // KDE: kcminputrc, applied by KWin at once.
        SettingsRow {
            visible: page.kde
            label: "Repeat delay"
            hint: "KDE's keyboard setting (kcminputrc)"
            SettingsSlider {
                from: 150
                to: 1000
                step: 10
                suffix: " ms"
                value: KdeInput.repeatDelay
                onCommitted: v => KdeInput.setRepeat(Math.round(v), KdeInput.repeatRate)
            }
        }

        SettingsRow {
            visible: page.kde
            label: "Repeat rate"
            hint: "KDE's keyboard setting (kcminputrc)"
            SettingsSlider {
                from: 5
                to: 80
                step: 1
                suffix: " /s"
                value: KdeInput.repeatRate
                onCommitted: v => KdeInput.setRepeat(KdeInput.repeatDelay, Math.round(v))
            }
        }

        SettingsRow {
            visible: page.kde && !KdeInput.libinput
            label: "Mouse and trackpad"
            hint: "KWin lists no mouse or trackpad it can configure here"
        }
    }

    // Mouse and touchpad share their controls.
    Repeater {
        model: [
            { id: "mouse", title: "Mouse", extra: [], kdeExtra: ["left-handed", "middle-emulation"] },
            { id: "touchpad", title: "Trackpad", extra: ["tap", "dwt"], kdeExtra: ["tap", "drag", "dwt", "left-handed"] }
        ]

        delegate: SettingsCard {
            id: dev
            required property var modelData
            // Under KWin: when a device of this kind is there.
            visible: !page.kde || (KdeInput.section(modelData.id).supported ?? []).length > 0
            readonly property string prefix: `input.${modelData.id}.`
            function has(key) {
                return KdeInput.supports(dev.modelData.id, key);
            }

            PageHeader {
                title: dev.modelData.title
                SettingsButton {
                    visible: !page.kde && NiriSettings.anyOverridden(dev.prefix)
                    text: "Reset"
                    onClicked: NiriSettings.unset(`input.${dev.modelData.id}`)
                }
            }

            NiriRow {
                visible: !page.kde
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
                visible: !page.kde
                key: dev.prefix + "accel-profile"
                SettingsSegmented {
                    options: page.accelOptions
                    current: NiriSettings.value(dev.prefix + "accel-profile") ?? "adaptive"
                    onActivated: v => NiriSettings.set(dev.prefix + "accel-profile", v)
                }
            }

            NiriRow {
                visible: !page.kde
                key: dev.prefix + "natural-scroll"
                extraHint: "Content follows your fingers"
                SettingsSwitch {
                    checked: NiriSettings.value(dev.prefix + "natural-scroll") ?? false
                    onToggled: on => NiriSettings.set(dev.prefix + "natural-scroll", on)
                }
            }

            Repeater {
                model: page.kde ? [] : dev.modelData.extra
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

            // KDE: the same settings on every device of this kind (KdeInput).
            SettingsRow {
                visible: page.kde && dev.has("accel-speed")
                label: "Pointer speed"
                SettingsSlider {
                    from: -1
                    to: 1
                    step: 0.05
                    value: KdeInput.value(dev.modelData.id, "accel-speed") ?? 0
                    format: v => v === 0 ? "default" : (v > 0 ? "+" : "") + v.toFixed(2)
                    onCommitted: v => KdeInput.setDevice(dev.modelData.id, "accel-speed", Math.round(v * 100) / 100)
                }
            }

            SettingsRow {
                visible: page.kde && dev.has("accel-profile")
                label: "Acceleration"
                SettingsSegmented {
                    options: page.accelOptions
                    current: KdeInput.value(dev.modelData.id, "accel-profile") ?? "adaptive"
                    onActivated: v => KdeInput.setDevice(dev.modelData.id, "accel-profile", v)
                }
            }

            SettingsRow {
                visible: page.kde && dev.has("natural-scroll")
                label: "Natural scrolling"
                hint: "Content follows your fingers"
                SettingsSwitch {
                    checked: KdeInput.value(dev.modelData.id, "natural-scroll") ?? false
                    onToggled: on => KdeInput.setDevice(dev.modelData.id, "natural-scroll", on)
                }
            }

            SettingsRow {
                visible: page.kde && dev.has("scroll-factor")
                label: "Scrolling speed"
                SettingsSlider {
                    from: 0.1
                    to: 3
                    step: 0.1
                    value: KdeInput.value(dev.modelData.id, "scroll-factor") ?? 1
                    format: v => Math.abs(v - 1) < 0.001 ? "default" : `${v.toFixed(1)}×`
                    onCommitted: v => KdeInput.setDevice(dev.modelData.id, "scroll-factor", Math.round(v * 10) / 10)
                }
            }

            Repeater {
                model: page.kde ? dev.modelData.kdeExtra : []
                delegate: SettingsRow {
                    id: kflag
                    required property string modelData
                    visible: dev.has(modelData)
                    label: page.kdeLabels[modelData] ?? modelData
                    SettingsSwitch {
                        checked: KdeInput.value(dev.modelData.id, kflag.modelData) ?? false
                        onToggled: on => KdeInput.setDevice(dev.modelData.id, kflag.modelData, on)
                    }
                }
            }
        }
    }

    Text {
        Layout.fillWidth: true
        visible: text !== ""
        text: page.kde ? KdeInput.error : NiriSettings.error
        color: Theme.urgent
        font.family: Theme.fontUi
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }
}
