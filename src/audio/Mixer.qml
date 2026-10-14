import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import qs.components
import qs.services

// The volume mixer (Feature "mixer"): the output and its volume, every app
// playing sound (up to 150 %, mute, favorites, per-app output) and the
// microphones. A glass panel under the bar on the right, like the Control
// Center; opened from its volume tile, a right-click on the bar's volume
// icon, or `qs ipc call mixer toggle`. Click outside to close.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property bool shown: Sound.mixerOpen && Sound.mixerScreen === modelData.name

    visible: shown || slide.running
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:mixer"
    WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    readonly property int panelWidth: 400
    readonly property int gap: 10
    property bool outputsOpen: false
    property bool inputsOpen: false

    onShownChanged: if (!shown) {
        outputsOpen = false;
        inputsOpen = false;
    }

    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur && shown && !slide.running ? backing : null
        radius: backing.radius
    }

    MouseArea {
        anchors.fill: parent
        onClicked: Sound.mixerOpen = false
    }

    Item {
        id: panel
        width: root.panelWidth
        height: content.implicitHeight + 2 * root.gap
        anchors {
            top: parent.top
            right: parent.right
            topMargin: 50
            rightMargin: 12
        }
        opacity: root.shown ? 1 : 0
        focus: root.shown
        Keys.onEscapePressed: Sound.mixerOpen = false

        transform: Translate {
            x: root.shown ? 0 : root.panelWidth + 30
            Behavior on x {
                NumberAnimation {
                    id: slide
                    duration: 320
                    easing.type: Easing.OutQuart
                }
            }
        }
        Behavior on opacity {
            NumberAnimation {
                duration: 220
            }
        }

        GlassSurface {
            id: backing
            anchors.fill: parent
            // The Control Center's shape: panel and module radii.
            radius: Theme.panelRadius + 8
        }

        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            id: content
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: root.gap
            }
            spacing: root.gap

            // ── Header ──────────────────────────────────────────────────
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 8
                Layout.rightMargin: 8
                Layout.topMargin: 4

                Text {
                    Layout.fillWidth: true
                    text: "Sound"
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 16
                    font.weight: Font.DemiBold
                }

                Icon {
                    text: "󰒓"
                    size: 15
                    color: Theme.subtext
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -6
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Sound.mixerOpen = false;
                            Panels.settingsSection = "sound";
                            Panels.settingsOpen = true;
                        }
                    }
                }
            }

            // ── Output ──────────────────────────────────────────────────
            GlassSurface {
                id: outputTile
                Layout.fillWidth: true
                implicitHeight: outputCol.implicitHeight + 24
                radius: Theme.panelRadius
                showHighlight: false

                readonly property PwNode sink: Sound.defaultSink
                readonly property bool ready: sink?.ready ?? false

                ColumnLayout {
                    id: outputCol
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        margins: 12
                    }
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        Rectangle {
                            Layout.preferredWidth: 30
                            Layout.preferredHeight: 30
                            radius: 15
                            color: outputTile.ready && !outputTile.sink.audio.muted ? Theme.accent : Theme.withAlpha(Theme.text, 0.15)

                            Icon {
                                anchors.centerIn: parent
                                text: outputTile.ready && outputTile.sink.audio.muted ? "󰝟" : Sound.outputIcon(outputTile.sink)
                                size: 14
                                color: outputTile.ready && !outputTile.sink.audio.muted ? Theme.bg : Theme.text
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: if (outputTile.ready)
                                    outputTile.sink.audio.muted = !outputTile.sink.audio.muted
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text {
                                text: "Output"
                                color: Theme.subtext
                                font.family: Theme.fontUi
                                font.pixelSize: 11
                            }
                            Text {
                                Layout.fillWidth: true
                                text: Sound.label(outputTile.sink) || "No output"
                                color: Theme.text
                                font.family: Theme.fontUi
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                        }

                        Icon {
                            visible: Features.on("audioOutputs") && Sound.sinks.length > 1
                            text: root.outputsOpen ? "󰅃" : "󰅀"
                            size: 14
                            color: Theme.subtext
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -8
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.outputsOpen = !root.outputsOpen
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        VolumeSlider {
                            Layout.fillWidth: true
                            value: outputTile.ready ? outputTile.sink.audio.volume : 0
                            dimmed: !outputTile.ready || outputTile.sink.audio.muted
                            onMoved: v => {
                                if (outputTile.ready)
                                    outputTile.sink.audio.volume = v;
                            }
                        }
                        Text {
                            Layout.preferredWidth: 38
                            horizontalAlignment: Text.AlignRight
                            text: outputTile.ready ? `${Math.round(outputTile.sink.audio.volume * 100)}%` : ""
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            font.features: {
                                "tnum": 1
                            }
                        }
                    }

                    DeviceList {
                        visible: root.outputsOpen
                        Layout.fillWidth: true
                        nodes: Sound.sinks
                        currentId: outputTile.sink?.id ?? -1
                        onPicked: node => Sound.setDefaultSink(node)
                    }
                }
            }

            // ── Apps ────────────────────────────────────────────────────
            GlassSurface {
                Layout.fillWidth: true
                implicitHeight: Math.min(appsCol.implicitHeight, 430) + 24
                radius: Theme.panelRadius
                showHighlight: false

                Flickable {
                    anchors {
                        fill: parent
                        margins: 12
                    }
                    contentHeight: appsCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: appsCol
                        width: parent.width
                        spacing: 14

                        Text {
                            visible: Sound.apps.length === 0
                            Layout.fillWidth: true
                            Layout.topMargin: 6
                            Layout.bottomMargin: 6
                            horizontalAlignment: Text.AlignHCenter
                            text: "No apps are playing sound"
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 12
                        }

                        Repeater {
                            model: Sound.apps
                            delegate: AppRow {
                                required property var modelData
                                Layout.fillWidth: true
                                app: modelData
                                meters: root.shown && Settings.sound.meters
                            }
                        }
                    }
                }
            }

            // ── Microphones ─────────────────────────────────────────────
            GlassSurface {
                id: micTile
                visible: Features.on("micTools") && Sound.sources.length > 0
                Layout.fillWidth: true
                implicitHeight: micCol.implicitHeight + 24
                radius: Theme.panelRadius
                showHighlight: false

                readonly property PwNode source: Sound.defaultSource

                ColumnLayout {
                    id: micCol
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        margins: 12
                    }
                    spacing: 8

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10

                        Rectangle {
                            Layout.preferredWidth: 30
                            Layout.preferredHeight: 30
                            radius: 15
                            color: Sound.micsMuted ? Theme.urgent : Sound.recording ? Theme.warn : Theme.withAlpha(Theme.text, 0.15)

                            Icon {
                                anchors.centerIn: parent
                                text: Sound.micsMuted ? "󰍭" : Sound.inputIcon(micTile.source)
                                size: 14
                                color: Sound.micsMuted || Sound.recording ? Theme.bg : Theme.text
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text {
                                text: Sound.recording ? `Microphone · in use by ${Sound.recordingApps.join(", ")}` : "Microphone"
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                color: Sound.recording ? Theme.warn : Theme.subtext
                                font.family: Theme.fontUi
                                font.pixelSize: 11
                            }
                            Text {
                                Layout.fillWidth: true
                                text: Sound.label(micTile.source) || "No input"
                                color: Theme.text
                                font.family: Theme.fontUi
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                        }

                        Icon {
                            visible: Sound.sources.length > 1
                            text: root.inputsOpen ? "󰅃" : "󰅀"
                            size: 14
                            color: Theme.subtext
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -8
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.inputsOpen = !root.inputsOpen
                            }
                        }
                    }

                    LevelMeter {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 5
                        node: micTile.source
                        active: root.shown && micTile.visible && !Sound.micsMuted && Settings.sound.meters
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            Layout.fillWidth: true
                            text: "Mute all microphones"
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 12
                        }
                        // (Same look as Settings' switch; qs.settings imports us.)
                        Rectangle {
                            implicitWidth: 44
                            implicitHeight: 26
                            radius: 13
                            color: Sound.micsMuted ? Theme.urgent : Theme.withAlpha(Theme.text, 0.2)

                            Rectangle {
                                width: 22
                                height: 22
                                radius: 11
                                y: 2
                                x: Sound.micsMuted ? parent.width - width - 2 : 2
                                color: "white"
                                Behavior on x {
                                    NumberAnimation {
                                        duration: 150
                                    }
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Sound.setMicsMuted(!Sound.micsMuted)
                            }
                        }
                    }

                    DeviceList {
                        visible: root.inputsOpen
                        Layout.fillWidth: true
                        nodes: Sound.sources
                        currentId: micTile.source?.id ?? -1
                        iconFor: n => Sound.inputIcon(n)
                        onPicked: node => Sound.setDefaultSource(node)
                    }
                }
            }
        }
    }
}
