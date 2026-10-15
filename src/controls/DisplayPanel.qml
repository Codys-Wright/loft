import QtQuick
import QtQuick.Layouts
import qs.audio
import qs.components
import qs.services

// Display: brightness (all displays, then each one), Night Light, the
// Transparency dial (Solid … Clear: windows, terminals, Files and the
// shell's glass together; Transparency.qml), and Dark / Light appearance when the active theme has a counterpart of the
// other polarity installed (same family name: "foo" ↔ "foo-day",
// "x-light" ↔ "x-dark", "catppuccin-latte" ↔ "catppuccin-mocha" …).
ColumnLayout {
    id: root

    property bool details: false
    property bool shown: true
    property bool inMenu: true
    signal dismiss
    signal openSettings(string section)

    spacing: 0

    onShownChanged: if (shown)
        Brightness.refresh()
    Component.onCompleted: {
        Brightness.refresh();
        if (ThemeManager.themes.length === 0)
            ThemeManager.refresh();
    }

    // ── Appearance counterpart ───────────────────────────────────────────
    function family(name) {
        return name.replace(/[-_.](light|dark|day|night|latte|mocha|frappe|macchiato|storm|moon|dawn|dusk)$/, "");
    }
    readonly property var themes: ThemeManager.themes
    readonly property var currentTheme: themes.find(t => t.name === Theme.name) ?? null
    readonly property var counterpart: {
        if (!currentTheme)
            return null;
        const fam = family(currentTheme.name);
        return themes.find(t => t.name !== currentTheme.name && family(t.name) === fam && (t.polarity ?? "dark") !== (currentTheme.polarity ?? "dark")) ?? null;
    }

    PanelHeader {
        title: "Display"
    }

    component BrightnessLine: RowLayout {
        id: line
        property string label
        property real value
        signal moved(real v)
        Layout.fillWidth: true
        Layout.leftMargin: 10
        Layout.rightMargin: 10
        Layout.bottomMargin: 6
        spacing: 8
        Icon {
            text: "󰃞"
            size: 14
            color: Theme.subtext
        }
        VolumeSlider {
            Layout.fillWidth: true
            value: line.value
            onMoved: v => line.moved(v)
        }
        Icon {
            text: "󰃠"
            size: 14
            color: Theme.subtext
        }
    }

    BrightnessLine {
        visible: Brightness.available
        value: Brightness.value
        onMoved: v => Brightness.setAll(v)
    }
    PanelRow {
        visible: !Brightness.available
        enabled: false
        dim: true
        text: Brightness.probing ? "Looking for displays…" : "Brightness isn't adjustable here"
    }

    // Per display (more than one).
    Repeater {
        model: Brightness.displays.length > 1 ? Brightness.displays : []
        delegate: ColumnLayout {
            required property var modelData
            Layout.fillWidth: true
            spacing: 0
            PanelSection {
                text: modelData.name
                trailing: `${Math.round(modelData.value * 100)}%`
            }
            BrightnessLine {
                value: parent.modelData.value
                onMoved: v => Brightness.set(parent.modelData.key, v)
            }
        }
    }

    PanelSeparator {}

    PanelRow {
        text: "Night Light"
        detail: NightLight.enabled ? `${NightLight.temperature}K` : ""
        glyph: "󰖔"
        glyphActive: NightLight.enabled
        onClicked: NightLight.enabled = !NightLight.enabled
    }

    PanelSection {
        text: "Transparency"
        trailing: Transparency.reduced ? "Reduced" : Transparency.level <= 0.01 ? "Solid" : Transparency.level >= 0.99 ? "Clear" : Math.abs(Transparency.level - 0.5) < 0.006 ? "Theme" : `${Math.round(Transparency.level * 100)}%`
    }
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 10
        Layout.rightMargin: 10
        Layout.bottomMargin: 6
        spacing: 8
        enabled: !Transparency.reduced
        opacity: enabled ? 1 : 0.4
        Icon {
            text: "󰝤"
            size: 14
            color: Theme.subtext
        }
        VolumeSlider {
            Layout.fillWidth: true
            value: Transparency.level
            onMoved: v => Transparency.setLevel(v)
        }
        Icon {
            text: "󰝣"
            size: 14
            color: Theme.subtext
        }
    }

    PanelSection {
        visible: root.counterpart !== null
        text: "Appearance"
    }
    PanelSegmented {
        visible: root.counterpart !== null
        Layout.leftMargin: 10
        Layout.rightMargin: 10
        Layout.bottomMargin: 4
        options: [{ value: "light", label: "Light" }, { value: "dark", label: "Dark" }]
        current: Theme.dark ? "dark" : "light"
        onPicked: v => {
            if ((v === "dark") !== Theme.dark && root.counterpart)
                ThemeManager.apply(root.counterpart.name);
        }
    }

    PanelSeparator {}
    PanelRow {
        text: "Displays Settings…"
        onClicked: root.openSettings("displays")
    }
}
