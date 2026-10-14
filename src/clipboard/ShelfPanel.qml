import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services
import "glyphs.js" as G

// The Shelf: a glass tray at the screen edge to park files, links and text.
//
// - Drag something to the shelf's edge (a thin strip in the middle of the
//   right edge, or the handle once it holds items) and it slides out; drop
//   it there. Wayland only tells a client about a drag once the pointer is
//   over one of its surfaces, so the strip is what lets the shell notice.
// - Drag items back out to drop them in another app (text/uri-list for
//   files, text/plain for links and text), or copy / open them.
// - IPC `shelf toggle` opens it without dragging; `shelf addClipboard`
//   parks what's on the clipboard.
// Data: services/Shelf.qml (persisted).
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property bool onThisScreen: (Niri.focusedWorkspace?.output ?? modelData.name) === modelData.name
    readonly property bool onLeft: ClipboardConfig.shelf.edge === "left"
    readonly property bool hasItems: Shelf.items.length > 0
    readonly property bool reveal: ClipboardConfig.shelf.revealOnDrag

    // A drag is over this screen's shelf (or just left it, see collapse).
    property bool dragHover: false
    // Opened by a drag rather than explicitly.
    readonly property bool expanded: (Shelf.open && onThisScreen) || dragHover || collapse.running

    readonly property int panelWidth: 300
    readonly property int panelHeight: Math.min(560, Math.round(modelData.height * 0.7))

    visible: expanded || hasItems || reveal
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "loft:shelf"
    WlrLayershell.keyboardFocus: Shelf.open && onThisScreen ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        left: root.onLeft
        right: !root.onLeft
    }
    implicitWidth: expanded ? panelWidth + 16 : hasItems ? 14 : 3
    implicitHeight: expanded ? panelHeight : hasItems ? 96 : Math.round(modelData.height * 0.4)
    color: "transparent"

    BackgroundEffect.blurRegion: Theme.blur && expanded ? blur : null
    Region {
        id: blur
        item: panel
        radius: panel.radius
    }

    // Leaving the shelf mid-drag: stay out a moment (the pointer often
    // overshoots the edge), then slide back unless something was dropped.
    Timer {
        id: collapse
        interval: 700
    }

    function iconFor(item) {
        if (item.kind === "url")
            return G.link;
        if (item.kind === "text")
            return G.text;
        if (/\.(png|jpe?g|webp|gif|bmp|svg|avif)$/i.test(item.value))
            return G.image;
        if (!/\.[a-z0-9]{1,5}$/i.test(item.name))
            return G.folder;
        return G.file;
    }

    function isImageFile(item) {
        return item.kind === "file" && /\.(png|jpe?g|webp|gif|bmp|avif)$/i.test(item.value);
    }

    function mimeFor(item) {
        if (item.kind === "file") {
            const uri = Shelf.uriOf(item);
            return {
                "text/uri-list": uri + "\r\n",
                "text/plain": item.value
            };
        }
        if (item.kind === "url")
            return {
                "text/uri-list": item.value + "\r\n",
                "text/x-moz-url": item.value,
                "text/plain": item.value
            };
        return {
            "text/plain": item.value
        };
    }

    // A small icon button in the header.
    component HeaderButton: Icon {
        id: hb
        signal clicked
        property string tip
        size: 15
        color: hbMouse.containsMouse ? Theme.text : Theme.subtext
        MouseArea {
            id: hbMouse
            anchors.fill: parent
            anchors.margins: -5
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: hb.clicked()
        }
    }

    // The collapsed edge: a drop sensor, plus a handle when items are parked.
    DropArea {
        anchors.fill: parent
        enabled: !root.expanded
        onEntered: drag => {
            root.dragHover = true;
            drag.accept(Qt.CopyAction);
        }
    }

    Rectangle {
        visible: !root.expanded && root.hasItems
        anchors {
            right: root.onLeft ? undefined : parent.right
            left: root.onLeft ? parent.left : undefined
            verticalCenter: parent.verticalCenter
        }
        width: 8
        height: 80
        radius: 4
        color: Theme.withAlpha(Theme.accent, handleMouse.containsMouse ? 0.9 : 0.6)

        MouseArea {
            id: handleMouse
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: Shelf.open = true
        }
    }

    GlassSurface {
        id: panel
        visible: root.expanded
        width: root.panelWidth
        height: parent.height
        x: root.onLeft ? 8 : parent.width - width - 8
        radius: 22
        strength: dropArea.containsDrag ? 2.2 : 1.6

        Keys.onEscapePressed: Shelf.open = false
        focus: Shelf.open && root.onThisScreen

        DropArea {
            id: dropArea
            anchors.fill: parent
            onEntered: drag => {
                root.dragHover = true;
                collapse.stop();
                drag.accept(Qt.CopyAction);
            }
            onExited: {
                root.dragHover = false;
                if (!Shelf.open)
                    collapse.restart();
            }
            onDropped: drop => {
                root.dragHover = false;
                if (Shelf.addDrop(drop) > 0 || root.hasItems)
                    Shelf.open = true;
                drop.accept(Qt.CopyAction);
            }
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: 6
            radius: parent.radius - 6
            visible: dropArea.containsDrag
            color: Theme.withAlpha(Theme.accent, 0.12)
            border.width: 2
            border.color: Theme.withAlpha(Theme.accent, 0.7)
        }

        ColumnLayout {
            anchors {
                fill: parent
                margins: 12
            }
            spacing: 8

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Icon {
                    text: G.tray
                    size: 16
                    color: Theme.accent
                }
                Text {
                    Layout.fillWidth: true
                    text: Shelf.items.length > 0 ? `Shelf · ${Shelf.items.length}` : "Shelf"
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 14
                    font.weight: Font.DemiBold
                }

                HeaderButton {
                    text: G.paste
                    onClicked: Shelf.addClipboard()
                }
                HeaderButton {
                    visible: root.hasItems
                    text: G.sweep
                    onClicked: Shelf.clear()
                }
                HeaderButton {
                    text: G.close
                    onClicked: {
                        Shelf.open = false;
                        collapse.stop();
                    }
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                ColumnLayout {
                    anchors.centerIn: parent
                    visible: !root.hasItems
                    spacing: 8
                    Icon {
                        Layout.alignment: Qt.AlignHCenter
                        text: G.tray
                        size: 34
                        color: Theme.withAlpha(Theme.subtext, 0.6)
                    }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        horizontalAlignment: Text.AlignHCenter
                        text: "Drop files, links or text here.\nDrag them out when you get there."
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                    }
                }

                ListView {
                    anchors.fill: parent
                    clip: true
                    spacing: 6
                    model: Shelf.items
                    boundsBehavior: Flickable.StopAtBounds

                    delegate: Rectangle {
                        id: card
                        required property var modelData
                        width: ListView.view.width
                        height: 52
                        radius: 12
                        color: dragMouse.containsMouse ? Theme.withAlpha(Theme.text, 0.12) : Theme.withAlpha(Theme.text, 0.06)

                        // What actually gets dragged out (Drag.Automatic starts a
                        // system drag-and-drop with this mime data).
                        Item {
                            id: proxy
                            width: card.width
                            height: card.height
                            Drag.active: dragMouse.drag.active
                            Drag.dragType: Drag.Automatic
                            Drag.supportedActions: Qt.CopyAction | Qt.LinkAction
                            Drag.proposedAction: Qt.CopyAction
                            Drag.mimeData: root.mimeFor(card.modelData)
                            Drag.imageSource: root.isImageFile(card.modelData) ? "file://" + card.modelData.value : ""
                            Drag.hotSpot.x: 20
                            Drag.hotSpot.y: 20
                        }

                        MouseArea {
                            id: dragMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            drag.target: proxy
                            cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.OpenHandCursor
                            onDoubleClicked: Shelf.openItem(card.modelData)
                            // Snap the proxy back for the next drag.
                            onReleased: {
                                proxy.x = 0;
                                proxy.y = 0;
                            }
                        }

                        RowLayout {
                            anchors {
                                fill: parent
                                leftMargin: 8
                                rightMargin: 10
                            }
                            spacing: 10

                            Rectangle {
                                Layout.preferredWidth: 36
                                Layout.preferredHeight: 36
                                radius: 9
                                color: Theme.withAlpha(Theme.text, 0.08)
                                clip: true

                                Icon {
                                    anchors.centerIn: parent
                                    visible: thumb.status !== Image.Ready
                                    text: root.iconFor(card.modelData)
                                    size: 18
                                    color: card.modelData.kind === "url" ? Theme.accent : Theme.subtext
                                }
                                Image {
                                    id: thumb
                                    anchors.fill: parent
                                    source: root.isImageFile(card.modelData) ? "file://" + card.modelData.value : ""
                                    sourceSize: Qt.size(72, 72)
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1
                                Text {
                                    Layout.fillWidth: true
                                    text: card.modelData.name
                                    color: Theme.text
                                    font.family: Theme.fontUi
                                    font.pixelSize: 12
                                    font.weight: Font.Medium
                                    elide: Text.ElideMiddle
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: card.modelData.kind === "file" ? card.modelData.value.replace(Quickshell.env("HOME"), "~").replace(/\/[^/]*$/, "") || "/" : card.modelData.kind === "url" ? "Link" : `Text · ${card.modelData.value.length} characters`
                                    color: Theme.subtext
                                    font.family: Theme.fontUi
                                    font.pixelSize: 10
                                    elide: Text.ElideMiddle
                                }
                            }

                            Icon {
                                visible: dragMouse.containsMouse || copyMouse.containsMouse || rmMouse.containsMouse
                                text: G.copy
                                size: 13
                                color: copyMouse.containsMouse ? Theme.text : Theme.subtext
                                MouseArea {
                                    id: copyMouse
                                    anchors.fill: parent
                                    anchors.margins: -5
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Shelf.copy(card.modelData)
                                }
                            }
                            Icon {
                                visible: dragMouse.containsMouse || copyMouse.containsMouse || rmMouse.containsMouse
                                text: G.close
                                size: 13
                                color: rmMouse.containsMouse ? Theme.urgent : Theme.subtext
                                MouseArea {
                                    id: rmMouse
                                    anchors.fill: parent
                                    anchors.margins: -5
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Shelf.remove(card.modelData.id)
                                }
                            }
                        }
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                visible: root.hasItems
                text: "Drag out to drop · double-click to open"
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 10
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }
}
