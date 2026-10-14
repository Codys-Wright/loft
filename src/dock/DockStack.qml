import QtQuick
import qs.components
import qs.services

// A docked folder (Downloads by default): as a Stack, its newest items
// piled up (thumbnails when there are), as a Folder, the folder's icon.
// Click opens the stack popup (fan / grid / list).
DockTile {
    id: root

    required property int folderIndex
    property var folder: ({})
    readonly property var folderSource: DockData.folder(folder.path ?? "")
    readonly property bool asStack: (folder.display ?? "stack") === "stack"
    readonly property var newest: (folderSource?.items ?? []).slice(0, 3)

    label: folderSource?.listing?.name || (folder.path ?? "")

    // Folder: its icon.
    AppIcon {
        anchors.fill: parent
        visible: !root.asStack || root.newest.length === 0
        sources: DockData.folderIcons(root.folder.path ?? "")
    }

    // Stack: up to three items, the newest on top, fanned a little.
    Repeater {
        model: root.asStack ? root.newest.slice().reverse() : []

        delegate: Item {
            required property var modelData
            required property int index
            readonly property int depth: root.newest.length - 1 - index
            width: parent.width * 0.86
            height: width
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -depth * parent.height * 0.05
            rotation: depth === 0 ? 0 : (depth % 2 ? -7 : 6)
            opacity: depth === 0 ? 1 : 0.9

            Rectangle {
                anchors.fill: parent
                visible: modelData.thumb !== undefined
                radius: 6
                color: "white"
                border.width: 1
                border.color: Theme.withAlpha("#000000", 0.25)
            }
            AppIcon {
                anchors.fill: parent
                anchors.margins: modelData.thumb !== undefined ? 3 : 0
                sources: DockData.fileIcons(modelData)
            }
        }
    }
}
