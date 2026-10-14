import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// The menu bar: floating Liquid Glass pills on a transparent strip
// (javiiervm's layout). Left: app menu (studio mark + focused app, like
// macOS) and workspaces. Right: tray, status, clock.
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
    implicitHeight: 44
    exclusiveZone: 44
    color: "transparent"

    readonly property int pillHeight: 34

    // Blur exactly the pills — the strip between them stays clear.
    BackgroundEffect.blurRegion: Theme.blur ? pills : null
    Region {
        id: pills
        item: appPill
        radius: appPill.radius

        Region {
            item: workspacePill
            radius: workspacePill.radius
        }
        Region {
            item: statusPill
            radius: statusPill.radius
        }
    }

    // ── Left: app menu ──────────────────────────────────────────────────
    GlassSurface {
        id: appPill
        anchors {
            left: parent.left
            leftMargin: 12
            verticalCenter: parent.verticalCenter
        }
        height: root.pillHeight
        width: appRow.implicitWidth + 28
        radius: height / 2

        RowLayout {
            id: appRow
            anchors.centerIn: parent
            spacing: 10

            Icon {
                text: "󰽰"
                size: 18
                color: Theme.accent
            }

            Text {
                text: Niri.focusedWindow ? Apps.name(Niri.focusedWindow.app_id) : "Desktop"
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 14
                font.weight: Font.DemiBold
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: Niri.toggleOverview()
        }
    }

    GlassSurface {
        id: workspacePill
        anchors {
            left: appPill.right
            leftMargin: 8
            verticalCenter: parent.verticalCenter
        }
        visible: workspaces.workspaces.length > 0
        height: root.pillHeight
        width: workspaces.implicitWidth + 28
        radius: height / 2

        Workspaces {
            id: workspaces
            anchors.centerIn: parent
            output: root.modelData.name
        }
    }

    // ── Right: status ───────────────────────────────────────────────────
    GlassSurface {
        id: statusPill
        anchors {
            right: parent.right
            rightMargin: 12
            verticalCenter: parent.verticalCenter
        }
        height: root.pillHeight
        width: statusRow.implicitWidth + 32
        radius: height / 2

        RowLayout {
            id: statusRow
            anchors.centerIn: parent
            spacing: 16

            Tray {
                window: root
                visible: children.length > 1
            }

            Volume {}

            Icon {
                text: "󰒓"
                size: 16
                color: Panels.controlCenterOpen ? Theme.accent : Theme.text

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Panels.toggleControlCenter(root.modelData.name)
                }
            }

            Text {
                text: Qt.formatDateTime(clock.date, "ddd MMM d   h:mm AP")
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.weight: Font.Medium
            }
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
