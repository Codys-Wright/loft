import QtQuick
import QtQuick.Layouts
import qs.services

// Settings → Layout & Motion: gaps, column widths, struts, animations.
// Theme-owned looks (focus ring, borders, shadows, radius) live in the theme.
// Under niri all of it is niri's. Under KWin (no columns) the page is KWin's
// motion instead: KDE's animation speed and KWin's effects, through
// KdeMotion (docs/KWIN.md §4.21).
ColumnLayout {
    id: page
    spacing: 12
    readonly property bool niri: Compositor.backend === "niri"
    readonly property bool kde: Compositor.backend === "kwin"

    // KDE's speed steps (slow → instant), as names.
    readonly property var speedNames: ["Slowest", "Slow", "Relaxed", "Normal", "Quick", "Fast", "Instant"]

    SettingsCard {
        visible: page.kde
        PageHeader {
            title: "Motion"
        }

        SettingsRow {
            label: "Animation speed"
            hint: "Every KWin animation, and KDE apps' own. Instant turns them off"
            SettingsSlider {
                from: 0
                to: KdeMotion.steps.length - 1
                step: 1
                value: KdeMotion.stepIndex(KdeMotion.speed)
                format: v => page.speedNames[Math.round(v)] ?? ""
                onCommitted: v => {
                    const f = KdeMotion.steps[Math.round(v)];
                    if (f !== undefined && f !== KdeMotion.speed)
                        KdeMotion.setSpeed(f);
                }
            }
        }

        Repeater {
            model: KdeMotion.choicesIn("animations")
            delegate: KdeChoiceRow {
                enabled: KdeMotion.speed > 0
            }
        }
    }

    SettingsCard {
        visible: page.kde && KdeMotion.togglesIn("effects").length > 0
        PageHeader {
            title: "Effects"
        }
        Repeater {
            model: KdeMotion.togglesIn("effects")
            delegate: KdeToggleRow {}
        }
        Text {
            Layout.fillWidth: true
            text: "Popup fades are off while Loft runs: Loft animates its own menus, and KDE's setting comes back when Loft stops."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }
    }

    SettingsCard {
        visible: page.kde && KdeMotion.togglesIn("windows").length > 0
        PageHeader {
            title: "Window overviews"
        }
        Repeater {
            model: KdeMotion.togglesIn("windows")
            delegate: KdeToggleRow {}
        }
    }

    SettingsCard {
        visible: page.kde && (KdeMotion.choicesIn("accessibility").length + KdeMotion.togglesIn("accessibility").length) > 0
        PageHeader {
            title: "Accessibility"
        }
        Repeater {
            model: KdeMotion.choicesIn("accessibility")
            delegate: KdeChoiceRow {}
        }
        Repeater {
            model: KdeMotion.togglesIn("accessibility")
            delegate: KdeToggleRow {}
        }
    }

    Text {
        Layout.fillWidth: true
        visible: page.kde && KdeMotion.error !== ""
        text: KdeMotion.error
        color: Theme.urgent
        font.family: Theme.fontUi
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }

    // One of KWin's exclusive groups: a segmented choice with None, or a
    // switch when the group has one effect (maximize, full screen).
    // modelData: the group's id; its state comes from KdeMotion.
    component KdeChoiceRow: SettingsRow {
        id: choiceRow
        required property string modelData
        readonly property var c: KdeMotion.choice(modelData)
        readonly property var opts: c?.options ?? []
        label: c?.label ?? ""
        hint: c?.hint ?? ""
        // Off (Instant): the controls dim themselves.
        SettingsSegmented {
            visible: choiceRow.opts.length > 1
            options: [{ value: "none", label: "None" }].concat(choiceRow.opts.map(o => ({ value: o.id, label: o.label })))
            current: choiceRow.c?.current
            onActivated: v => KdeMotion.choose(choiceRow.modelData, v)
        }
        SettingsSwitch {
            visible: choiceRow.opts.length === 1
            checked: (choiceRow.c?.current ?? "none") !== "none"
            onToggled: on => KdeMotion.choose(choiceRow.modelData, on ? choiceRow.opts[0].id : "none")
        }
    }

    // modelData: the effect's id.
    component KdeToggleRow: SettingsRow {
        id: toggleRow
        required property string modelData
        readonly property var t: KdeMotion.toggle(modelData)
        label: t?.label ?? ""
        hint: t?.hint ?? ""
        SettingsSwitch {
            checked: toggleRow.t?.on ?? false
            onToggled: on => KdeMotion.setEffect(toggleRow.modelData, on)
        }
    }

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
        visible: page.niri
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
        visible: page.niri
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
        visible: page.niri
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
        visible: page.niri && NiriSettings.error !== ""
        text: NiriSettings.error
        color: Theme.urgent
        font.family: Theme.fontUi
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }
}
