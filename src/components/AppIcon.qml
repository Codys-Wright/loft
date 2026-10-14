import QtQuick
import qs.services

// An app's icon that never shows Qt's magenta/black "missing image" pattern:
// it walks Apps.iconSources(appId) (themed names, absolute Icon=, pixmaps,
// a generic app icon) to the next candidate whenever one fails to load, and
// ends on a drawn glyph. `source` overrides the app lookup (a file icon).
Item {
    id: root

    property string appId: ""
    // Explicit candidates (e.g. a file's thumbnail, then its MIME icons).
    property var sources: null
    property int pixelSize: 128
    // The glyph when nothing loads: an app by default; files, folders and
    // the Trash pass their own.
    property string glyph: "󰀻"

    readonly property var candidates: sources ?? Apps.iconSources(appId)
    property int index: 0
    readonly property string current: index < candidates.length ? (candidates[index] ?? "") : ""
    readonly property bool ready: img.status === Image.Ready

    onCandidatesChanged: index = 0

    Image {
        id: img
        anchors.fill: parent
        visible: root.current !== "" && status === Image.Ready
        source: root.current
        sourceSize: Qt.size(root.pixelSize, root.pixelSize)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: true
        onStatusChanged: {
            // Errors (and image providers that hand back nothing) move on.
            if (status === Image.Error || (status === Image.Ready && (implicitWidth <= 0 || implicitHeight <= 0)))
                root.index = Math.min(root.index + 1, root.candidates.length);
        }
    }

    // Nothing loaded: a rounded tile with a generic glyph.
    Rectangle {
        anchors.fill: parent
        anchors.margins: parent.width * 0.08
        visible: root.current === ""
        radius: width * 0.22
        color: Theme.withAlpha(Theme.text, 0.12)
        border.width: 1
        border.color: Theme.withAlpha(Theme.text, 0.18)

        Icon {
            anchors.centerIn: parent
            text: root.glyph
            size: parent.width * 0.5
            color: Theme.subtext
        }
    }
}
