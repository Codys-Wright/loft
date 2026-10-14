import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Island media page: big art, title/artist/source, scrubber, transport.
Item {
    id: root

    property var player: null

    // MPRIS position isn't pushed; poll it while visible.
    Timer {
        interval: 1000
        running: root.visible && (root.player?.isPlaying ?? false)
        repeat: true
        onTriggered: root.player.positionChanged()
    }

    Text {
        anchors.centerIn: parent
        visible: !root.player
        text: "Nothing playing"
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 14
    }

    RowLayout {
        anchors.fill: parent
        anchors.bottomMargin: 8
        visible: root.player !== null
        spacing: 16

        Rectangle {
            Layout.preferredWidth: 120
            Layout.preferredHeight: 120
            Layout.alignment: Qt.AlignVCenter
            radius: 18
            clip: true
            color: Theme.withAlpha(Theme.text, 0.12)

            Image {
                anchors.fill: parent
                source: root.player?.trackArtUrl ?? ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 4

            Text {
                Layout.fillWidth: true
                text: root.player?.trackTitle || ""
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 15
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                text: [root.player?.trackArtist, root.player?.identity].filter(s => s).join("  ·  ")
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 12
                elide: Text.ElideRight
            }

            // Scrubber
            Item {
                Layout.fillWidth: true
                Layout.topMargin: 10
                Layout.preferredHeight: 18
                visible: (root.player?.lengthSupported ?? false) && root.player.length > 0

                readonly property real progress: visible ? root.player.position / root.player.length : 0

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 4
                    radius: 2
                    color: Theme.withAlpha(Theme.text, 0.18)

                    Rectangle {
                        width: parent.width * Math.max(0, Math.min(1, parent.parent.progress))
                        height: parent.height
                        radius: 2
                        color: Theme.text
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: root.player?.canSeek ?? false
                    cursorShape: Qt.PointingHandCursor
                    onClicked: mouse => root.player.position = root.player.length * mouse.x / width
                }
            }

            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 26

                Repeater {
                    model: [
                        { icon: "󰒮", act: () => root.player.previous(), enabled: root.player?.canGoPrevious ?? false },
                        { icon: root.player?.isPlaying ? "󰏤" : "󰐊", act: () => root.player.togglePlaying(), enabled: root.player?.canTogglePlaying ?? false },
                        { icon: "󰒭", act: () => root.player.next(), enabled: root.player?.canGoNext ?? false }
                    ]

                    delegate: Icon {
                        required property var modelData
                        text: modelData.icon
                        size: 24
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
}
