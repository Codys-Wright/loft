import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// Settings → Displays → Identify: each screen briefly shows which output it
// is (connector, model, mode), so the arrangement can be matched to reality.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property var info: NiriSettings.outputByName(modelData.name)

    visible: NiriSettings.identifying
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:identify"
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        left: true
    }
    margins {
        top: 60
        left: 40
    }
    implicitWidth: card.implicitWidth
    implicitHeight: card.implicitHeight
    color: "transparent"
    // Click-through.
    mask: Region {}

    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur ? card : null
        radius: card.radius
    }

    GlassSurface {
        id: card
        implicitWidth: col.implicitWidth + 56
        implicitHeight: col.implicitHeight + 40
        radius: 24
        strength: 1.8

        ColumnLayout {
            id: col
            anchors.centerIn: parent
            spacing: 4

            Text {
                text: root.modelData.name
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 44
                font.weight: Font.Bold
            }
            Text {
                text: root.info?.description ?? root.modelData.model ?? ""
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 16
            }
            Text {
                text: root.info ? `${root.info.mode ?? ""} · scale ${root.info.scale}` : `${root.modelData.width}×${root.modelData.height}`
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 13
            }
        }
    }
}
