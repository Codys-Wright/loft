import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.audio
import qs.components
import qs.menubar
import qs.services

// The menu bar, as on macOS Golden Gate: flush with the top edge and the full
// width of the screen, with no background — titles and icons sit on the
// wallpaper, light or dark from the wallpaper under the bar on this output
// (Theme.barTextFor / barShadowFor, WallpaperTone), with a soft shadow.
// "Show menu bar background" (Theme.barBackground) brings back the glass
// strip. Left: the OS mark, the focused app (bold) and the space indicator.
// Right: status, Control Center, date.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    // A space can hide the bar on its displays (Gaming: `bar.hidden`).
    visible: !Spaces.barHiddenOn(modelData.name)
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "loft:bar"
    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: barHeight
    exclusiveZone: barHeight
    color: "transparent"

    readonly property int barHeight: 30

    // This output's bar colors (per-output components use the same calls).
    readonly property color textColor: Theme.barTextFor(modelData.name)
    readonly property color shadowColor: Theme.barShadowFor(modelData.name)

    BackgroundEffect.blurRegion: barRegion
    Region {
        id: barRegion
        item: Theme.blur && Theme.barBackground ? bar : null
    }

    // Soft shadow under everything on a transparent bar (titles, icons).
    contentItem.layer.enabled: !Theme.barBackground
    contentItem.layer.effect: MultiEffect {
        shadowEnabled: true
        shadowColor: root.shadowColor
        shadowBlur: 0.5
        shadowVerticalOffset: 1
        shadowHorizontalOffset: 0
    }

    GlassSurface {
        id: bar
        visible: Theme.barBackground
        clear: true
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
            // Up to the island (centred, ≤ 300 px compact + 7 px shoulders each
            // side when attached), past the workspaces.
            maxWidth: root.width / 2 - (Features.on("island") ? 160 : 12) - 14 - left.spacing - workspaces.implicitWidth
        }

        // The space indicator (spaces on) or the workspace dots.
        Workspaces {
            id: workspaces
            visible: workspaces.implicitWidth > 0
            output: root.modelData.name
            window: root
        }
    }

    // ── Right: status items (Controls; Settings → Menu Bar) ─────────────
    StatusItems {
        id: statusRow
        // The bar is on every display; its status area only on the active one
        // (main display, or the fallback while the main one is fullscreen).
        visible: Displays.isActive(root.modelData)
        anchors {
            right: parent.right
            rightMargin: 10
            verticalCenter: parent.verticalCenter
        }
        window: root
        screenName: root.modelData.name
        // Up to the island (centred, ≤ 300 px compact + 7 px shoulders each
        // side when attached).
        maxWidth: root.width / 2 - (Features.on("island") ? 160 : 12) - 10
    }

    // Keep Awake (services/KeepAwake.qml): keep the session from idling.
    IdleInhibitor {
        window: root
        enabled: KeepAwake.active
    }
}
