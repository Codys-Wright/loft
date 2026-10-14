import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.components
import qs.services

// Wallpaper picker (javiiervm's WallpaperCarousel, reworked): a glass
// carousel along the bottom of the focused screen with the theme's vibe set
// (Vibes): its own and curated wallpapers first, then other installed packs'
// and the wallpaper folder's images, closest colors first. Arrows / scroll
// to browse, Enter or click to apply, Escape to close; "Use theme
// wallpaper" goes back to the theme's default. The choice is remembered per
// theme (Settings.perTheme). IPC: wallpaper toggle|next|prev.
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

    // Video-only entries (no still) can't be shown by the image layer.
    readonly property var items: Vibes.themeWallpapers.concat(Vibes.matchingWallpapers).filter(w => w.kind === "image")

    function apply(path) {
        Vibes.chooseWallpaper(path);
    }

    onOpenChanged: if (open) {
        Vibes.refresh();
        const i = items.findIndex(w => Vibes.isCurrentWallpaper(w.path));
        list.currentIndex = Math.max(0, i);
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
                root.apply(root.items[list.currentIndex]?.path ?? "");
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
                    text: `Wallpapers for ${Vibes.theme}  ·  ${Vibes.themeWallpapers.length} + ${Vibes.matchingWallpapers.length} matching`
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                }

                Text {
                    text: Vibes.chosenWallpaper ? "Use theme wallpaper" : "Using theme wallpaper"
                    color: Vibes.chosenWallpaper ? Theme.accent : Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 12

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -6
                        enabled: Vibes.chosenWallpaper !== ""
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.apply("")
                    }
                }
            }

            Text {
                visible: root.items.length === 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: Vibes.loading ? "Loading…" : `No wallpapers: the theme has none and ${Settings.wallpaper.directory} is empty`
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 13
            }

            ListView {
                id: list
                visible: root.items.length > 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                orientation: ListView.Horizontal
                spacing: 12
                clip: true
                model: root.items
                highlightMoveDuration: 200
                preferredHighlightBegin: width / 2 - 120
                preferredHighlightEnd: width / 2 + 120
                highlightRangeMode: ListView.ApplyRange

                delegate: Item {
                    id: thumb
                    required property var modelData
                    required property int index
                    readonly property bool current: ListView.isCurrentItem
                    readonly property bool applied: Vibes.isCurrentWallpaper(modelData.path)
                    readonly property string caption: modelData.origin === "own" ? Vibes.theme : modelData.origin === "curated" ? "curated · " + modelData.source_pack : `${modelData.source_pack || "folder"} · ${Math.round((modelData.score ?? 0) * 100)}%`

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
                            source: Vibes.url(thumb.modelData.path)
                            sourceSize: Qt.size(480, 270)
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                        }

                        // Where it comes from: the theme, a curated link, or a match.
                        Rectangle {
                            anchors {
                                left: parent.left
                                bottom: parent.bottom
                                margins: 10
                            }
                            width: cap.implicitWidth + 14
                            height: 20
                            radius: 10
                            color: thumb.modelData.origin === "match" ? Theme.withAlpha("#000000", 0.55) : Theme.withAlpha(Theme.accent, 0.9)

                            Text {
                                id: cap
                                anchors.centerIn: parent
                                text: thumb.caption
                                color: thumb.modelData.origin === "match" ? "white" : Theme.bg
                                font.family: Theme.fontUi
                                font.pixelSize: 10
                                font.weight: Font.DemiBold
                            }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onEntered: list.currentIndex = thumb.index
                        onClicked: root.apply(thumb.modelData.path)
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
            Vibes.cycle(1);
        }

        function prev(): void {
            Vibes.cycle(-1);
        }
    }
}
