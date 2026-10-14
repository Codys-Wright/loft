import QtQuick
import QtQuick.Layouts
import qs.capture
import qs.services

// Settings → Capture: where captures go and what follows them, recording
// audio and GIF export, text recognition, the color picker and the camera
// mirror. Stored in <state>/overrides/capture.json (Capture.cfg).
ColumnLayout {
    id: page
    spacing: 12

    readonly property var cfg: Capture.cfg

    component Hint: Text {
        Layout.fillWidth: true
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
        wrapMode: Text.Wrap
    }

    SettingsCard {
        PageHeader {
            title: "Screenshots"
            SettingsButton {
                text: "Open Selector"
                icon: "󰹑"
                onClicked: {
                    Panels.settingsOpen = false;
                    Capture.openSelector();
                }
            }
        }

        SettingsRow {
            label: "Save to"
            hint: Capture.screenshotDir
            SettingsTextField {
                implicitWidth: 240
                text: page.cfg.screenshotDir
                placeholder: "~/Pictures/Screenshots"
                onCommitted: t => page.cfg.screenshotDir = t.trim() || "~/Pictures/Screenshots"
            }
        }
        SettingsRow {
            label: "Timer"
            hint: "Delay before the selector captures"
            SettingsSegmented {
                options: [
                    {
                        value: 0,
                        label: "None"
                    },
                    {
                        value: 3,
                        label: "3 s"
                    },
                    {
                        value: 10,
                        label: "10 s"
                    }
                ]
                current: page.cfg.timer
                onActivated: v => page.cfg.timer = v
            }
        }
        SettingsRow {
            label: "Copy to clipboard"
            SettingsSwitch {
                checked: page.cfg.copyToClipboard
                onToggled: on => page.cfg.copyToClipboard = on
            }
        }
        SettingsRow {
            label: "Show floating thumbnail"
            hint: "Click to annotate, drag into an app, or pin it on top"
            SettingsSwitch {
                checked: page.cfg.showThumbnail
                onToggled: on => page.cfg.showThumbnail = on
            }
        }
        SettingsRow {
            label: "Annotate after capture"
            hint: "Open every screenshot in satty right away"
            SettingsSwitch {
                checked: page.cfg.annotateAfter
                onToggled: on => page.cfg.annotateAfter = on
            }
        }
        SettingsRow {
            label: "Show mouse pointer"
            SettingsSwitch {
                checked: page.cfg.showPointer
                onToggled: on => page.cfg.showPointer = on
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: "Screen Recording"
        }

        SettingsRow {
            label: "Save to"
            hint: Capture.recordingDir
            SettingsTextField {
                implicitWidth: 240
                text: page.cfg.recordingDir
                placeholder: "~/Videos/Recordings"
                onCommitted: t => page.cfg.recordingDir = t.trim() || "~/Videos/Recordings"
            }
        }
        SettingsRow {
            label: "Audio"
            hint: page.cfg.audio === "both" ? "System and microphone as two separate tracks" : "From the default output / input device"
            SettingsSelect {
                implicitWidth: 200
                options: [
                    {
                        value: "none",
                        label: "No audio"
                    },
                    {
                        value: "system",
                        label: "System audio"
                    },
                    {
                        value: "mic",
                        label: "Microphone"
                    },
                    {
                        value: "both",
                        label: "System + microphone"
                    }
                ]
                current: page.cfg.audio
                onActivated: v => page.cfg.audio = v
            }
        }
        SettingsRow {
            label: "GIF frame rate"
            SettingsSegmented {
                options: [10, 15, 24, 30]
                current: page.cfg.gifFps
                onActivated: v => page.cfg.gifFps = v
            }
        }
        SettingsRow {
            label: "GIF width"
            hint: "At most; smaller recordings keep their size"
            SettingsSegmented {
                options: [
                    {
                        value: 480,
                        label: "480"
                    },
                    {
                        value: 720,
                        label: "720"
                    },
                    {
                        value: 960,
                        label: "960"
                    },
                    {
                        value: 1280,
                        label: "1280"
                    }
                ]
                current: page.cfg.gifWidth
                onActivated: v => page.cfg.gifWidth = v
            }
        }
        Hint {
            text: "After a recording, its thumbnail offers Trim & Zoom (trim, Auto Zoom, zoom segments) and Export GIF. Stop from the island or the selector."
        }
    }

    SettingsCard {
        visible: Features.on("ocr")

        PageHeader {
            title: "Text from Screen"
        }
        SettingsRow {
            label: "Languages"
            hint: "tesseract codes, e.g. eng or eng+deu"
            SettingsTextField {
                implicitWidth: 160
                text: page.cfg.ocrLanguage
                placeholder: "eng"
                onCommitted: t => page.cfg.ocrLanguage = t.trim() || "eng"
            }
        }
        Hint {
            text: "QR codes in the selection are read first; otherwise the text is recognized. Either way it's copied and shown in the island."
        }
    }

    SettingsCard {
        visible: Features.on("colorPicker")

        PageHeader {
            title: "Color Picker"
            SettingsButton {
                visible: page.cfg.recentColors.length > 0
                text: "Clear Recents"
                onClicked: page.cfg.recentColors = []
            }
        }
        SettingsRow {
            label: "Copy as"
            hint: page.cfg.recentColors.length > 0 ? Capture.formatColor(page.cfg.recentColors[0], page.cfg.colorFormat) : "Format of the copied value"
            SettingsSelect {
                implicitWidth: 220
                options: Capture.colorFormats
                current: page.cfg.colorFormat
                onActivated: v => page.cfg.colorFormat = v
            }
        }
        Flow {
            Layout.fillWidth: true
            visible: page.cfg.recentColors.length > 0
            spacing: 8

            Repeater {
                model: page.cfg.recentColors
                delegate: Rectangle {
                    id: chip
                    required property string modelData
                    width: 28
                    height: 28
                    radius: 8
                    color: modelData
                    border.width: chipMouse.containsMouse ? 2 : 1
                    border.color: chipMouse.containsMouse ? Theme.text : Theme.withAlpha(Theme.text, 0.2)

                    MouseArea {
                        id: chipMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: Capture.copyColor(chip.modelData)
                    }
                }
            }
        }
    }

    SettingsCard {
        visible: Features.on("camera")

        PageHeader {
            title: "Camera Mirror"
        }
        SettingsRow {
            label: "Show camera"
            hint: Capture.cameraOn ? (Capture.cameraState === "live" ? Capture.cameraName : Capture.cameraState === "none" ? "No camera found" : Capture.cameraState === "error" ? Capture.cameraError : "Starting…") : "A floating preview above your windows"
            SettingsSwitch {
                checked: Capture.cameraOn
                onToggled: on => Capture.cameraOn = on
            }
        }
        SettingsRow {
            label: "Camera"
            visible: Capture.cameraDevices.length > 1
            SettingsSelect {
                implicitWidth: 220
                options: [
                    {
                        value: "",
                        label: "System default"
                    }
                ].concat(Capture.cameraDevices.map(d => ({
                            value: d,
                            label: d
                        })))
                current: page.cfg.cameraDevice
                onActivated: v => page.cfg.cameraDevice = v
            }
        }
        SettingsRow {
            label: "Shape"
            SettingsSegmented {
                options: [
                    {
                        value: "circle",
                        label: "Circle"
                    },
                    {
                        value: "rounded",
                        label: "Rounded"
                    }
                ]
                current: page.cfg.cameraShape
                onActivated: v => page.cfg.cameraShape = v
            }
        }
        SettingsRow {
            label: "Size"
            SettingsSlider {
                from: 120
                to: 520
                step: 10
                suffix: " px"
                value: page.cfg.cameraSize
                onMoved: v => page.cfg.cameraSize = v
            }
        }
        SettingsRow {
            label: "Mirror image"
            SettingsSwitch {
                checked: page.cfg.cameraMirror
                onToggled: on => page.cfg.cameraMirror = on
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: "Shortcuts"
        }
        Repeater {
            model: [
                ["⌘⇧5", "Capture selector"],
                ["⌘⇧4", "Capture an area"],
                ["⌘⇧3", "Capture the screen"]
            ]
            delegate: SettingsRow {
                id: shortcut
                required property var modelData
                label: modelData[1]
                Rectangle {
                    implicitWidth: keys.implicitWidth + 16
                    implicitHeight: 24
                    radius: 6
                    color: Theme.withAlpha(Theme.text, 0.08)
                    Text {
                        id: keys
                        anchors.centerIn: parent
                        text: shortcut.modelData[0]
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                    }
                }
            }
        }
        Hint {
            text: "IPC: capture toggle | area | screen | window | recordArea | recordScreen | text | color, camera toggle."
        }
    }
}
