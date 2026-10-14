import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// The dock: pinned apps, then any other running apps (from niri), on a
// floating Liquid Glass shelf. Hovering shows the app name above the icon.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "studio:dock"
    anchors.bottom: true
    // Room above the shelf for magnified icons and the name label.
    implicitWidth: Math.max(shelf.width, nameTag.width) + 40
    implicitHeight: shelfHeight + 70
    exclusiveZone: shelfHeight + margin
    color: "transparent"

    readonly property int margin: 8
    readonly property int shelfHeight: Settings.dock.iconSize + 24

    // Pinned first, then running apps that aren't pinned (in window order).
    readonly property var apps: {
        const pinned = Array.from(Settings.dock.pinned);
        const running = [];
        for (const w of Niri.windows)
            if (w.app_id && !pinned.includes(w.app_id) && !running.includes(w.app_id))
                running.push(w.app_id);
        return { pinned: pinned, running: running };
    }

    property string hoveredLabel: ""
    property real hoveredX: 0

    // Only the shelf takes input; the transparent space above passes clicks through.
    mask: Region {
        item: shelf
    }

    BackgroundEffect.blurRegion: Theme.blur ? blur : null
    Region {
        id: blur
        item: shelf
        radius: shelf.radius

        Region {
            item: nameTag.visible ? nameTag : null
            radius: nameTag.radius
        }
    }

    GlassSurface {
        id: shelf
        anchors {
            bottom: parent.bottom
            bottomMargin: root.margin
            horizontalCenter: parent.horizontalCenter
        }
        height: root.shelfHeight
        width: row.implicitWidth + 24
        radius: Theme.radius + 8

        Behavior on width {
            NumberAnimation {
                duration: 140
                easing.type: Easing.OutCubic
            }
        }

        RowLayout {
            id: row
            anchors {
                horizontalCenter: parent.horizontalCenter
                bottom: parent.bottom
                bottomMargin: 12
            }
            spacing: 10

            Repeater {
                model: root.apps.pinned
                delegate: item
            }

            // Divider between pinned and running-only apps, like macOS.
            Rectangle {
                visible: root.apps.running.length > 0
                Layout.preferredWidth: 1
                Layout.preferredHeight: Settings.dock.iconSize * 0.8
                Layout.alignment: Qt.AlignVCenter
                color: Theme.glassBorder
            }

            Repeater {
                model: root.apps.running
                delegate: item
            }
        }
    }

    Component {
        id: item

        DockItem {
            required property string modelData
            appId: modelData
            Layout.alignment: Qt.AlignBottom
            onHoverChanged: hovered => {
                if (hovered) {
                    root.hoveredLabel = label;
                    root.hoveredX = mapToItem(root.contentItem, width / 2, 0).x;
                } else if (root.hoveredLabel === label) {
                    root.hoveredLabel = "";
                }
            }
        }
    }

    // App name above the hovered icon.
    GlassSurface {
        id: nameTag
        visible: root.hoveredLabel !== ""
        height: 28
        width: labelText.implicitWidth + 24
        radius: height / 2
        x: Math.max(0, Math.min(root.width - width, root.hoveredX - width / 2))
        anchors {
            bottom: shelf.top
            bottomMargin: Settings.dock.iconSize * (Settings.dock.magnification - 1) + 10
        }

        Text {
            id: labelText
            anchors.centerIn: parent
            text: root.hoveredLabel
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 13
            font.weight: Font.Medium
        }
    }
}
