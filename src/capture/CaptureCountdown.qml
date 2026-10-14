import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// The selector's timer: a glass disc counting down in the middle of the
// focused screen. Click it (or Escape via IPC capture cancel) to cancel.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    visible: Capture.countdown > 0 && Capture.screenFocused?.name === modelData.name
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "studio:capture-countdown"
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: 180
    implicitHeight: 180
    color: "transparent"

    mask: Region {
        item: disc
        radius: disc.radius
    }
    BackgroundEffect.blurRegion: Theme.blur ? blur : null
    Region {
        id: blur
        item: disc
        radius: disc.radius
    }

    GlassSurface {
        id: disc
        anchors.centerIn: parent
        width: 140
        height: 140
        radius: 70
        strength: 1.8
        showHighlight: false

        Text {
            anchors.centerIn: parent
            text: Capture.countdown
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 64
            font.weight: Font.DemiBold
            font.features: {
                "tnum": 1
            }

            // A beat on every second.
            onTextChanged: beat.restart()
            NumberAnimation on scale {
                id: beat
                from: 1.25
                to: 1
                duration: 350
                easing.type: Easing.OutBack
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: Capture.cancel()
        }
    }
}
