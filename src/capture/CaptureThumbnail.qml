import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// The floating thumbnail after a capture (bottom-right, like macOS):
// click → annotate (screenshots) or open (recordings); drag it out to drop
// the file into another app; hover for Pin / GIF / Trim & Zoom / Delete; it slides
// away after a few seconds unless the pointer is on it.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property var item: Capture.thumbnail
    readonly property bool onThisScreen: Capture.screenFocused?.name === modelData.name
    readonly property bool shown: item !== null && onThisScreen
    readonly property bool isVideo: item?.kind === "video"

    visible: (shown || Capture.busy !== "") && onThisScreen && !Capture.panoramaRunning
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:capture-thumbnail"
    exclusionMode: ExclusionMode.Ignore
    anchors {
        bottom: true
        right: true
    }
    margins {
        bottom: 24
        right: 24
    }
    implicitWidth: 280
    implicitHeight: 260
    color: "transparent"

    mask: Region {
        item: root.shown ? card : busy
    }
    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur ? (root.shown ? card : busy) : null
        radius: root.shown ? card.radius : busy.radius
    }

    // Fresh capture: slide in, restart the clock.
    onItemChanged: {
        if (item) {
            card.slide = 1;
            slideIn.restart();
            dismiss.restart();
        }
    }

    Timer {
        id: dismiss
        interval: 6000
        running: root.shown && !hover.hovered && !dragArea.drag.active
        onTriggered: Capture.thumbnail = null
    }

    component Action: Rectangle {
        id: act
        property string icon
        property string tip
        property color tint: Theme.text
        signal clicked

        width: 30
        height: 30
        radius: 15
        color: actMouse.containsMouse ? Theme.withAlpha(Theme.bg, 0.9) : Theme.withAlpha(Theme.bg, 0.7)
        border.width: 1
        border.color: Theme.glassBorder

        Icon {
            anchors.centerIn: parent
            text: act.icon
            size: 14
            color: act.tint
        }
        MouseArea {
            id: actMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: act.clicked()
        }
    }

    // Post-processing in progress (GIF export, trim).
    GlassSurface {
        id: busy
        visible: Capture.busy !== ""
        anchors {
            right: parent.right
            bottom: root.shown ? card.top : parent.bottom
            bottomMargin: root.shown ? 10 : 0
        }
        width: busyText.implicitWidth + 28
        height: 30
        radius: 15
        strength: 1.8

        Text {
            id: busyText
            anchors.centerIn: parent
            text: Capture.busy
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 12
            font.weight: Font.Medium
        }
    }

    GlassSurface {
        id: card
        visible: root.shown
        property real slide: 0
        // Slides with a margin, not a transform: the input/blur regions
        // follow geometry changes only.
        anchors {
            right: parent.right
            bottom: parent.bottom
            rightMargin: -slide * 260
        }
        readonly property real aspect: shot.implicitWidth > 0 ? shot.implicitHeight / shot.implicitWidth : 0.6
        width: 220
        height: Math.max(90, Math.min(200, (width - 12) * aspect)) + 12
        radius: 14
        strength: 1.8
        opacity: 1 - slide

        NumberAnimation {
            id: slideIn
            target: card
            property: "slide"
            from: 1
            to: 0
            duration: 380
            easing.type: Easing.OutQuint
        }

        HoverHandler {
            id: hover
        }

        RoundedClip {
            id: clip
            anchors {
                fill: parent
                margins: 6
            }
            radius: 9

            Rectangle {
                anchors.fill: parent
                color: Theme.overlay
            }

            Image {
                id: shot
                anchors.fill: parent
                source: root.item?.poster ? "file://" + root.item.poster : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: false
                sourceSize.width: 440
            }

            // Recording: a play badge.
            Rectangle {
                visible: root.isVideo
                anchors.centerIn: parent
                width: 40
                height: 40
                radius: 20
                color: Qt.rgba(0, 0, 0, 0.45)

                Icon {
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: 2
                    text: "󰐊"
                    size: 20
                    color: "white"
                }
            }
        }

        // Click: annotate / open. Drag: hand the file to another app.
        MouseArea {
            id: dragArea
            anchors.fill: clip
            cursorShape: drag.active ? Qt.ClosedHandCursor : Qt.PointingHandCursor
            drag.target: proxy
            onClicked: {
                const it = root.item;
                if (!it)
                    return;
                if (root.isVideo) {
                    Capture.thumbnail = null;
                    Capture.open(it.path);
                } else {
                    Capture.annotate(it.path);
                }
            }
            onReleased: proxy.Drag.drop()
        }

        Item {
            id: proxy
            width: 1
            height: 1
            Drag.active: dragArea.drag.active
            Drag.dragType: Drag.Automatic
            Drag.supportedActions: Qt.CopyAction
            Drag.imageSource: shot.source
            Drag.mimeData: ({
                    "text/uri-list": root.item ? "file://" + encodeURI(root.item.path) + "\r\n" : "",
                    "text/plain": root.item?.path ?? ""
                })
            Drag.onDragFinished: action => {
                if (action !== Qt.IgnoreAction)
                    Capture.thumbnail = null;
            }
        }

        // Hover actions.
        Item {
            anchors.fill: parent
            visible: hover.hovered && !dragArea.drag.active

            Action {
                anchors {
                    left: parent.left
                    top: parent.top
                    margins: 10
                }
                icon: "󰅖"
                tip: "Dismiss"
                onClicked: Capture.thumbnail = null
            }

            Row {
                anchors {
                    right: parent.right
                    bottom: parent.bottom
                    margins: 10
                }
                spacing: 6

                Action {
                    visible: !root.isVideo
                    icon: "󰏫"
                    tip: "Annotate"
                    onClicked: Capture.annotate(root.item.path)
                }
                Action {
                    visible: !root.isVideo
                    icon: "󰐃"
                    tip: "Pin"
                    onClicked: Capture.pin(root.item.path)
                }
                Action {
                    visible: root.isVideo
                    icon: "󰆐"
                    tip: "Trim & Zoom"
                    onClicked: Capture.startTrim(root.item.path)
                }
                Action {
                    visible: root.isVideo
                    icon: "󰵸"
                    tip: "Export GIF"
                    onClicked: Capture.exportGif(root.item.path)
                }
                Action {
                    icon: "󰆴"
                    tip: "Delete"
                    tint: Theme.urgent
                    onClicked: Capture.trash(root.item.path)
                }
            }
        }
    }
}
