import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.components
import qs.services

// Wallpaper picker (javiiervm's WallpaperCarousel, reworked): a glass
// carousel of the images in Settings.wallpaper.directory along the bottom of
// the focused screen. Arrows / scroll to browse, Enter or click to apply,
// Escape to close; "Theme" goes back to the theme's own wallpaper.
// The choice is a runtime override (Settings.wallpaper.path), so it persists.
// IPC: wallpaper toggle|next|prev.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property bool onThisScreen: (Niri.focusedWorkspace?.output ?? modelData.name) === modelData.name
    readonly property bool open: Panels.wallpaperPickerOpen && onThisScreen

    visible: open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "studio:wallpaper-picker"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        bottom: true
        left: true
        right: true
    }
    margins.bottom: 100
    implicitHeight: 230
    color: "transparent"

    mask: Region {
        item: panel
    }
    BackgroundEffect.blurRegion: Theme.blur && open ? blur : null
    Region {
        id: blur
        item: panel
        radius: panel.radius
    }

    readonly property string directory: {
        const d = Settings.wallpaper.directory;
        return d.startsWith("~/") ? Quickshell.env("HOME") + d.slice(1) : d;
    }

    function apply(path) {
        Settings.wallpaper.path = path;
    }

    FolderListModel {
        id: images
        folder: "file://" + root.directory
        nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.webp", "*.JPG", "*.PNG"]
        showDirs: false
        sortField: FolderListModel.Name
    }

    GlassSurface {
        id: panel
        anchors {
            fill: parent
            leftMargin: 120
            rightMargin: 120
        }
        radius: 30
        strength: 1.5

        focus: root.open
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape)
                Panels.wallpaperPickerOpen = false;
            else if (event.key === Qt.Key_Right)
                list.incrementCurrentIndex();
            else if (event.key === Qt.Key_Left)
                list.decrementCurrentIndex();
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                root.apply(images.get(list.currentIndex, "filePath"));
        }

        ColumnLayout {
            anchors {
                fill: parent
                margins: 16
            }
            spacing: 10

            RowLayout {
                Layout.fillWidth: true

                Text {
                    Layout.fillWidth: true
                    text: `Wallpapers  ·  ${images.count}`
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                }

                Text {
                    text: Settings.wallpaper.path ? "Use theme wallpaper" : "Using theme wallpaper"
                    color: Settings.wallpaper.path ? Theme.accent : Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 12

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -6
                        enabled: Settings.wallpaper.path !== ""
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.apply("")
                    }
                }
            }

            Text {
                visible: images.count === 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: `No images in ${Settings.wallpaper.directory}`
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 13
            }

            ListView {
                id: list
                visible: images.count > 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                orientation: ListView.Horizontal
                spacing: 12
                clip: true
                model: images
                highlightMoveDuration: 200
                preferredHighlightBegin: width / 2 - 120
                preferredHighlightEnd: width / 2 + 120
                highlightRangeMode: ListView.ApplyRange

                delegate: Item {
                    id: thumb
                    required property string filePath
                    required property string fileName
                    required property int index
                    readonly property bool current: ListView.isCurrentItem
                    readonly property bool applied: Settings.wallpaper.path === filePath

                    width: 240
                    height: ListView.view.height

                    Rectangle {
                        id: frame
                        anchors.fill: parent
                        anchors.margins: thumb.current ? 0 : 6
                        radius: 18
                        color: Theme.overlay
                        clip: true
                        border.width: thumb.applied ? 3 : thumb.current ? 2 : 0
                        border.color: thumb.applied ? Theme.accent : Theme.text

                        Behavior on anchors.margins {
                            NumberAnimation {
                                duration: 150
                            }
                        }

                        Image {
                            anchors.fill: parent
                            anchors.margins: frame.border.width
                            source: "file://" + thumb.filePath
                            sourceSize: Qt.size(480, 270)
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: list.currentIndex = thumb.index
                        onClicked: root.apply(thumb.filePath)
                    }
                }
            }
        }
    }

    IpcHandler {
        target: "wallpaper"

        function toggle(): void {
            Panels.wallpaperPickerOpen = !Panels.wallpaperPickerOpen;
        }

        function next(): void {
            if (images.count === 0)
                return;
            const i = (Math.max(0, images.indexOf("file://" + Settings.wallpaper.path)) + 1) % images.count;
            root.apply(images.get(i, "filePath"));
        }

        function prev(): void {
            if (images.count === 0)
                return;
            const i = (Math.max(0, images.indexOf("file://" + Settings.wallpaper.path)) - 1 + images.count) % images.count;
            root.apply(images.get(i, "filePath"));
        }
    }
}
