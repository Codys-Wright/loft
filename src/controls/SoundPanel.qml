import QtQuick
import QtQuick.Layouts
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import qs.audio
import qs.components
import qs.services

// Sound (macOS's Sound menu): output volume, the outputs (Bluetooth ones
// with battery), the mixer. ⌥ (details): inputs with the mic level, and the
// PipeWire graph clock — rate and quantum with quick switching (Auto clears
// the force). Shared by the bar dropdown and the CC's expanded Sound module.
ColumnLayout {
    id: root

    property bool details: false
    property bool shown: true
    property bool inMenu: true
    property string screenName: ""
    signal dismiss
    signal openSettings(string section)

    spacing: 0

    readonly property PwNode sink: Sound.defaultSink
    readonly property bool ready: sink?.ready ?? false

    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }

    // Bluetooth battery for an output (PipeWire node ↔ BlueZ device by address).
    function btBattery(n) {
        const addr = n?.properties["api.bluez5.address"] ?? "";
        if (!addr)
            return "";
        const d = Bluetooth.devices.values.find(x => x.address === addr);
        return d && d.batteryAvailable ? `${Math.round(d.battery * 100)}%` : "";
    }

    // The clock is read only while it's on screen.
    readonly property bool clockShown: details && shown && Features.on("soundControl")
    onClockShownChanged: PwClock.watching += clockShown ? 1 : -1
    Component.onCompleted: if (clockShown)
        PwClock.watching += 1
    Component.onDestruction: if (clockShown)
        PwClock.watching -= 1

    // A level meter opens a capture stream: only with Settings → Sound →
    // level meters on, or after asking here.
    property bool levelAsked: false
    onShownChanged: if (!shown)
        levelAsked = false

    PanelHeader {
        title: "Sound"
        trailing: root.ready ? `${Math.round(root.sink.audio.volume * 100)}%` : ""
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 10
        Layout.rightMargin: 10
        Layout.bottomMargin: 6
        spacing: 8

        Icon {
            text: !root.ready || root.sink.audio.muted ? "󰝟" : "󰕿"
            size: 14
            color: Theme.subtext
            MouseArea {
                anchors.fill: parent
                anchors.margins: -4
                cursorShape: Qt.PointingHandCursor
                onClicked: if (root.ready)
                    root.sink.audio.muted = !root.sink.audio.muted
            }
        }
        VolumeSlider {
            Layout.fillWidth: true
            value: root.ready ? root.sink.audio.volume : 0
            dimmed: !root.ready || root.sink.audio.muted
            onMoved: v => {
                if (root.ready)
                    root.sink.audio.volume = v;
            }
        }
        Icon {
            text: "󰕾"
            size: 14
            color: Theme.subtext
        }
    }

    PanelSection {
        text: "Output"
    }

    Repeater {
        model: Sound.sinks
        delegate: PanelRow {
            required property var modelData
            text: Sound.label(modelData)
            detail: root.details ? (modelData.name ?? "") : ""
            glyph: Sound.outputIcon(modelData)
            glyphActive: modelData.id === root.sink?.id
            trailing: root.btBattery(modelData)
            onClicked: Sound.setDefaultSink(modelData)
        }
    }

    // ── ⌥: inputs + level ────────────────────────────────────────────────
    PanelSection {
        visible: root.details
        text: "Input"
    }
    Repeater {
        model: root.details ? Sound.sources : []
        delegate: PanelRow {
            required property var modelData
            text: Sound.label(modelData)
            glyph: Sound.inputIcon(modelData)
            glyphActive: modelData.id === Sound.defaultSource?.id
            trailing: modelData.ready && modelData.audio.muted ? "Muted" : ""
            onClicked: Sound.setDefaultSource(modelData)
        }
    }
    RowLayout {
        visible: root.details && Sound.defaultSource !== null
        Layout.fillWidth: true
        Layout.leftMargin: 10
        Layout.rightMargin: 10
        Layout.topMargin: 2
        Layout.bottomMargin: 4
        spacing: 8

        Text {
            text: "Level"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
        LevelMeter {
            Layout.fillWidth: true
            visible: Settings.sound.meters || root.levelAsked
            node: Sound.defaultSource
            active: visible && root.shown && root.details
        }
        PanelButton {
            visible: !Settings.sound.meters && !root.levelAsked
            text: "Show level"
            onClicked: root.levelAsked = true
        }
    }

    // ── ⌥: the graph clock ───────────────────────────────────────────────
    PanelSection {
        visible: root.details
        text: "Clock"
        trailing: PwClock.ready ? `${PwClock.rateLabel(PwClock.effectiveRate)} · ${PwClock.effectiveQuantum} · ${PwClock.latencyMs.toFixed(1)} ms` : "…"
    }
    GridLayout {
        visible: root.details && PwClock.ready
        Layout.fillWidth: true
        Layout.leftMargin: 10
        Layout.rightMargin: 10
        Layout.bottomMargin: 4
        columns: 2
        columnSpacing: 8
        rowSpacing: 5

        Text {
            text: "Rate"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
        PanelSegmented {
            options: [{ value: 0, label: "Auto" }].concat(PwClock.rates.map(r => ({ value: r, label: String(r / 1000) })))
            current: PwClock.forceRate
            onPicked: v => PwClock.setRate(v)
        }
        Text {
            text: "Buffer"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
        PanelSegmented {
            options: [{ value: 0, label: "Auto" }].concat(PwClock.quanta.map(q => ({ value: q, label: String(q) })))
            current: PwClock.forceQuantum
            onPicked: v => PwClock.setQuantum(v)
        }
    }

    PanelSeparator {}
    PanelRow {
        visible: Features.on("mixer")
        text: "Mixer"
        trailingGlyph: "󰅂"
        onClicked: {
            root.dismiss();
            Sound.openMixer(root.screenName);
        }
    }
    PanelRow {
        text: "Sound Settings…"
        onClicked: root.openSettings("sound")
    }
}
