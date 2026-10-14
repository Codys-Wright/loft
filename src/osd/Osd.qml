import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// On-screen display: a glass pill above the dock that appears when the output
// volume or mute changes (keys, apps, the Control Center) and fades out.
// Sound announcements (output switched, microphones muted — Sound.announced)
// show in the same pill as an icon and a line of text. The state lives in
// Hud.qml; this pill is its fallback — with the Dynamic Island on (and
// Settings → Dynamic Island → Show changes in the Dynamic Island), the island
// shows it instead.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property real volume: Hud.value
    readonly property bool muted: Hud.muted
    readonly property string message: Hud.kind === "message" ? Hud.text : ""
    readonly property string messageIcon: Hud.icon

    // Only the focused output shows it (Hud.output).
    readonly property bool shown: !Hud.inIsland && Hud.kind !== "brightness" && Hud.onScreen(modelData.name)

    visible: shown || fade.running
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:osd"
    exclusionMode: ExclusionMode.Ignore
    anchors.bottom: true
    margins.bottom: 130
    implicitWidth: message ? Math.min(560, Math.max(300, messageText.implicitWidth + 92)) : 300
    implicitHeight: 56
    color: "transparent"
    mask: Region {}

    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur && shown ? pill : null
        radius: pill.radius
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
