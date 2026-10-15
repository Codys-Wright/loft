import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Transparency and Blur (Settings → Appearance, mirrored at the top of
// Window Rules): one master dial from Solid to Clear that moves window
// opacity, terminal backgrounds, GTK glass and the shell's own glass
// together, and one from Frosted to Clear (no blur) for niri's blur. Under
// Advanced, each value the master dial drives, overridable one by one
// (Transparency.qml has the plumbing, cli/loft/render/look.py the curves).
SettingsCard {
    id: card

    property bool showAdvanced: true
    property bool advancedOpen: false

    function pct(v) {
        return Math.round(v * 100) + "%";
    }

    PageHeader {
        title: "Transparency and Blur"
        Text {
            visible: Transparency.anySet
            text: "Reset to Theme"
            color: Theme.accent
            font.family: Theme.fontUi
            font.pixelSize: 12
            MouseArea {
                anchors.fill: parent
                anchors.margins: -4
                cursorShape: Qt.PointingHandCursor
                onClicked: Transparency.resetAll()
            }
        }
    }

    SettingsRow {
        label: "Transparency"
        hint: Transparency.reduced ? "Off with Reduce transparency" : `Solid … Clear · windows, terminals, Files and the shell's glass together${Transparency.levelSet ? "" : " · following the theme"}`
        enabled: !Transparency.reduced
        SettingsSlider {
            implicitWidth: 280
            from: 0
            to: 1
            step: 0.01
            value: Transparency.level
            format: v => v <= 0.01 ? "Solid" : v >= 0.99 ? "Clear" : Math.abs(v - 0.5) < 0.006 ? "Theme" : card.pct(v)
            onMoved: v => Transparency.setLevel(v)
            onCommitted: v => Transparency.setLevel(v)
        }
    }

    // Left Frosted, right Clear: the slider shows 1 − strength.
    SettingsRow {
        label: "Blur"
        hint: Transparency.reduced ? "Off with Reduce transparency" : `Frosted … Clear (no blur; windows stay see-through)${Transparency.blurSet ? "" : " · following the theme"}`
        enabled: !Transparency.reduced
        SettingsSlider {
            implicitWidth: 280
            from: 0
            to: 1
            step: 0.01
            value: 1 - Transparency.blur
            format: v => v >= 0.99 ? "Clear" : v <= 0.01 ? "Frosted" : Math.abs((1 - v) - (Transparency.themeVals.blur ?? 0.5)) < 0.006 ? "Theme" : card.pct(1 - v)
            onMoved: v => Transparency.setBlur(1 - v)
            onCommitted: v => Transparency.setBlur(1 - v)
        }
    }

    Text {
        Layout.fillWidth: true
        visible: Transparency.error !== ""
        text: Transparency.error
        color: Theme.warn
        font.family: Theme.fontUi
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }

    // ── Advanced ────────────────────────────────────────────────────────
    RowLayout {
        visible: card.showAdvanced
        Layout.fillWidth: true
        spacing: 6
        Icon {
            text: card.advancedOpen ? "󰅀" : "󰅂"
            size: 12
            color: Theme.subtext
        }
        Text {
            Layout.fillWidth: true
            text: "Advanced"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 12
            font.weight: Font.DemiBold
        }
        TapHandler {
            onTapped: card.advancedOpen = !card.advancedOpen
        }
        HoverHandler {
            cursorShape: Qt.PointingHandCursor
        }
    }

    // A value the master dial drives, with its own override.
    component Override: SettingsRow {
        id: ov
        property bool overridden: false
        property real from: 0.2
        property real value: 1
        property string followText: "Following Transparency"
        signal picked(real v)
        signal follow
        hint: overridden ? "Yours" : followText
        Text {
            visible: ov.overridden
            text: "Follow"
            color: Theme.accent
            font.family: Theme.fontUi
            font.pixelSize: 12
            MouseArea {
                anchors.fill: parent
                anchors.margins: -4
                cursorShape: Qt.PointingHandCursor
                onClicked: ov.follow()
            }
        }
        SettingsSlider {
            implicitWidth: 220
            from: ov.from
            to: 1
            step: 0.01
            value: ov.value
            format: v => card.pct(v)
            onCommitted: v => ov.picked(Math.round(v * 100) / 100)
        }
    }

    ColumnLayout {
        visible: card.showAdvanced && card.advancedOpen
        Layout.fillWidth: true
        spacing: 12

        Override {
            label: "Focused window"
            from: 0.3
            enabled: WindowRules.enabled && !Transparency.reduced
            overridden: WindowRules.userGlass.focused !== undefined
            value: WindowRules.glass.focused ?? 0.9
            followText: `Following Transparency · niri fades the whole window, text too`
            onPicked: v => WindowRules.setGlass({ focused: v })
            onFollow: WindowRules.setGlass({ focused: null })
        }
        Override {
            label: "Other windows"
            from: 0.3
            enabled: WindowRules.enabled && !Transparency.reduced
            overridden: WindowRules.userGlass.unfocused !== undefined
            value: WindowRules.glass.unfocused ?? 0.8
            onPicked: v => WindowRules.setGlass({ unfocused: v })
            onFollow: WindowRules.setGlass({ unfocused: null })
        }
        Override {
            label: "Shell glass"
            from: 0
            enabled: !Theme.reduceTransparency
            overridden: Settings.appearance.glass >= 0
            value: Theme.glass
            followText: "Following Transparency · menus, panels, dock, Control Center (Liquid Glass)"
            onPicked: v => {
                Settings.appearance.glass = v;
                Theme.glassPreview = -1;
            }
            onFollow: Settings.appearance.glass = -1
        }
        Override {
            label: "Terminal background"
            from: 0.2
            enabled: !Transparency.reduced
            overridden: Transparency.terminalsSet
            value: Transparency.terminals
            followText: `Following Transparency · theme ${card.pct(Transparency.themeVals.terminals ?? 0.85)} · text stays opaque`
            onPicked: v => Transparency.set("terminals", v)
            onFollow: Transparency.set("terminals", null)
        }
        Override {
            label: "File manager glass (Files, Dolphin)"
            from: 0.2
            enabled: !Transparency.reduced
            overridden: Transparency.gtkSet
            value: Transparency.gtk
            followText: `Following Transparency · theme ${card.pct(Transparency.themeVals.gtk ?? 0.63)} · Files and Dolphin read it when they start`
            onPicked: v => Transparency.set("gtk", v)
            onFollow: Transparency.set("gtk", null)
        }

        Text {
            Layout.fillWidth: true
            text: "Transparency moves each of these from the theme's value (the middle of the slider) toward opaque or toward its clearest: windows ease in and stop at 55 % (focused) and 40 % (others) — clearer is an override away here, since niri fades their text too; terminal backgrounds go to 30 % (their text stays opaque); GTK glass to 30 %. Windows kept opaque in Window Rules stay opaque."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }
    }
}
