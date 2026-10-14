import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Bluetooth
import Quickshell.Networking
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import qs.audio
import qs.components
import qs.services

// macOS-style Control Center: toggles, now playing, volume and a calendar,
// sliding in under the bar on the right. Click outside to close.
// Layout and tile design ported from javiiervm/dotfiles; services are
// Quickshell's native NetworkManager / BlueZ / PipeWire / UPower / MPRIS.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property bool shown: Panels.controlCenterOpen && Panels.controlCenterScreen === modelData.name

    visible: shown || slide.running
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "studio:controlcenter"
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    readonly property int panelWidth: 400
    readonly property int gap: 10
    readonly property int tileHeight: 58

    // One glass panel (like macOS); blur only once it has slid into place.
    BackgroundEffect.blurRegion: Theme.blur && shown && !slide.running ? blur : null
    Region {
        id: blur
        item: backing
        radius: backing.radius
    }

    // Anywhere outside the panel closes it.
    MouseArea {
        anchors.fill: parent
        onClicked: Panels.controlCenterOpen = false
    }

    Item {
        id: panel
        width: root.panelWidth
        height: tiles.implicitHeight + 2 * root.gap
        anchors {
            top: parent.top
            right: parent.right
            topMargin: 50
            rightMargin: 12
        }
        opacity: root.shown ? 1 : 0

        transform: Translate {
            x: root.shown ? 0 : root.panelWidth + 30
            Behavior on x {
                NumberAnimation {
                    id: slide
                    duration: 320
                    easing.type: Easing.OutQuart
                }
            }
        }
        Behavior on opacity {
            NumberAnimation {
                duration: 220
            }
        }

        GlassSurface {
            id: backing
            anchors.fill: parent
            radius: 28
        }

        // Swallow clicks on the panel itself.
        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            id: tiles
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: root.gap
            }
            spacing: root.gap

            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: root.gap
                rowSpacing: root.gap

                ToggleTile {
                    id: network
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.tileHeight

                    readonly property var devices: Networking.devices.values
                    readonly property var wifi: devices.find(d => d.type === DeviceType.Wifi) ?? null
                    readonly property var wired: devices.find(d => d.type === DeviceType.Wired && d.connected) ?? null
                    readonly property var wifiNet: wifi ? wifi.networks.values.find(n => n.connected) ?? null : null

                    icon: wired ? "󰈀" : "󰖩"
                    title: wired ? "Ethernet" : "Wi-Fi"
                    active: wired !== null || (Networking.wifiEnabled && wifiNet !== null)
                    available: wired !== null || wifi !== null
                    subtitle: wired ? (wired.name || "Connected") : !Networking.wifiEnabled ? "Off" : wifiNet ? wifiNet.name : "Not connected"
                    onClicked: if (wifi)
                        Networking.wifiEnabled = !Networking.wifiEnabled
                }

                ToggleTile {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.tileHeight

                    readonly property var adapter: Bluetooth.defaultAdapter
                    readonly property var device: adapter ? adapter.devices.values.find(d => d.connected) ?? null : null

                    icon: "󰂯"
                    title: "Bluetooth"
                    available: adapter !== null
                    active: adapter?.enabled ?? false
                    subtitle: !adapter ? "Unavailable" : !adapter.enabled ? "Off" : device ? device.name : "On"
                    onClicked: adapter.enabled = !adapter.enabled
                }

                ToggleTile {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.tileHeight
                    icon: "󰂛"
                    title: "Do Not Disturb"
                    active: Panels.doNotDisturb
                    subtitle: active ? "On" : "Off"
                    onClicked: Panels.doNotDisturb = !Panels.doNotDisturb
                }

                ToggleTile {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.tileHeight
                    icon: "󰅶"
                    title: "Caffeine"
                    active: Panels.caffeine
                    subtitle: active ? "Staying awake" : "Off"
                    onClicked: Panels.caffeine = !Panels.caffeine
                }

                ToggleTile {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.tileHeight
                    icon: "󰖔"
                    title: "Night Light"
                    active: NightLight.enabled
                    subtitle: active ? `${NightLight.temperature}K` : "Off"
                    onClicked: NightLight.enabled = !NightLight.enabled
                }

                ToggleTile {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.tileHeight

                    readonly property var profile: PowerProfiles.profile
                    readonly property var order: [PowerProfile.PowerSaver, PowerProfile.Balanced, PowerProfile.Performance]

                    icon: profile === PowerProfile.Performance ? "󰓅" : profile === PowerProfile.PowerSaver ? "󰌪" : "󰾅"
                    title: "Power Mode"
                    active: profile !== PowerProfile.Balanced
                    subtitle: PowerProfile.toString(profile)
                    onClicked: {
                        const i = order.indexOf(profile);
                        let next = order[(i + 1) % order.length];
                        if (next === PowerProfile.Performance && !PowerProfiles.hasPerformanceProfile)
                            next = order[0];
                        PowerProfiles.profile = next;
                    }
                }

                ToggleTile {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.tileHeight
                    icon: "󰑋"
                    title: "Screen Record"
                    active: Recorder.active
                    subtitle: active ? FocusTimer.format(Recorder.elapsed) : "Focused display"
                    onClicked: {
                        Panels.controlCenterOpen = false;
                        Recorder.active ? Recorder.stop() : Recorder.start();
                    }
                }

                ToggleTile {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.tileHeight
                    icon: "󰔟"
                    title: "Focus Timer"
                    active: FocusTimer.active
                    subtitle: active ? FocusTimer.format(FocusTimer.remaining) : `${Settings.island.focusMinutes} min`
                    onClicked: FocusTimer.active ? FocusTimer.stop() : FocusTimer.start()
                }
            }

            MediaCard {
                Layout.fillWidth: true
            }

            SliderTile {
                id: volume
                Layout.fillWidth: true

                readonly property PwNode sink: Pipewire.defaultAudioSink
                readonly property bool ready: sink?.ready ?? false

                title: ready ? (sink.description || "Sound") : "Sound"
                icon: !ready || sink.audio.muted ? "󰝟" : "󰕾"
                value: ready ? sink.audio.volume : 0
                dimmed: !ready || sink.audio.muted
                onMoved: v => {
                    if (ready)
                        sink.audio.volume = v;
                }
                onIconClicked: if (ready)
                    sink.audio.muted = !sink.audio.muted

                // Sound features: pick the output here, open the mixer.
                property bool outputsOpen: false
                titleClickable: Features.on("audioOutputs") && Sound.sinks.length > 1
                titleOpen: outputsOpen
                onTitleClicked: outputsOpen = !outputsOpen
                expandable: Features.on("mixer")
                onExpandClicked: {
                    Panels.controlCenterOpen = false;
                    Sound.openMixer(root.modelData.name);
                }

                PwObjectTracker {
                    objects: volume.sink ? [volume.sink] : []
                }
            }

            OutputPicker {
                Layout.fillWidth: true
                visible: volume.outputsOpen && volume.titleClickable
            }

            Calendar {
                Layout.fillWidth: true
            }

            Text {
                Layout.alignment: Qt.AlignRight
                Layout.rightMargin: 8
                text: "Settings…"
                color: Theme.accent
                font.family: Theme.fontUi
                font.pixelSize: 12
                font.weight: Font.Medium

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        Panels.controlCenterOpen = false;
                        Panels.settingsOpen = true;
                    }
                }
            }
        }
    }
}
