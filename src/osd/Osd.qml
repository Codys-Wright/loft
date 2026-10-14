import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import qs.components
import qs.services

// On-screen display: a glass pill above the dock that appears when the output
// volume or mute changes (keys, apps, the Control Center) and fades out.
// Sound announcements (output switched, microphones muted — Sound.announced)
// show in the same pill as an icon and a line of text.
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
    implicitWidth: message ? Math.min(560, Math.max(300, messageText.implicitWidth + 92)) : 300
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
        // A volume change right after an announcement (the new output's
        // volume) keeps the announcement up.
        if (!messageTimer.running)
            message = "";
        shown = true;
        hide.restart();
    }

    property string message: ""
    property string messageIcon: ""

    function say(icon, text) {
        if (!onThisScreen)
            return;
        messageIcon = icon;
        message = text;
        shown = true;
        messageTimer.restart();
        hide.restart();
    }

    Connections {
        target: Sound
        function onAnnounced(icon, text) {
            root.say(icon, text);
        }
    }

    Timer {
        id: messageTimer
        interval: 2200
    }
    onVolumeChanged: poke()
    onMutedChanged: poke()

    Timer {
        id: hide
        interval: root.message ? 2200 : 1400
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
                text: root.message ? root.messageIcon : root.muted || root.volume <= 0 ? "󰝟" : root.volume >= 0.66 ? "󰕾" : root.volume >= 0.33 ? "󰖀" : "󰕿"
            }

            Text {
                id: messageText
                visible: root.message !== ""
                Layout.fillWidth: true
                text: root.message
                elide: Text.ElideRight
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.weight: Font.DemiBold
            }

            Rectangle {
                visible: root.message === ""
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
                visible: root.message === ""
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
