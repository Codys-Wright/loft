import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// The capture selector (macOS ⌘⇧5): a glass toolbar at the bottom center
// of the focused screen. Screenshot (screen / window / area) · Record
// (screen / area) · Text · Color, an Options menu (save location, timer,
// thumbnail, clipboard, annotate, pointer, audio, color format) and the
// Capture button. Recent picked colors show above it in Color mode.
// Enter captures, Escape closes.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property bool shown: Capture.selectorOpen && Capture.screenFocused?.name === modelData.name
    property bool optionsOpen: false

    visible: shown
    onShownChanged: optionsOpen = false

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "studio:capture-selector"
    WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors.bottom: true
    margins.bottom: 112
    implicitWidth: 900
    implicitHeight: 460
    color: "transparent"

    readonly property var cfg: Capture.cfg

    mask: Region {
        item: bar
        Region {
            item: root.optionsOpen ? options : null
        }
        Region {
            item: swatches.visible ? swatches : null
        }
    }
    BackgroundEffect.blurRegion: Theme.blur ? blur : null
    Region {
        id: blur
        item: bar
        radius: bar.radius
        Region {
            item: root.optionsOpen ? options : null
            radius: options.radius
        }
        Region {
            item: swatches.visible ? swatches : null
            radius: swatches.radius
        }
    }

    // ── Pieces ──────────────────────────────────────────────────────────
    component ModeButton: Rectangle {
        id: mb
        property string icon
        property string tip
        property string kind
        property string where
        readonly property bool selected: Capture.mode === kind && (kind === "text" || kind === "color" || Capture.target === where)
        visible: Capture.allowed(kind)

        Layout.preferredWidth: 44
        Layout.preferredHeight: 40
        radius: 10
        color: selected ? Theme.withAlpha(Theme.accent, 0.3) : mouse.containsMouse ? Theme.withAlpha(Theme.text, 0.1) : "transparent"
        border.width: selected ? 1 : 0
        border.color: Theme.withAlpha(Theme.accent, 0.6)

        Icon {
            anchors.centerIn: parent
            text: mb.icon
            size: 20
            color: mb.selected ? Theme.accent : Theme.text
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                Capture.mode = mb.kind;
                if (mb.where !== "")
                    Capture.target = mb.where;
            }
            onDoubleClicked: Capture.captureSelected()
        }

        // Tooltip above the toolbar.
        Rectangle {
            visible: mouse.containsMouse
            anchors {
                bottom: parent.top
                bottomMargin: 14
                horizontalCenter: parent.horizontalCenter
            }
            width: tipText.implicitWidth + 16
            height: 24
            radius: 8
            color: Theme.withAlpha(Theme.surface, 0.95)
            border.width: 1
            border.color: Theme.glassBorder

            Text {
                id: tipText
                anchors.centerIn: parent
                text: mb.tip
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 11
            }
        }
    }

    component Divider: Rectangle {
        Layout.preferredWidth: 1
        Layout.preferredHeight: 28
        color: Theme.withAlpha(Theme.text, 0.15)
    }

    // A checkable line in the Options menu.
    component MenuItem: Rectangle {
        id: mi
        property string label
        property bool checked
        signal activated

        Layout.fillWidth: true
        implicitHeight: 26
        implicitWidth: Math.min(320, miText.implicitWidth + 40)
        radius: 6
        color: miMouse.containsMouse ? Theme.accent : "transparent"

        Icon {
            anchors {
                left: parent.left
                leftMargin: 6
                verticalCenter: parent.verticalCenter
            }
            visible: mi.checked
            text: "󰄬"
            size: 11
            color: miMouse.containsMouse ? Theme.bg : Theme.accent
        }
        Text {
            id: miText
            anchors {
                left: parent.left
                leftMargin: 24
                verticalCenter: parent.verticalCenter
            }
            width: parent.width - 30
            text: mi.label
            elide: Text.ElideMiddle
            color: miMouse.containsMouse ? Theme.bg : Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 12
        }
        MouseArea {
            id: miMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: mi.activated()
        }
    }

    component MenuTitle: Text {
        Layout.topMargin: 6
        Layout.leftMargin: 6
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
        font.weight: Font.DemiBold
    }

    // ── Toolbar ─────────────────────────────────────────────────────────
    GlassSurface {
        id: bar
        anchors {
            bottom: parent.bottom
            horizontalCenter: parent.horizontalCenter
        }
        width: row.implicitWidth + 20
        height: 56
        radius: 16
        strength: 1.8

        focus: root.shown
        Keys.onEscapePressed: root.optionsOpen ? root.optionsOpen = false : Capture.closeSelector()
        Keys.onReturnPressed: Capture.captureSelected()
        Keys.onEnterPressed: Capture.captureSelected()

        RowLayout {
            id: row
            anchors.centerIn: parent
            spacing: 4

            // Close
            Rectangle {
                Layout.preferredWidth: 28
                Layout.preferredHeight: 28
                radius: 14
                color: closeMouse.containsMouse ? Theme.withAlpha(Theme.text, 0.2) : Theme.withAlpha(Theme.text, 0.1)

                Icon {
                    anchors.centerIn: parent
                    text: "󰅖"
                    size: 14
                    color: Theme.subtext
                }
                MouseArea {
                    id: closeMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Capture.closeSelector()
                }
            }

            Item {
                Layout.preferredWidth: 6
            }

            ModeButton {
                icon: "󰍹"
                tip: "Capture Entire Screen"
                kind: "shot"
                where: "screen"
            }
            ModeButton {
                icon: "󰖯"
                tip: "Capture Focused Window"
                kind: "shot"
                where: "window"
            }
            ModeButton {
                icon: "󰆞"
                tip: "Capture Selected Portion"
                kind: "shot"
                where: "area"
            }

            Divider {
                visible: Capture.allowed("shot")
            }

            ModeButton {
                icon: "󰕧"
                tip: "Record Entire Screen"
                kind: "record"
                where: "screen"
            }
            ModeButton {
                icon: "󰹑"
                tip: "Record Selected Portion"
                kind: "record"
                where: "area"
            }

            Divider {
                visible: Capture.allowed("text") || Capture.allowed("color")
            }

            ModeButton {
                icon: "󱄽"
                tip: "Copy Text or QR Code"
                kind: "text"
                where: ""
            }
            ModeButton {
                icon: "󰈊"
                tip: "Pick a Color"
                kind: "color"
                where: ""
            }

            Divider {}

            // Options
            Rectangle {
                Layout.preferredHeight: 34
                Layout.preferredWidth: optRow.implicitWidth + 22
                radius: 9
                color: root.optionsOpen || optMouse.containsMouse ? Theme.withAlpha(Theme.text, 0.12) : "transparent"

                Row {
                    id: optRow
                    anchors.centerIn: parent
                    spacing: 6

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Options"
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                    }
                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "󰅀"
                        size: 11
                        color: Theme.subtext
                    }
                }
                MouseArea {
                    id: optMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.optionsOpen = !root.optionsOpen
                }
            }

            // Capture / Record
            Rectangle {
                id: go
                Layout.leftMargin: 4
                Layout.preferredHeight: 34
                Layout.preferredWidth: goRow.implicitWidth + 28
                radius: 9
                readonly property bool stopping: Capture.mode === "record" && Recorder.active
                color: goMouse.containsMouse ? Qt.lighter(stopping ? Theme.urgent : Theme.accent, 1.1) : stopping ? Theme.urgent : Theme.accent

                Row {
                    id: goRow
                    anchors.centerIn: parent
                    spacing: 6

                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: Capture.cfg.timer > 0 && !go.stopping
                        text: "󰔛"
                        size: 13
                        color: Theme.bg
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: {
                            if (go.stopping)
                                return "Stop Recording";
                            switch (Capture.mode) {
                            case "record":
                                return "Record";
                            case "text":
                                return "Copy Text";
                            case "color":
                                return "Pick Color";
                            default:
                                return "Capture";
                            }
                        }
                        color: Theme.bg
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                    }
                }
                MouseArea {
                    id: goMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Capture.captureSelected()
                }
            }
        }
    }

    // ── Recent colors (Color mode) ──────────────────────────────────────
    GlassSurface {
        id: swatches
        visible: Capture.mode === "color" && Capture.cfg.recentColors.length > 0 && !root.optionsOpen
        anchors {
            bottom: bar.top
            bottomMargin: 10
            horizontalCenter: bar.horizontalCenter
        }
        width: swatchRow.implicitWidth + 24
        height: 40
        radius: 12
        strength: 1.8

        Row {
            id: swatchRow
            anchors.centerIn: parent
            spacing: 8

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Recent"
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
            }

            Repeater {
                model: Capture.cfg.recentColors
                delegate: Rectangle {
                    id: sw
                    required property string modelData
                    anchors.verticalCenter: parent.verticalCenter
                    width: 22
                    height: 22
                    radius: 6
                    color: modelData
                    border.width: swMouse.containsMouse ? 2 : 1
                    border.color: swMouse.containsMouse ? Theme.text : Theme.withAlpha(Theme.text, 0.25)

                    MouseArea {
                        id: swMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Capture.copyColor(sw.modelData)
                    }
                }
            }
        }
    }

    // ── Options menu ────────────────────────────────────────────────────
    Rectangle {
        id: options
        visible: root.optionsOpen
        anchors {
            bottom: bar.top
            bottomMargin: 8
            right: bar.right
        }
        width: Math.max(250, menu.implicitWidth + 16)
        height: menu.implicitHeight + 16
        radius: 12
        color: Theme.withAlpha(Theme.surface, 0.97)
        border.width: 1
        border.color: Theme.glassBorder

        readonly property var places: {
            const list = ["~/Pictures/Screenshots", "~/Desktop", "~/Pictures"];
            const current = Capture.mode === "record" ? root.cfg.recordingDir : root.cfg.screenshotDir;
            if (!list.includes(current))
                list.push(current);
            if (Capture.mode === "record" && !list.includes("~/Videos/Recordings"))
                list.unshift("~/Videos/Recordings");
            return list;
        }

        ColumnLayout {
            id: menu
            anchors {
                fill: parent
                margins: 8
            }
            spacing: 1

            MenuTitle {
                visible: Capture.mode === "shot" || Capture.mode === "record"
                text: "Save to"
                Layout.topMargin: 0
            }
            Repeater {
                model: Capture.mode === "shot" || Capture.mode === "record" ? options.places : []
                delegate: MenuItem {
                    required property string modelData
                    label: Capture.pretty(Capture.expand(modelData))
                    checked: (Capture.mode === "record" ? root.cfg.recordingDir : root.cfg.screenshotDir) === modelData
                    onActivated: Capture.mode === "record" ? root.cfg.recordingDir = modelData : root.cfg.screenshotDir = modelData
                }
            }

            MenuTitle {
                text: "Timer"
            }
            Repeater {
                model: [
                    {
                        v: 0,
                        l: "None"
                    },
                    {
                        v: 3,
                        l: "3 Seconds"
                    },
                    {
                        v: 10,
                        l: "10 Seconds"
                    }
                ]
                delegate: MenuItem {
                    required property var modelData
                    label: modelData.l
                    checked: root.cfg.timer === modelData.v
                    onActivated: root.cfg.timer = modelData.v
                }
            }

            MenuTitle {
                visible: Capture.mode === "record"
                text: "Audio"
            }
            Repeater {
                model: Capture.mode === "record" ? [
                    {
                        v: "none",
                        l: "No Audio"
                    },
                    {
                        v: "system",
                        l: "System Audio"
                    },
                    {
                        v: "mic",
                        l: "Microphone"
                    },
                    {
                        v: "both",
                        l: "System + Microphone (two tracks)"
                    }
                ] : []
                delegate: MenuItem {
                    required property var modelData
                    label: modelData.l
                    checked: root.cfg.audio === modelData.v
                    onActivated: root.cfg.audio = modelData.v
                }
            }

            MenuTitle {
                visible: Capture.mode === "color"
                text: "Copy as"
            }
            Repeater {
                model: Capture.mode === "color" ? Capture.colorFormats : []
                delegate: MenuItem {
                    required property var modelData
                    label: modelData.label
                    checked: root.cfg.colorFormat === modelData.value
                    onActivated: root.cfg.colorFormat = modelData.value
                }
            }

            MenuTitle {
                visible: Capture.mode === "shot" || Capture.mode === "record"
                text: "Options"
            }
            MenuItem {
                visible: Capture.mode === "shot" || Capture.mode === "record"
                label: "Show Floating Thumbnail"
                checked: root.cfg.showThumbnail
                onActivated: root.cfg.showThumbnail = !root.cfg.showThumbnail
            }
            MenuItem {
                visible: Capture.mode === "shot"
                label: "Copy to Clipboard"
                checked: root.cfg.copyToClipboard
                onActivated: root.cfg.copyToClipboard = !root.cfg.copyToClipboard
            }
            MenuItem {
                visible: Capture.mode === "shot"
                label: "Annotate After Capture"
                checked: root.cfg.annotateAfter
                onActivated: root.cfg.annotateAfter = !root.cfg.annotateAfter
            }
            MenuItem {
                visible: Capture.mode === "shot"
                label: "Show Mouse Pointer"
                checked: root.cfg.showPointer
                onActivated: root.cfg.showPointer = !root.cfg.showPointer
            }
        }
    }
}
