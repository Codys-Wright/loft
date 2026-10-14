import QtQuick
import QtQuick.Effects
import qs.services

// Round user picture. Tries `sources` in order (e.g. ~/.face, then the
// AccountsService icon) and falls back to the initial on an accent disc.
Item {
    id: root

    property var sources: []
    property string name: ""

    property int attempt: 0
    readonly property string source: attempt < sources.length ? sources[attempt] : ""
    readonly property bool hasImage: picture.status === Image.Ready

    onSourcesChanged: attempt = 0

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        visible: !root.hasImage
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.accent }
            GradientStop { position: 1.0; color: Theme.accent2 }
        }

        Text {
            anchors.centerIn: parent
            text: root.name.length > 0 ? root.name[0].toUpperCase() : "?"
            color: Theme.bg
            font.family: Theme.fontUi
            font.pixelSize: root.height * 0.42
            font.weight: Font.DemiBold
        }
    }

    Image {
        id: picture
        anchors.fill: parent
        visible: false
        source: root.source
        sourceSize: Qt.size(width * 2, height * 2)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        onStatusChanged: if (status === Image.Error)
            root.attempt++
    }

    Rectangle {
        id: circle
        anchors.fill: parent
        radius: width / 2
        visible: false
        layer.enabled: true
    }

    MultiEffect {
        anchors.fill: parent
        visible: root.hasImage
        source: picture
        maskEnabled: true
        maskSource: circle
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1.0
    }

    // Hairline ring so a dark photo still reads against a dark wallpaper.
    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: "transparent"
        border.width: 1
        border.color: Theme.glassBorder
    }
}
