import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.services

// Dock (placeholder): a floating Liquid Glass pill at the bottom center.
// Phase 3 fills it with pinned + running apps from niri.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "studio:dock"
    exclusionMode: ExclusionMode.Ignore
    anchors.bottom: true
    margins.bottom: 10
    implicitWidth: row.implicitWidth + 2 * padding
    implicitHeight: 64 + 2 * padding
    color: "transparent"

    readonly property int padding: 8

    // Blur exactly the rounded pill, not the window rectangle.
    BackgroundEffect.blurRegion: Theme.blur ? glassRegion : null
    Region {
        id: glassRegion
        item: glass
        radius: glass.radius
    }

    Rectangle {
        id: glass
        anchors.fill: parent
        radius: Theme.radius + 8
        color: Theme.glassFill
        border.width: 1
        border.color: Theme.glassBorder
    }

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: 10

        Repeater {
            model: [Theme.accent, Theme.accent2, Theme.ok, Theme.warn, Theme.urgent, Theme.overlay]
            delegate: Rectangle {
                required property color modelData
                Layout.preferredWidth: 56
                Layout.preferredHeight: 56
                radius: 14
                color: modelData
            }
        }
    }
}
