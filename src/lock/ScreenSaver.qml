import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Mpris
import qs.services
import qs.lock.design

// The idle dimming and the screen saver, one overlay per screen
// (services/Idle.qml decides when; Settings → Appearance → Screen Saver how
// it looks, LockSleepConfig.screenSaver).
//
// Dimmed, input passes through: moving the mouse just wakes the screen.
// The screen saver takes the pointer and the keyboard, so the key or click
// that ends it doesn't also reach the app underneath. Locking draws the
// lock above it (a session lock is above every layer), so it hides then.
PanelWindow {
    id: root

    required property var modelData
    screen: modelData

    readonly property var look: LockSleepConfig.screenSaver
    readonly property bool saver: Idle.saverOn
    readonly property bool dim: Idle.dimmed && !saver && !LockState.locked
    readonly property bool shown: saver || dim

    // Stay mapped while fading out.
    visible: shown || scrim.opacity > 0 || saverLayer.opacity > 0
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft-screensaver"
    WlrLayershell.keyboardFocus: saver ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    // Dimmed: an empty input region, so clicks reach the windows.
    mask: Region {
        item: root.saver ? content : null
    }

    function wake() {
        Idle.endPreview();
    }

    Item {
        id: content
        anchors.fill: parent
        focus: root.saver
        Keys.onPressed: event => {
            root.wake();
            event.accepted = true;
        }

        MouseArea {
            anchors.fill: parent
            enabled: root.saver
            hoverEnabled: true
            cursorShape: root.saver ? Qt.BlankCursor : Qt.ArrowCursor
            // The first move after showing comes from the pointer sitting
            // there already; only real motion wakes.
            property point start: Qt.point(-1, -1)
            onEntered: start = Qt.point(mouseX, mouseY)
            onPositionChanged: mouse => {
                if (start.x < 0)
                    start = Qt.point(mouse.x, mouse.y);
                else if (Math.abs(mouse.x - start.x) + Math.abs(mouse.y - start.y) > 6)
                    root.wake();
            }
            onPressed: root.wake()
            onWheel: root.wake()
        }

        // The dim, and the screen saver's own darkening.
        Rectangle {
            id: scrim
            anchors.fill: parent
            color: "black"
            opacity: root.saver ? (root.look.style === "black" ? 1 : 0) : root.dim ? 0.5 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: root.shown ? 1200 : 250
                    easing.type: Easing.InOutQuad
                }
            }
        }

        Item {
            id: saverLayer
            anchors.fill: parent
            opacity: root.saver ? 1 : 0
            visible: opacity > 0
            Behavior on opacity {
                NumberAnimation {
                    duration: root.saver ? 1200 : 250
                    easing.type: Easing.InOutQuad
                }
            }

            readonly property string wallpaper: Vibes.url(Vibes.wallpaperFor(root.screen?.name ?? ""))
            readonly property real sizeScale: Math.max(0.6, Math.min(root.width, root.height) / 1100)

            // clock: the wallpaper, darkened, under a large centered clock.
            Backdrop {
                anchors.fill: parent
                visible: root.look.style === "clock"
                image: saverLayer.wallpaper
                Rectangle {
                    anchors.fill: parent
                    color: Qt.rgba(0, 0, 0, 0.45)
                }
            }

            // drift: the wallpaper slowly panning and zooming.
            Item {
                anchors.fill: parent
                visible: root.look.style === "drift"
                clip: true
                Backdrop {
                    id: drifting
                    width: parent.width * 1.15
                    height: parent.height * 1.15
                    image: saverLayer.wallpaper
                    SequentialAnimation on x {
                        running: root.saver && root.look.style === "drift"
                        loops: Animation.Infinite
                        NumberAnimation {
                            from: 0
                            to: -root.width * 0.15
                            duration: 60000
                            easing.type: Easing.InOutSine
                        }
                        NumberAnimation {
                            from: -root.width * 0.15
                            to: 0
                            duration: 60000
                            easing.type: Easing.InOutSine
                        }
                    }
                    SequentialAnimation on y {
                        running: root.saver && root.look.style === "drift"
                        loops: Animation.Infinite
                        NumberAnimation {
                            from: -root.height * 0.15
                            to: 0
                            duration: 45000
                            easing.type: Easing.InOutSine
                        }
                        NumberAnimation {
                            from: 0
                            to: -root.height * 0.15
                            duration: 45000
                            easing.type: Easing.InOutSine
                        }
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    color: Qt.rgba(0, 0, 0, 0.2)
                }
            }

            Column {
                id: info
                spacing: 18 * saverLayer.sizeScale
                visible: root.look.showClock || nowPlaying.visible
                // Centered for clock; low and to the left for drift; for
                // black it wanders a little each minute so no pixel stays lit.
                property real wanderX: 0
                property real wanderY: 0
                x: root.look.style === "drift" ? 60 * saverLayer.sizeScale : (root.width - width) / 2 + wanderX
                y: root.look.style === "drift" ? root.height - height - 60 * saverLayer.sizeScale : (root.height - height) / 2 + wanderY
                opacity: root.look.style === "black" ? 0.55 : 1
                Behavior on x {
                    NumberAnimation {
                        duration: 4000
                        easing.type: Easing.InOutSine
                    }
                }
                Behavior on y {
                    NumberAnimation {
                        duration: 4000
                        easing.type: Easing.InOutSine
                    }
                }

                Timer {
                    running: root.saver && root.look.style === "black"
                    interval: 60000
                    repeat: true
                    onTriggered: {
                        info.wanderX = (Math.random() - 0.5) * root.width * 0.5;
                        info.wanderY = (Math.random() - 0.5) * root.height * 0.4;
                    }
                }

                LockClock {
                    visible: root.look.showClock
                    anchors.horizontalCenter: root.look.style === "drift" ? undefined : parent.horizontalCenter
                    sizeScale: saverLayer.sizeScale * (root.look.style === "drift" ? 0.6 : 1)
                }

                // Now Playing: one line under the clock.
                Row {
                    id: nowPlaying
                    readonly property var player: Mpris.players.values.find(p => p.isPlaying) ?? null
                    visible: root.look.showMedia && player !== null && (player.trackTitle ?? "") !== ""
                    anchors.horizontalCenter: root.look.style === "drift" ? undefined : parent.horizontalCenter
                    spacing: 10
                    Text {
                        text: "󰎈"
                        color: Qt.rgba(1, 1, 1, 0.8)
                        font.family: Theme.fontIcons
                        font.pixelSize: 18 * saverLayer.sizeScale
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: (nowPlaying.player?.trackTitle ?? "") + (nowPlaying.player?.trackArtist ? `  ·  ${nowPlaying.player.trackArtist}` : "")
                        color: Qt.rgba(1, 1, 1, 0.85)
                        font.family: Theme.fontUi
                        font.pixelSize: 18 * saverLayer.sizeScale
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, root.width * 0.6)
                    }
                }
            }
        }
    }
}
