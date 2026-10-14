import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import qs.components
import qs.services

// Dynamic Island: a glass pill at the top center. Collapsed it shows the
// time, or now-playing art + a live equalizer. Hovering expands it into a
// carousel of pages (media, system); scroll to switch pages.
// Design ported from javiiervm/dotfiles' DynamicIsland.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "studio:island"
    // Sit inside the bar's strip rather than below its exclusive zone.
    exclusionMode: ExclusionMode.Ignore
    anchors.top: true
    margins.top: 5
    implicitWidth: 500
    implicitHeight: 230
    color: "transparent"

    readonly property var players: Mpris.players.values
    readonly property var player: players.find(p => p.isPlaying) ?? players[0] ?? null
    readonly property bool playing: player?.isPlaying ?? false

    // Hover expands; `qs ipc call island toggle|media|system` pins it open (keybinds).
    property bool pinned: false
    readonly property bool expanded: hover.hovered || pinned
    property int page: 0
    readonly property int pageCount: 2

    // A notification banner takes over the pill until it times out.
    readonly property var banner: Notifications.current
    readonly property bool bannering: banner !== null && !expanded

    readonly property real targetWidth: expanded ? 460 : bannering ? 440 : playing ? 300 : 150
    readonly property real targetHeight: expanded ? 200 : bannering ? 84 : 34

    // Input and blur follow the pill's silhouette only.
    mask: Region {
        item: pill
        radius: pill.radius
    }
    BackgroundEffect.blurRegion: Theme.blur ? blur : null
    Region {
        id: blur
        item: pill
        radius: pill.radius
    }

    onExpandedChanged: {
        SystemStats.active = expanded && page === 1;
        if (expanded)
            page = player ? 0 : 1;
    }
    onPageChanged: SystemStats.active = expanded && page === 1

    GlassSurface {
        id: pill
        anchors {
            top: parent.top
            horizontalCenter: parent.horizontalCenter
        }
        width: root.targetWidth
        height: root.targetHeight
        radius: root.expanded ? 28 : root.bannering ? 26 : height / 2
        showHighlight: false
        strength: 1.6
        clip: true

        Behavior on width {
            NumberAnimation {
                duration: 300
                easing.type: Easing.OutQuint
            }
        }
        Behavior on height {
            NumberAnimation {
                duration: 300
                easing.type: Easing.OutQuint
            }
        }
        Behavior on radius {
            NumberAnimation {
                duration: 300
                easing.type: Easing.OutQuint
            }
        }

        HoverHandler {
            id: hover
        }

        WheelHandler {
            enabled: root.expanded
            onWheel: event => root.page = (root.page + (event.angleDelta.y < 0 ? 1 : root.pageCount - 1)) % root.pageCount
        }

        // ── Collapsed ───────────────────────────────────────────────────
        RowLayout {
            anchors {
                fill: parent
                leftMargin: 8
                rightMargin: 14
            }
            visible: opacity > 0
            opacity: root.expanded || root.bannering ? 0 : 1
            spacing: 10

            Behavior on opacity {
                NumberAnimation {
                    duration: 150
                }
            }

            Rectangle {
                visible: root.playing
                Layout.preferredWidth: 22
                Layout.preferredHeight: 22
                radius: 6
                clip: true
                color: Theme.overlay

                Image {
                    anchors.fill: parent
                    source: root.player?.trackArtUrl ?? ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                }
            }

            Text {
                Layout.fillWidth: true
                horizontalAlignment: root.playing ? Text.AlignLeft : Text.AlignHCenter
                text: root.playing ? (root.player.trackTitle || root.player.identity) : Qt.formatDateTime(clock.date, "h:mm AP")
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Equalizer {
                visible: root.playing
                running: root.playing && !root.expanded
                Layout.preferredWidth: 18
                Layout.preferredHeight: 14
            }
        }

        // ── Notification banner ─────────────────────────────────────────
        Banner {
            anchors {
                fill: parent
                margins: 12
            }
            notification: root.banner
            visible: opacity > 0
            opacity: root.bannering ? 1 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: 180
                }
            }
        }

        // Each banner stays 5s (longer while hovered via the expanded state).
        Timer {
            running: root.bannering
            interval: 5000
            onTriggered: Notifications.next()
        }

        // ── Expanded pages ──────────────────────────────────────────────
        Item {
            anchors {
                fill: parent
                margins: 18
            }
            visible: opacity > 0
            opacity: root.expanded ? 1 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: 220
                }
            }

            MediaPage {
                anchors.fill: parent
                visible: root.page === 0
                player: root.player
            }

            SystemPage {
                anchors.fill: parent
                visible: root.page === 1
            }

            // Page dots.
            Row {
                anchors {
                    bottom: parent.bottom
                    horizontalCenter: parent.horizontalCenter
                    bottomMargin: -10
                }
                spacing: 6

                Repeater {
                    model: root.pageCount
                    delegate: Rectangle {
                        required property int index
                        width: 6
                        height: 6
                        radius: 3
                        color: Theme.text
                        opacity: index === root.page ? 0.9 : 0.25
                    }
                }
            }
        }
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    IpcHandler {
        target: "island"

        function toggle(): void {
            root.pinned = !root.pinned;
        }

        function media(): void {
            root.pinned = true;
            root.page = 0;
        }

        function system(): void {
            root.pinned = true;
            root.page = 1;
        }
    }
}
