import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services

// Island media page (One UI-style, as javiiervm did it): the album art
// fills the page behind a dark veil; controls take an accent color picked
// from the art. With Lyrics on, the current synced line under the artist.
Item {
    id: root

    property var player: null
    readonly property string art: player?.trackArtUrl ?? ""

    // Brightest reasonably saturated color of the art, else the theme accent.
    readonly property color artAccent: {
        const cs = quantizer.colors.filter(c => c.hslSaturation > 0.25 && c.hslLightness > 0.35);
        cs.sort((a, b) => b.hslLightness - a.hslLightness);
        return cs.length ? cs[0] : Theme.accent;
    }

    ColorQuantizer {
        id: quantizer
        source: root.art
        depth: 3
        rescaleSize: 64
    }

    // MPRIS position isn't pushed; poll it while visible.
    Timer {
        interval: 1000
        running: root.visible && (root.player?.isPlaying ?? false)
        repeat: true
        onTriggered: root.player.positionChanged()
    }

    Image {
        anchors.fill: parent
        visible: root.art !== ""
        source: root.art
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        opacity: 0.55
    }

    Rectangle {
        anchors.fill: parent
        visible: root.art !== ""
        color: "black"
        opacity: 0.45
    }

    Row {
        anchors.centerIn: parent
        visible: !root.player
        spacing: 10

        Icon {
            text: "󰎆"
            size: 18
            color: Theme.islandSubtext
        }

        Text {
            text: "Nothing playing"
            color: Theme.islandSubtext
            font.family: Theme.fontUi
            font.pixelSize: 13
        }
    }

    // Over the art the text is always light; without art it follows the theme.
    readonly property color fg: art !== "" ? "white" : Theme.islandText
    readonly property color fgDim: art !== "" ? Qt.rgba(1, 1, 1, 0.72) : Theme.islandSubtext

    ColumnLayout {
        anchors {
            fill: parent
            margins: 20
            bottomMargin: 26
        }
        visible: root.player !== null
        spacing: 4

        Text {
            Layout.fillWidth: true
            text: root.player?.trackTitle || root.player?.identity || ""
            color: root.fg
            font.family: Theme.fontUi
            font.pixelSize: 17
            font.weight: Font.Bold
            elide: Text.ElideRight
        }

        Text {
            Layout.fillWidth: true
            text: [root.player?.trackArtist, root.player?.identity].filter(s => s).join("  ·  ")
            color: root.fgDim
            font.family: Theme.fontUi
            font.pixelSize: 12
            elide: Text.ElideRight
        }

        // The current lyric line (Settings → Dynamic Island → Lyrics).
        Text {
            id: lyricLine
            Layout.fillWidth: true
            Layout.topMargin: 4
            visible: Lyrics.has && Lyrics.player === root.player
            text: Lyrics.current || "♪"
            color: root.artAccent
            font.family: Theme.fontUi
            font.pixelSize: 14
            font.weight: Font.DemiBold
            elide: Text.ElideRight

            Behavior on text {
                SequentialAnimation {
                    NumberAnimation {
                        target: lyricLine
                        property: "opacity"
                        to: 0.3
                        duration: 90
                    }
                    PropertyAction {}
                    NumberAnimation {
                        target: lyricLine
                        property: "opacity"
                        to: 1
                        duration: 160
                    }
                }
            }
        }

        Item {
            Layout.fillHeight: true
        }

        // Scrubber with elapsed / total.
        RowLayout {
            Layout.fillWidth: true
            visible: (root.player?.lengthSupported ?? false) && root.player.length > 0
            spacing: 10

            readonly property real progress: visible ? root.player.position / root.player.length : 0

            Text {
                text: FocusTimer.format(Math.floor(root.player?.position ?? 0))
                color: root.fgDim
                font.family: Theme.fontUi
                font.pixelSize: 10
                font.features: { "tnum": 1 }
            }

            Item {
                Layout.fillWidth: true
                Layout.preferredHeight: 16

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 4
                    radius: 2
                    color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.22)

                    Rectangle {
                        width: parent.width * Math.max(0, Math.min(1, parent.parent.parent.progress))
                        height: parent.height
                        radius: 2
                        color: root.artAccent
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: root.player?.canSeek ?? false
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mouse => root.player.position = root.player.length * mouse.x / width
                }
            }

            Text {
                text: FocusTimer.format(Math.floor(root.player?.length ?? 0))
                color: root.fgDim
                font.family: Theme.fontUi
                font.pixelSize: 10
                font.features: { "tnum": 1 }
            }
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 30

            Repeater {
                model: [
                    { icon: "󰒮", act: () => root.player.previous(), enabled: root.player?.canGoPrevious ?? false },
                    { icon: root.player?.isPlaying ? "󰏤" : "󰐊", act: () => root.player.togglePlaying(), enabled: root.player?.canTogglePlaying ?? false, big: true },
                    { icon: "󰒭", act: () => root.player.next(), enabled: root.player?.canGoNext ?? false }
                ]

                delegate: Icon {
                    required property var modelData
                    text: modelData.icon
                    size: modelData.big ? 30 : 22
                    color: modelData.big ? root.artAccent : root.fg
                    opacity: modelData.enabled ? 1 : 0.35

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -8
                        enabled: parent.modelData.enabled
                        cursorShape: Qt.PointingHandCursor
                        onClicked: parent.modelData.act()
                    }
                }
            }
        }
    }
}
