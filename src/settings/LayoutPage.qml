import QtQuick
import QtQuick.Layouts
import qs.services

// Settings → Layout & Motion: gaps, column widths, struts, animations.
// Theme-owned looks (focus ring, borders, shadows, radius) live in the theme.
ColumnLayout {
    id: page
    spacing: 12


    function sizeLabel(s) {
        if (typeof s === "number")
            return `${Math.round(s * 100)}%`;
        if (s && s.fixed !== undefined)
            return `${s.fixed} px`;
        return "window decides";
    }

    // Proportions as the user types them: "33%, 50%, 1200px" or "0.5".
    function parseSizes(text) {
        const out = [];
        for (const raw of text.split(/[,\s]+/)) {
            const t = raw.trim();
            if (t === "")
                continue;
            if (t.endsWith("px"))
                out.push({ fixed: parseInt(t) });
            else if (t.endsWith("%"))
                out.push(parseFloat(t) / 100);
            else
                out.push(parseFloat(t));
        }
        return out.filter(v => typeof v === "object" ? !isNaN(v.fixed) : !isNaN(v) && v > 0 && v <= 1);
    }

    SettingsCard {
        PageHeader {
            title: "Windows"
            SettingsButton {
                visible: NiriSettings.anyOverridden("layout.")
                text: "Reset"
                onClicked: NiriSettings.unset("layout")
            }
        }

        NiriRow {
            key: "layout.gaps"
            extraHint: "Between and around windows"
            SettingsSlider {
                from: 0
                to: 48
                step: 1
                suffix: " px"
                value: NiriSettings.value("layout.gaps") ?? 16
                onCommitted: v => NiriSettings.set("layout.gaps", Math.round(v))
            }
        }

        NiriRow {
            key: "layout.default-column-width"
            extraHint: "New windows open this wide"
            SettingsSegmented {
                readonly property var v: NiriSettings.value("layout.default-column-width")
                options: [
                    { value: 0.33333, label: "⅓" },
                    { value: 0.5, label: "½" },
                    { value: 0.66667, label: "⅔" },
                    { value: 1, label: "Full" }
                ]
                current: typeof v === "number" ? options.map(o => o.value).find(o => Math.abs(o - v) < 0.01) : undefined
                onActivated: val => NiriSettings.set("layout.default-column-width", val)
            }
        }

        NiriRow {
            key: "layout.preset-column-widths"
            extraHint: "Mod+W cycles through these"
            SettingsTextField {
                implicitWidth: 220
                text: (NiriSettings.value("layout.preset-column-widths") ?? []).map(page.sizeLabel).join(", ")
                placeholder: "33%, 50%, 67%"
                onCommitted: t => {
                    const sizes = page.parseSizes(t);
                    if (sizes.length > 0)
                        NiriSettings.set("layout.preset-column-widths", sizes);
                }
            }
        }

        NiriRow {
            key: "layout.center-focused-column"
            SettingsSegmented {
                options: [
                    { value: "never", label: "Never" },
                    { value: "on-overflow", label: "On overflow" },
                    { value: "always", label: "Always" }
                ]
                current: NiriSettings.value("layout.center-focused-column") ?? "never"
                onActivated: v => NiriSettings.set("layout.center-focused-column", v)
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: "Struts"
        }

        Text {
            Layout.fillWidth: true
            text: "Reserved space at the screen edges that windows don't cover (on top of the bar and dock)."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Repeater {
            model: ["top", "bottom", "left", "right"]
            delegate: NiriRow {
                id: strut
                required property string modelData
                key: `layout.struts.${modelData}`
                SettingsSlider {
                    from: 0
                    to: 200
                    step: 2
                    suffix: " px"
                    value: NiriSettings.value(strut.key) ?? 0
                    onCommitted: v => NiriSettings.set(strut.key, Math.round(v))
                }
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: "Motion"
            SettingsButton {
                visible: NiriSettings.anyOverridden("animations.")
                text: "Reset"
                onClicked: NiriSettings.unset("animations")
            }
        }

        NiriRow {
            key: "animations.off"
            label: "Animations"
            extraHint: "Window, workspace and overview animations"
            SettingsSwitch {
                checked: !(NiriSettings.value("animations.off") ?? false)
                onToggled: on => NiriSettings.set("animations.off", !on)
            }
        }

        NiriRow {
            key: "animations.slowdown"
            label: "Animation speed"
            extraHint: "Slower ← → faster"
            enabled: !(NiriSettings.value("animations.off") ?? false)
            opacity: enabled ? 1 : 0.5
            // niri's slowdown multiplies durations; show it as a speed.
            SettingsSlider {
                from: -2
                to: 2
                step: 0.1
                // log2(slowdown), inverted: right = faster
                value: -Math.log2(NiriSettings.value("animations.slowdown") ?? 1)
                format: v => `${(1 / Math.pow(2, -v)).toFixed(2)}×`
                onCommitted: v => NiriSettings.set("animations.slowdown", Math.round(Math.pow(2, -v) * 100) / 100)
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
