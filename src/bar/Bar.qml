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
//
// Full screen (FullscreenChrome): while this display shows a fullscreen
// window the bar slides up out of sight, leaving a 1 px input strip at the
// top edge; resting the pointer there brings it back down over the app (on
// the Overlay layer, as niri draws Top under a fullscreen window, on a solid
// strip), and it slides away again once the pointer, the island and any menu
// opened from it have left.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    // A space can hide the bar on its displays (Gaming: `bar.hidden`).
    visible: !Spaces.barHiddenOn(modelData.name)
    // Over a fullscreen window only Overlay is drawn above it.
    WlrLayershell.layer: overApp ? WlrLayer.Overlay : WlrLayer.Top
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

    // ── Full screen (FullscreenChrome) ──────────────────────────────────
    readonly property string screenName: modelData.name
    readonly property bool overApp: FullscreenChrome.fullscreenOn(screenName)
    readonly property bool hides: FullscreenChrome.barHidesOn(screenName)
    readonly property bool revealed: FullscreenChrome.revealedOn(screenName)
    readonly property bool concealed: FullscreenChrome.barConcealedOn(screenName)
    // A bar menu (or a status item's panel), the Control Center or the Sound
    // mixer open here.
    readonly property bool menuHere: (MenuState.open && MenuState.screen === screenName) || (Panels.controlCenterOpen && Panels.controlCenterScreen === screenName) || (Sound.mixerOpen && Sound.mixerScreen === screenName)
    onMenuHereChanged: {
        FullscreenChrome.setMenuOpen(screenName, menuHere);
        // A panel covered the bar (the Control Center and the menus take
        // the whole screen for click-outside), so the bar lost the pointer;
        // Qt only sees it again once it moves. Give it longer to move
        // before the bar goes (closing by clicking the bar's own button
        // leaves the pointer here, still).
        if (!menuHere)
            grace.afterMenu = true;
    }
    Component.onCompleted: FullscreenChrome.setMenuOpen(screenName, menuHere)
    Component.onDestruction: {
        FullscreenChrome.setMenuOpen(screenName, false);
        FullscreenChrome.setRevealed(screenName, false);
    }
    // What keeps a revealed bar down: the pointer on it, on the island, or a
    // menu opened from it.
    readonly property bool keepRevealed: pointer.hovered || menuHere || FullscreenChrome.islandBusy[screenName] === true

    function updateReveal() {
        if (!hides) {
            dwell.stop();
            grace.stop();
        } else if (!revealed) {
            grace.stop();
            if (pointer.hovered && FullscreenChrome.revealAtTop)
                dwell.restart();
            else
                dwell.stop();
        } else {
            dwell.stop();
            if (keepRevealed)
                grace.stop();
            else
                grace.restart();
        }
    }
    onKeepRevealedChanged: updateReveal()
    onRevealedChanged: updateReveal()
    onHidesChanged: updateReveal()

    // Resting at the top edge, not passing through it, brings the bar down.
    Timer {
        id: dwell
        interval: 350
        onTriggered: if (root.hides && pointer.hovered && FullscreenChrome.revealAtTop)
            FullscreenChrome.setRevealed(root.screenName, true)
    }
    // A short grace after leaving, so a dip below the bar doesn't drop it.
    Timer {
        id: grace
        property bool afterMenu: false
        interval: afterMenu ? 1500 : 600
        onTriggered: {
            afterMenu = false;
            if (!root.keepRevealed)
                FullscreenChrome.setRevealed(root.screenName, false);
        }
    }

    // Input: the whole bar, or while it's away only a 1 px strip at the top
    // edge, so the fullscreen app keeps its clicks. Never empty: Quickshell
    // makes an empty mask WindowTransparentForInput, which QtWayland doesn't
    // undo when the mask fills again (with the reveal off the strip just
    // doesn't start the dwell).
    mask: Region {
        item: inputArea
    }
    Item {
        id: inputArea
        anchors {
            top: parent.top
            left: parent.left
            right: parent.right
        }
        height: root.concealed ? 1 : root.barHeight
    }

    // Is the pointer on the bar (inside the input mask)? On the window's
    // content item, the ancestor of every bar item: it stays hovered over
    // the status items, titles and workspace cells, and they still get
    // their own hover. (On an item stacked above them, it took the hover
    // from every MouseArea under it: no hover highlights, no space or
    // workspace names on hover.)
    HoverHandler {
        id: pointer
        onHoveredChanged: if (hovered)
            grace.afterMenu = false
    }

    // This output's bar colors (per-output components use the same calls).
    readonly property color textColor: Theme.barTextFor(modelData.name)
    readonly property color shadowColor: Theme.barShadowFor(modelData.name)

    BackgroundEffect.blurRegion: barRegion
    Region {
        id: barRegion
        item: Theme.blur && Theme.barBackground && !root.overApp ? bar : null
    }

    // Soft shadow under everything on a transparent bar (titles, icons).
    contentItem.layer.enabled: !Theme.barBackground && !root.overApp
    contentItem.layer.effect: MultiEffect {
        shadowEnabled: true
        shadowColor: root.shadowColor
        shadowBlur: 0.5
        shadowVerticalOffset: 1
        shadowHorizontalOffset: 0
    }

    // Everything the bar draws, slid up out of sight while it's away (Reduce
    // Motion: it fades instead).
    Item {
        id: face
        anchors {
            left: parent.left
            right: parent.right
        }
        height: root.barHeight
        // (A Behavior's duration can't depend on the direction: it is read
        // before the binding that picks it updates.)
        y: root.concealed && !Motion.reduce ? -root.barHeight : 0
        opacity: root.concealed && Motion.reduce ? 0 : 1
        visible: opacity > 0 && y > -root.barHeight
        // The status items register what's visible for hover-switching
        // between their panels (MenuState.extraItems): re-measure once shown.
        onVisibleChanged: if (visible && statusRow.visible)
            statusRow.measure()

        Behavior on y {
            enabled: !Motion.reduce
            NumberAnimation {
                duration: Motion.ms(220)
                easing.type: Easing.OutCubic
            }
        }
        Behavior on opacity {
            enabled: Motion.reduce
            NumberAnimation {
                duration: Motion.ms(160)
            }
        }

        // Over a fullscreen app: a solid strip, as macOS's menu bar there.
        Rectangle {
            anchors.fill: parent
            visible: root.overApp
            color: Theme.bg

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

        GlassSurface {
            id: bar
            visible: Theme.barBackground && !root.overApp
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
            // (main display, or the fallback while the main one is fullscreen),
            // and on a display showing a fullscreen window, so the bar revealed
            // there over the app (FullscreenChrome) is the whole menu bar. Its
            // panels open from this copy, on this display (everything in it
            // is keyed by screenName: overflow, extras, Control Center, mixer).
            visible: Displays.isActive(root.modelData) || root.overApp
            onVisibleChanged: if (visible)
                measure()
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
    }

    // Keep Awake (services/KeepAwake.qml): keep the session from idling.
    IdleInhibitor {
        window: root
        enabled: KeepAwake.active
    }
}
