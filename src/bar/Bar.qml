import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.audio
import qs.components
import qs.menubar
import qs.services

// The menu bar, as on macOS: one translucent strip, flush with the top edge
// and the full width of the screen. Left: the OS mark, the focused app (bold)
// and workspaces. Right: status, Control Center, date. Items sit directly on
// the bar; the glass is the bar itself.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "studio:bar"
    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: barHeight
    exclusiveZone: barHeight
    color: "transparent"

    readonly property int barHeight: 30

    BackgroundEffect.blurRegion: Theme.blur ? barRegion : null
    Region {
        id: barRegion
        item: bar
    }

    GlassSurface {
        id: bar
        anchors.fill: parent
        radius: 0
        showBorder: false
        showHighlight: false
        // Lighter than a panel: the wallpaper should read through, as on macOS.
        strength: 0.8

        // Hairline under the bar.
        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            height: 1
            color: Theme.glassBorder
        }
    }

    // ── Left: OS mark, app, workspaces ──────────────────────────────────
    RowLayout {
        id: left
        anchors {
            left: parent.left
            leftMargin: 14
            verticalCenter: parent.verticalCenter
        }
        spacing: 16

        // The OS mark (overview), the focused app in bold (its app menu),
        // then the app's global menus: File Edit View … (src/menubar/).
        MenuBarTitles {
            window: root
            screenName: root.modelData.name
            barHeight: root.barHeight
            // Up to the island (centred, ≤ 300 px compact), past the workspaces.
            maxWidth: root.width / 2 - (Features.on("island") ? 160 : 12) - 14 - left.spacing - workspaces.implicitWidth
        }

        Workspaces {
            id: workspaces
            visible: workspaces.workspaces.length > 0
            output: root.modelData.name
        }
    }

    // ── Right: status ───────────────────────────────────────────────────
    RowLayout {
        id: statusRow
        anchors {
            right: parent.right
            rightMargin: 14
            verticalCenter: parent.verticalCenter
        }
        spacing: 16

        Readouts {}

        Tray {
            window: root
            visible: children.length > 1
        }

        MicIndicator {
            screenName: root.modelData.name
        }

        Volume {
            screenName: root.modelData.name
        }

        Icon {
            text: "󰒓"
            size: 15
            color: Panels.controlCenterOpen ? Theme.accent : Theme.text

            MouseArea {
                anchors.fill: parent
                anchors.margins: -6
                cursorShape: Qt.PointingHandCursor
                onClicked: Panels.toggleControlCenter(root.modelData.name)
            }
        }

        Text {
            // The time lives in the island.
            text: Qt.formatDateTime(clock.date, "ddd MMM d")
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 13
            font.weight: Font.Medium
        }
    }

    // Caffeine (Control Center): keep the session from idling.
    IdleInhibitor {
        window: root
        enabled: Panels.caffeine
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }
}
