import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Mpris
import qs.components
import qs.services

// Now playing (MPRIS): art, title/artist, previous / play-pause / next.
// Prefers a player that is playing; hidden when there is none.
GlassSurface {
    id: root

    readonly property var players: Mpris.players.values
    readonly property var player: players.find(p => p.isPlaying) ?? players[0] ?? null

    visible: player !== null
    implicitHeight: visible ? 76 : 0
    radius: 22
    showHighlight: false

    RowLayout {
        anchors {
            fill: parent
            margins: 12
        }
        spacing: 12

        Rectangle {
            Layout.preferredWidth: 52
            Layout.preferredHeight: 52
            radius: 12
            color: Theme.withAlpha(Theme.text, 0.12)
            clip: true

            Image {
                anchors.fill: parent
                source: root.player?.trackArtUrl ?? ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }

            Icon {
                anchors.centerIn: parent
                visible: !(root.player?.trackArtUrl)
                text: "󰝚"
                size: 22
                color: Theme.subtext
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            Text {
                Layout.fillWidth: true
                text: root.player?.trackTitle || root.player?.identity || ""
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                text: root.player?.trackArtist || root.player?.identity || ""
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }

        Repeater {
            model: [
                { icon: "󰒮", act: () => root.player.previous(), enabled: root.player?.canGoPrevious ?? false },
                { icon: root.player?.isPlaying ? "󰏤" : "󰐊", act: () => root.player.togglePlaying(), enabled: root.player?.canTogglePlaying ?? false },
                { icon: "󰒭", act: () => root.player.next(), enabled: root.player?.canGoNext ?? false }
            ]

            delegate: Icon {
                required property var modelData
                text: modelData.icon
                size: 20
                opacity: modelData.enabled ? 1 : 0.35

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    enabled: parent.modelData.enabled
                    cursorShape: Qt.PointingHandCursor
                    onClicked: parent.modelData.act()
                }
            }
        }
    }
}
