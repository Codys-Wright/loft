import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import qs.components
import qs.services

// On-screen display: a glass pill above the dock that appears when the output
// volume or mute changes (keys, apps, the Control Center) and fades out.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property PwNode sink: Pipewire.defaultAudioSink
    readonly property bool ready: sink?.ready ?? false
    readonly property real volume: ready ? sink.audio.volume : 0
    readonly property bool muted: ready ? sink.audio.muted : false

    property bool shown: false
    // Only the focused output shows it.
    readonly property bool onThisScreen: (Niri.focusedWorkspace?.output ?? modelData.name) === modelData.name

    visible: shown || fade.running
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "studio:osd"
    exclusionMode: ExclusionMode.Ignore
    anchors.bottom: true
    margins.bottom: 130
    implicitWidth: 300
    implicitHeight: 56
    color: "transparent"
    mask: Region {}

    BackgroundEffect.blurRegion: Theme.blur && shown ? blur : null
    Region {
        id: blur
        item: pill
        radius: pill.radius
    }

    PwObjectTracker {
        objects: root.sink ? [root.sink] : []
    }

    // Ignore the initial values reported when the sink first binds.
    property bool armed: false
    Timer {
        running: root.ready
        interval: 500
        onTriggered: root.armed = true
    }

    function poke() {
        if (!armed || !onThisScreen)
            return;
        shown = true;
        hide.restart();
    }
    onVolumeChanged: poke()
    onMutedChanged: poke()

    Timer {
        id: hide
        interval: 1400
        onTriggered: root.shown = false
    }

    GlassSurface {
        id: pill
        anchors.fill: parent
        radius: height / 2
        strength: 1.5
        opacity: root.shown ? 1 : 0

        Behavior on opacity {
            NumberAnimation {
                id: fade
                duration: 200
            }
        }

        RowLayout {
            anchors {
                fill: parent
                leftMargin: 18
                rightMargin: 20
            }
            spacing: 14

            Icon {
                size: 20
                text: root.muted || root.volume <= 0 ? "󰝟" : root.volume >= 0.66 ? "󰕾" : root.volume >= 0.33 ? "󰖀" : "󰕿"
            }

            Rectangle {
                Layout.fillWidth: true
                height: 6
                radius: 3
                color: Theme.withAlpha(Theme.text, 0.18)

                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, root.volume))
                    height: parent.height
                    radius: 3
                    color: root.muted ? Theme.subtext : Theme.text

                    Behavior on width {
                        NumberAnimation {
                            duration: 100
                        }
                    }
                }
            }

            Text {
                text: root.muted ? "Muted" : `${Math.round(root.volume * 100)}`
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.weight: Font.DemiBold
                Layout.preferredWidth: 40
                horizontalAlignment: Text.AlignRight
            }
        }
    }
}
