import QtQuick
import qs.services

// A static miniature of a lock screen, for designs without a preview image:
// the design's backdrop (its background, else its pack's wallpaper), a clock,
// an avatar and a password pill in the source pack's colors. Not the real
// design (that runs only when locked; "Preview lock" shows it), but enough to
// judge whether it fits.
Item {
    id: card

    // { bg, surface, text, subtext, accent, accent2, polarity }
    property var colors: ({})
    property string background: ""
    // The built-in design draws a frosted card; pack designs a bare pill.
    property bool frosted: false

    anchors.fill: parent

    readonly property color bg: colors.bg ?? Theme.bg
    readonly property color fg: colors.text ?? Theme.text
    readonly property color accent: colors.accent ?? Theme.accent
    readonly property color surface: colors.surface ?? Theme.surface

    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0; color: card.bg }
            GradientStop { position: 1; color: Qt.darker(card.surface, 1.1) }
        }
    }

    Image {
        anchors.fill: parent
        visible: card.background !== "" && status === Image.Ready
        source: Vibes.url(card.background)
        sourceSize: Qt.size(320, 180)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
    }

    // Scrim, like the real lock's.
    Rectangle {
        anchors.fill: parent
        color: Theme.withAlpha(card.bg, card.background !== "" ? 0.3 : 0)
    }

    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.12
        spacing: 0

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Tuesday, 14 October"
            color: card.fg
            font.family: Theme.fontUi
            font.pixelSize: 6
            opacity: 0.85
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "9:41"
            color: card.fg
            font.family: Theme.fontUi
            font.pixelSize: 24
            font.weight: Font.DemiBold
        }
    }

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.52
        width: parent.width * 0.42
        height: parent.height * 0.4
        radius: 8
        visible: card.frosted
        color: Theme.withAlpha(card.bg, 0.45)
        border.width: 1
        border.color: Theme.withAlpha("#ffffff", 0.18)
    }

    Rectangle {
        id: avatar
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height * 0.57
        width: 15
        height: 15
        radius: 7.5
        color: card.accent
        border.width: 1
        border.color: Theme.withAlpha(card.fg, 0.5)
    }

    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: avatar.bottom
        anchors.topMargin: 6
        width: parent.width * 0.34
        height: 8
        radius: 4
        color: Theme.withAlpha(card.surface, 0.75)
        border.width: 1
        border.color: Theme.withAlpha(card.accent, 0.8)
    }
}
