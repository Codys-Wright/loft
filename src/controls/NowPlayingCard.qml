import QtQuick
import QtQuick.Layouts
import Quickshell.Services.Mpris
import qs.components
import qs.services

// One MPRIS player: art, title / artist, previous · play/pause · next and a
// scrubber (seek when the player allows it). `compact` drops the scrubber
// and shrinks the art (the Control Center's 2×1 tile).
ColumnLayout {
    id: card

    property var player: null
    property bool showApp: false
    property bool compact: false
    property int artSize: compact ? 40 : 52
    // Art on top, then the titles and the transport (a 2×2 tile).
    property bool stacked: false

    Layout.fillWidth: true
    spacing: 6

    // MPRIS doesn't push the position; ask while playing and visible.
    Timer {
        running: card.visible && (card.player?.isPlaying ?? false)
        repeat: true
        interval: 1000
        onTriggered: card.player.positionChanged()
    }

    function fmt(s) {
        s = Math.max(0, Math.floor(s));
        return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
    }

    // Transport buttons, shared by both arrangements.
    component Transport: Row {
        spacing: 2
        Repeater {
            model: [
                { glyph: "󰒮", ok: card.player?.canGoPrevious ?? false, act: () => card.player.previous() },
                { glyph: card.player?.isPlaying ? "󰏤" : "󰐊", ok: card.player?.canTogglePlaying ?? false, act: () => card.player.togglePlaying() },
                { glyph: "󰒭", ok: card.player?.canGoNext ?? false, act: () => card.player.next() }
            ]
            delegate: Item {
                required property var modelData
                width: 28
                height: 28
                opacity: modelData.ok ? 1 : 0.35
                Rectangle {
                    anchors.fill: parent
                    radius: 14
                    color: tap.containsMouse && parent.modelData.ok ? Theme.withAlpha(Theme.text, 0.12) : "transparent"
                }
                Icon {
                    anchors.centerIn: parent
                    text: parent.modelData.glyph
                    size: 17
                }
                MouseArea {
                    id: tap
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (parent.modelData.ok)
                        parent.modelData.act()
                }
            }
        }
    }

    ColumnLayout {
        visible: card.stacked
        Layout.fillWidth: true
        spacing: 6
        Rectangle {
            Layout.preferredWidth: card.artSize
            Layout.preferredHeight: card.artSize
            radius: 10
            color: Theme.withAlpha(Theme.text, 0.12)
            clip: true
            Icon {
                anchors.centerIn: parent
                visible: art2.status !== Image.Ready
                text: "󰎆"
                size: card.artSize * 0.42
                color: Theme.subtext
            }
            Image {
                id: art2
                anchors.fill: parent
                source: card.player?.trackArtUrl ?? ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }
        }
        Text {
            Layout.fillWidth: true
            text: card.player?.trackTitle || "Not Playing"
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 13
            font.weight: Font.DemiBold
            elide: Text.ElideRight
        }
        Text {
            Layout.fillWidth: true
            text: card.player?.trackArtist ?? ""
            visible: text !== ""
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            elide: Text.ElideRight
        }
        Transport {
            Layout.alignment: Qt.AlignHCenter
        }
    }

    RowLayout {
        visible: !card.stacked
        Layout.fillWidth: true
        spacing: 10

        Rectangle {
            Layout.preferredWidth: card.artSize
            Layout.preferredHeight: card.artSize
            radius: 9
            color: Theme.withAlpha(Theme.text, 0.12)
            clip: true

            Icon {
                anchors.centerIn: parent
                visible: art.status !== Image.Ready
                text: "󰎆"
                size: card.artSize * 0.42
                color: Theme.subtext
            }
            Image {
                id: art
                anchors.fill: parent
                source: card.player?.trackArtUrl ?? ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Text {
                Layout.fillWidth: true
                visible: card.showApp
                text: card.player?.identity ?? ""
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 10
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            Text {
                Layout.fillWidth: true
                text: card.player?.trackTitle || "Not playing"
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            Text {
                Layout.fillWidth: true
                text: card.player?.trackArtist ?? ""
                visible: text !== ""
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 12
                elide: Text.ElideRight
            }
        }

        Transport {}
    }

    // Scrubber.
    RowLayout {
        visible: !card.compact && !card.stacked && (card.player?.lengthSupported ?? false) && (card.player?.length ?? 0) > 0
        Layout.fillWidth: true
        spacing: 8

        Text {
            text: card.fmt(card.player?.position ?? 0)
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 10
            font.features: {
                "tnum": 1
            }
        }
        Item {
            Layout.fillWidth: true
            implicitHeight: 12
            readonly property real t: card.player && card.player.length > 0 ? Math.min(1, card.player.position / card.player.length) : 0
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: 4
                radius: 2
                color: Theme.withAlpha(Theme.text, 0.14)
            }
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width * parent.t
                height: 4
                radius: 2
                color: Theme.text
            }
            MouseArea {
                anchors.fill: parent
                enabled: card.player?.canSeek ?? false
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => card.player.position = mouse.x / width * card.player.length
            }
        }
        Text {
            text: card.fmt(card.player?.length ?? 0)
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 10
            font.features: {
                "tnum": 1
            }
        }
    }
}
