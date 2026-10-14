import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// A floating camera mirror (round or rounded square) above all windows —
// for checking your look before a call or for screen recordings. Drag to
// move, scroll to resize; hover for shape / flip / close. With no camera
// (or no QtMultimedia) it says so instead of a picture.
// IPC: camera toggle|on|off; the island has a Camera page while it's on.
PanelWindow {
    id: root

    readonly property var cfg: Capture.cfg
    // The screen it was opened on (it doesn't follow focus).
    screen: Quickshell.screens.find(s => s.name === Capture.cameraScreen) ?? Capture.screenFocused

    visible: Capture.cameraOn
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "studio:camera"
    exclusionMode: ExclusionMode.Ignore
    anchors {
        bottom: true
        left: true
    }
    property point offset: Qt.point(28, 28)
    margins {
        left: Math.round(offset.x)
        bottom: Math.round(offset.y)
    }
    readonly property int size: Math.max(120, Math.min(520, cfg.cameraSize))
    readonly property real shapeRadius: cfg.cameraShape === "circle" ? size / 2 : 28
    implicitWidth: size
    implicitHeight: cfg.cameraShape === "circle" ? size : Math.round(size * 0.75)
    color: "transparent"

    mask: Region {
        item: frame
        radius: root.shapeRadius
    }
    BackgroundEffect.blurRegion: Theme.blur ? blur : null
    Region {
        id: blur
        item: frame
        radius: root.shapeRadius
    }

    onVisibleChanged: if (!visible)
        Capture.cameraState = "unavailable"

    GlassSurface {
        id: frame
        anchors.fill: parent
        radius: root.shapeRadius
        strength: 1.6
        showHighlight: false

        HoverHandler {
            id: hover
        }

        RoundedClip {
            anchors {
                fill: parent
                margins: 4
            }
            radius: Math.max(0, root.shapeRadius - 4)

            Loader {
                id: view
                anchors.fill: parent
                active: root.visible
                source: "CameraView.qml"
                onLoaded: {
                    item.mirrored = Qt.binding(() => root.cfg.cameraMirror);
                    item.device = Qt.binding(() => root.cfg.cameraDevice);
                }
            }
        }

        // State → Capture (island page, settings).
        Binding {
            target: Capture
            property: "cameraState"
            value: view.status === Loader.Error ? "unavailable" : view.item?.state ?? "starting"
            when: root.visible
        }
        Binding {
            target: Capture
            property: "cameraName"
            value: view.item?.deviceName ?? ""
            when: root.visible
        }
        Binding {
            target: Capture
            property: "cameraError"
            value: view.item?.errorString ?? ""
            when: root.visible
        }
        Binding {
            target: Capture
            property: "cameraDevices"
            value: view.item?.deviceNames ?? []
            when: root.visible && view.item !== null
        }

        // No picture: why.
        Column {
            anchors.centerIn: parent
            visible: Capture.cameraState !== "live"
            spacing: 6
            width: parent.width - 32

            Icon {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Capture.cameraState === "starting" ? "󰄀" : "󰗟"
                size: 30
                color: Theme.subtext
            }
            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: {
                    switch (Capture.cameraState) {
                    case "none":
                        return "No camera";
                    case "unavailable":
                        return "Camera preview unavailable";
                    case "error":
                        return Capture.cameraError || "Camera error";
                    default:
                        return "Starting camera…";
                    }
                }
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.weight: Font.Medium
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            property point grab
            onPressed: mouse => grab = Qt.point(mouse.x, mouse.y)
            onPositionChanged: mouse => {
                if (pressed)
                    root.offset = Qt.point(Math.max(0, root.offset.x + mouse.x - grab.x), Math.max(0, root.offset.y - (mouse.y - grab.y)));
            }
            onWheel: wheel => root.cfg.cameraSize = Math.round(root.size * (wheel.angleDelta.y > 0 ? 1.08 : 1 / 1.08))
        }

        // Hover controls.
        Row {
            visible: hover.hovered
            anchors {
                horizontalCenter: parent.horizontalCenter
                bottom: parent.bottom
                bottomMargin: root.cfg.cameraShape === "circle" ? 18 : 12
            }
            spacing: 6

            Repeater {
                model: [
                    {
                        icon: root.cfg.cameraShape === "circle" ? "󰆟" : "󰄰",
                        act: "shape"
                    },
                    {
                        icon: "󰓡",
                        act: "flip"
                    },
                    {
                        icon: "󰅖",
                        act: "close"
                    }
                ]
                delegate: Rectangle {
                    id: b
                    required property var modelData
                    width: 28
                    height: 28
                    radius: 14
                    color: bMouse.containsMouse ? Theme.withAlpha(Theme.bg, 0.95) : Theme.withAlpha(Theme.bg, 0.7)
                    border.width: 1
                    border.color: Theme.glassBorder

                    Icon {
                        anchors.centerIn: parent
                        text: b.modelData.icon
                        size: 13
                    }
                    MouseArea {
                        id: bMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (b.modelData.act === "shape")
                                root.cfg.cameraShape = root.cfg.cameraShape === "circle" ? "rounded" : "circle";
                            else if (b.modelData.act === "flip")
                                root.cfg.cameraMirror = !root.cfg.cameraMirror;
                            else
                                Capture.cameraOn = false;
                        }
                    }
                }
            }
        }
    }
}
