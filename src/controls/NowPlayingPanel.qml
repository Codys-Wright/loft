import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Mpris
import qs.services

// Now Playing: every MPRIS player as a card (art, title, artist,
// transport, scrubber), the playing one first.
ColumnLayout {
    id: root

    property bool details: false
    property bool shown: true
    property bool inMenu: true
    signal dismiss
    signal openSettings(string section)

    spacing: 8

    readonly property var players: Mpris.players.values.slice().sort((a, b) => b.isPlaying - a.isPlaying)

    PanelHeader {
        title: "Now Playing"
    }

    Repeater {
        model: root.players
        delegate: NowPlayingCard {
            required property var modelData
            Layout.leftMargin: 6
            Layout.rightMargin: 6
            player: modelData
            showApp: root.players.length > 1 || root.details
        }
    }

    PanelRow {
        visible: root.players.length === 0
        enabled: false
        dim: true
        text: "Nothing is playing"
    }
}
