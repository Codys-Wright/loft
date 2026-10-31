import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services
import qs.settings

// Disks & Sensors → Fan control: every hwmon pwm output from services/Fans.qml.
// A writable one (with programs.loft.fanControl on) can run Automatic, at a
// Manual speed or on a Curve following a temperature; the rest show read-only
// with why. Every change runs `loft fans …` (the pkexec helper).
SettingsCard {
    id: card
    spacing: 14
    visible: Fans.status !== null

    function sourceOf(f) {
        return Fans.tempId(f.setting.source ?? "") || Fans.defaultSource;
    }

    PageHeader {
        title: "Fan control"
        SettingsButton {
            visible: Fans.fans.some(f => f.setting.mode !== "auto")
            enabled: !Fans.busy
            text: "All automatic"
            icon: "󰑐"
            onClicked: Fans.run(["loft", "fans", "reset"])
        }
    }

    Text {
        Layout.fillWidth: true
        text: !Fans.enabled ? "Read-only: fan control is off on this machine. Turn it on with programs.loft.fanControl.enable in the NixOS config (it installs the helper, its service and polkit rule)." : Fans.fans.length === 0 ? "No fan here has a speed output (pwm) Linux can drive — NVIDIA cards and many laptops don't expose one — so fan speeds are read-only." : `Speeds never go under ${Fans.minPercent}%${Fans.allowStop ? " unless a fan may stop" : ""}; at ${Fans.criticalTemp} °C every controlled fan runs at 100%. Fans go back to automatic when the service stops or the machine sleeps.`
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }

    Text {
        Layout.fillWidth: true
        visible: Fans.enabled && !Fans.daemon
        text: "The loft-fans service isn't running, so settings aren't applied (systemctl status loft-fans)."
        color: Theme.warn
        font.family: Theme.fontUi
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }

    Text {
        Layout.fillWidth: true
        visible: Fans.error !== ""
        text: Fans.error
        color: Theme.urgent
        font.family: Theme.fontUi
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }

    Repeater {
        model: Fans.fans

        delegate: ColumnLayout {
            id: fan
            required property var modelData
            readonly property bool controllable: Fans.enabled && modelData.writable
            readonly property var setting: modelData.setting
            readonly property string mode: setting.mode
            readonly property var applied: modelData.applied ?? null
            readonly property bool stop: setting.stop === true
            Layout.fillWidth: true
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Icon {
                    text: "󰈐"
                    size: 16
                    color: fan.applied?.critical ? Theme.urgent : fan.controllable ? Theme.accent : Theme.subtext
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                        text: fan.modelData.label
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                        font.weight: Font.Medium
                    }
                    Text {
                        Layout.fillWidth: true
                        text: `${fan.modelData.chip} · ${fan.modelData.id}` + (fan.modelData.writable ? "" : " · read-only (the driver doesn't take writes)")
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 10
                        elide: Text.ElideRight
                    }
                }
                Text {
                    text: [fan.modelData.percent !== null ? `${fan.modelData.percent}%` : "", fan.modelData.rpm !== null ? `${fan.modelData.rpm} RPM` : ""].filter(s => s).join(" · ")
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                    font.weight: Font.Medium
                    font.features: {
                        "tnum": 1
                    }
                }
            }

            SettingsRow {
                visible: fan.controllable
                Layout.leftMargin: 26
                label: "Control"
                hint: fan.applied?.error ?? (fan.applied?.critical ? "Critical temperature: running at 100%" : "")
                hintColor: fan.applied?.error || fan.applied?.critical ? Theme.urgent : Theme.subtext
                SettingsSegmented {
                    enabled: !Fans.busy
                    options: [
                        {
                            value: "auto",
                            label: "Automatic"
                        },
                        {
                            value: "manual",
                            label: "Manual"
                        },
                        {
                            value: "curve",
                            label: "Curve"
                        }
                    ]
                    current: fan.mode
                    onActivated: v => {
                        if (v === fan.mode)
                            return;
                        if (v === "auto")
                            Fans.setAuto(fan.modelData);
                        else if (v === "manual")
                            Fans.setManual(fan.modelData, Math.max(Fans.minPercent, fan.modelData.percent ?? 50), false);
                        else if (Fans.defaultSource !== "")
                            Fans.setCurve(fan.modelData, Fans.defaultSource, Fans.presets.balanced, false);
                    }
                }
            }

            SettingsRow {
                visible: fan.controllable && fan.mode === "manual"
                Layout.leftMargin: 26
                label: "Speed"
                SettingsSlider {
                    enabled: !Fans.busy
                    from: Fans.allowStop && fan.stop ? 0 : Fans.minPercent
                    to: 100
                    step: 1
                    suffix: "%"
                    value: fan.setting.percent ?? 50
                    onCommitted: v => Fans.setManual(fan.modelData, v, fan.stop)
                }
            }

            SettingsRow {
                visible: fan.controllable && fan.mode === "curve"
                Layout.leftMargin: 26
                label: "Follows"
                hint: typeof fan.applied?.temp === "number" ? `${fan.applied.temp.toFixed(0)} °C now` : ""
                SettingsSelect {
                    enabled: !Fans.busy
                    options: Fans.temps.map(t => ({
                                value: t.id,
                                label: `${t.chip} · ${t.label}`
                            }))
                    current: Fans.tempId(fan.setting.source ?? "")
                    onActivated: v => Fans.setCurve(fan.modelData, v, fan.setting.points, fan.stop)
                }
            }

            SettingsRow {
                visible: fan.controllable && fan.mode === "curve"
                Layout.leftMargin: 26
                label: "Preset"
                hint: "Then drag the points"
                SettingsSegmented {
                    enabled: !Fans.busy
                    options: [
                        {
                            value: "quiet",
                            label: "Quiet"
                        },
                        {
                            value: "balanced",
                            label: "Balanced"
                        },
                        {
                            value: "performance",
                            label: "Performance"
                        }
                    ]
                    current: Object.keys(Fans.presets).find(k => JSON.stringify(Fans.presets[k]) === JSON.stringify(fan.setting.points)) ?? ""
                    onActivated: v => Fans.setCurve(fan.modelData, card.sourceOf(fan.modelData), Fans.presets[v], fan.stop)
                }
            }

            FanCurve {
                visible: fan.controllable && fan.mode === "curve"
                enabled: !Fans.busy
                Layout.fillWidth: true
                Layout.leftMargin: 26
                points: fan.setting.points ?? []
                floor: fan.stop ? 0 : Fans.minPercent
                critical: Fans.criticalTemp
                temp: fan.applied?.temp ?? -1
                applied: fan.applied?.percent ?? -1
                onCommitted: pts => Fans.setCurve(fan.modelData, card.sourceOf(fan.modelData), pts, fan.stop)
            }

            SettingsRow {
                visible: fan.controllable && Fans.allowStop && fan.mode !== "auto"
                Layout.leftMargin: 26
                label: "Allow stopping"
                hint: "0% stops this fan instead of running it at the floor"
                SettingsSwitch {
                    enabled: !Fans.busy
                    checked: fan.stop
                    onToggled: on => {
                        const s = fan.setting;
                        if (fan.mode === "manual")
                            Fans.setManual(fan.modelData, on ? s.percent : Math.max(Fans.minPercent, s.percent), on);
                        else
                            Fans.setCurve(fan.modelData, card.sourceOf(fan.modelData), on ? s.points : s.points.map(p => [p[0], Math.max(p[1], Fans.minPercent)]), on);
                    }
                }
            }
        }
    }
}
