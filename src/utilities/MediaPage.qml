import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services
import qs.settings

// Utilities → Media Tools: drop files (anywhere on the window), pick recent
// media, or send them from the dock's Quick Actions / "Open With → Media
// Tools" / Spotlight; choose an operation and its options; run. Progress
// comes from `loft media run` (services/MediaTools.qml); results list the
// new files with their size change and Show in Files / Open.
ColumnLayout {
    id: page
    spacing: 12

    onVisibleChanged: if (visible)
        MediaTools.loadRecent()
    Component.onCompleted: if (visible)
        MediaTools.loadRecent()

    function size(b) {
        return Cleaner.formatBytes(b);
    }
    function dur(s) {
        if (!s)
            return "";
        const m = Math.floor(s / 60);
        const r = Math.round(s % 60);
        return `${m}:${r < 10 ? "0" : ""}${r}`;
    }
    function kindIcon(k) {
        return k === "video" ? "󰕧" : k === "image" ? "󰋩" : k === "audio" ? "󰎈" : "󰈔";
    }
    function uri(path) {
        return "file://" + path.split("/").map(encodeURIComponent).join("/");
    }

    component Sub: Text {
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
    }

    // ── Files ────────────────────────────────────────────────────────────
    SettingsCard {
        spacing: 6

        PageHeader {
            title: MediaTools.files.length === 0 ? "Files" : `${MediaTools.files.length} file${MediaTools.files.length === 1 ? "" : "s"}`
        }

        // Empty: a drop target with recent media.
        Rectangle {
            Layout.fillWidth: true
            visible: MediaTools.files.length === 0
            implicitHeight: 92
            radius: 14
            color: Theme.withAlpha(Theme.text, 0.035)
            border.width: 1
            border.color: Theme.withAlpha(Theme.text, 0.18)
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 4
                Icon {
                    Layout.alignment: Qt.AlignHCenter
                    text: "󰇚"
                    size: 24
                    color: Theme.subtext
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Drop videos, images or audio here"
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                    font.weight: Font.Medium
                }
                Sub {
                    Layout.alignment: Qt.AlignHCenter
                    text: "or pick a recent file · Open With → Media Tools in any file manager"
                    font.pixelSize: 10
                }
            }
        }

        Repeater {
            model: MediaTools.files
            delegate: Rectangle {
                id: frow
                required property var modelData
                required property int index
                readonly property bool fits: MediaTools.opInfo.kinds.includes(modelData.kind)
                readonly property bool active: MediaTools.running && MediaTools.applicable[MediaTools.current]?.path === modelData.path
                Layout.fillWidth: true
                implicitHeight: 40
                radius: 8
                color: active ? Theme.withAlpha(Theme.accent, 0.12) : index % 2 === 1 ? Theme.withAlpha(Theme.text, 0.03) : "transparent"
                opacity: fits ? 1 : 0.45
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 10
                    Rectangle {
                        Layout.preferredWidth: 30
                        Layout.preferredHeight: 30
                        radius: 6
                        clip: true
                        color: Theme.withAlpha(Theme.text, 0.08)
                        Image {
                            anchors.fill: parent
                            visible: frow.modelData.kind === "image"
                            source: visible ? page.uri(frow.modelData.path) : ""
                            sourceSize: Qt.size(60, 60)
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                        }
                        Icon {
                            anchors.centerIn: parent
                            visible: frow.modelData.kind !== "image"
                            text: page.kindIcon(frow.modelData.kind)
                            size: 14
                            color: Theme.accent
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Text {
                            Layout.fillWidth: true
                            text: frow.modelData.name
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 12
                            elide: Text.ElideMiddle
                        }
                        Sub {
                            Layout.fillWidth: true
                            text: [frow.modelData.kind, frow.modelData.width ? `${frow.modelData.width}×${frow.modelData.height}` : "", page.dur(frow.modelData.duration), page.size(frow.modelData.bytes)].filter(x => x).join(" · ") + (frow.fits ? "" : ` — not for ${MediaTools.opInfo.label}`)
                            font.pixelSize: 10
                            elide: Text.ElideRight
                        }
                    }
                    Rectangle {
                        Layout.preferredWidth: 20
                        Layout.preferredHeight: 20
                        radius: 10
                        visible: !MediaTools.running
                        color: rm.containsMouse ? Theme.withAlpha(Theme.text, 0.2) : Theme.withAlpha(Theme.text, 0.08)
                        Icon {
                            anchors.centerIn: parent
                            text: "󰅖"
                            size: 10
                            color: Theme.text
                        }
                        MouseArea {
                            id: rm
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: MediaTools.remove(frow.modelData.path)
                        }
                    }
                }
            }
        }

        Text {
            visible: MediaTools.recent.length > 0
            Layout.topMargin: 4
            text: MediaTools.files.length === 0 ? "Recent" : "Add recent"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 10
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 0.4
        }
        Flow {
            Layout.fillWidth: true
            visible: MediaTools.recent.length > 0
            spacing: 8
            Repeater {
                model: MediaTools.recent.filter(r => !MediaTools.files.some(f => f.path === r.path))
                delegate: Rectangle {
                    id: chip
                    required property var modelData
                    implicitWidth: 168
                    implicitHeight: 44
                    radius: 10
                    color: cm.containsMouse ? Theme.withAlpha(Theme.accent, 0.18) : Theme.withAlpha(Theme.text, 0.06)
                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 6
                        spacing: 8
                        Rectangle {
                            Layout.preferredWidth: 32
                            Layout.preferredHeight: 32
                            radius: 6
                            clip: true
                            color: Theme.withAlpha(Theme.text, 0.08)
                            Image {
                                anchors.fill: parent
                                visible: chip.modelData.kind === "image"
                                source: visible ? page.uri(chip.modelData.path) : ""
                                sourceSize: Qt.size(64, 64)
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }
                            Icon {
                                anchors.centerIn: parent
                                visible: chip.modelData.kind !== "image"
                                text: page.kindIcon(chip.modelData.kind)
                                size: 15
                                color: Theme.accent
                            }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text {
                                Layout.fillWidth: true
                                text: chip.modelData.name
                                color: Theme.text
                                font.family: Theme.fontUi
                                font.pixelSize: 11
                                elide: Text.ElideMiddle
                            }
                            Sub {
                                text: page.size(chip.modelData.bytes)
                                font.pixelSize: 9
                            }
                        }
                    }
                    MouseArea {
                        id: cm
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: MediaTools.add([chip.modelData.path])
                    }
                }
            }
        }

    }

    // ── Operation + options ──────────────────────────────────────────────
    SettingsCard {
        spacing: 8

        // Five tool tiles.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Repeater {
                model: MediaTools.ops
                delegate: Rectangle {
                    id: tile
                    required property var modelData
                    readonly property bool current: MediaTools.op === modelData.id
                    readonly property int count: MediaTools.files.filter(f => modelData.kinds.includes(f.kind)).length
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    implicitHeight: 66
                    radius: 12
                    color: current ? Theme.withAlpha(Theme.accent, 0.2) : tm.containsMouse ? Theme.withAlpha(Theme.text, 0.08) : Theme.withAlpha(Theme.text, 0.04)
                    border.width: current ? 1 : 0
                    border.color: Theme.withAlpha(Theme.accent, 0.7)
                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 4
                        Icon {
                            Layout.alignment: Qt.AlignHCenter
                            text: tile.modelData.icon
                            size: 18
                            color: tile.current ? Theme.accent : Theme.text
                        }
                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: tile.modelData.label
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            font.weight: tile.current ? Font.DemiBold : Font.Normal
                        }
                        Sub {
                            Layout.alignment: Qt.AlignHCenter
                            visible: MediaTools.files.length > 0
                            text: tile.count > 0 ? `${tile.count} file${tile.count === 1 ? "" : "s"}` : tile.modelData.kinds.join(" / ")
                            font.pixelSize: 9
                        }
                    }
                    MouseArea {
                        id: tm
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        enabled: !MediaTools.running
                        onClicked: MediaTools.op = tile.modelData.id
                    }
                }
            }
        }

        // compress
        SettingsRow {
            visible: MediaTools.op === "compress"
            label: "Quality"
            hint: "H.264 + AAC in MP4; the 720p / 1080p presets only scale down"
            SettingsSegmented {
                options: [
                    {
                        value: "small",
                        label: "Small · 720p"
                    },
                    {
                        value: "balanced",
                        label: "Balanced · 1080p"
                    },
                    {
                        value: "high",
                        label: "High"
                    }
                ]
                current: MediaTools.preset
                onActivated: v => MediaTools.preset = v
            }
        }

        // convert
        SettingsRow {
            visible: MediaTools.op === "convert"
            label: "Format"
            hint: MediaTools.caps.avif === false ? "AVIF isn't available in this ImageMagick" : ""
            SettingsSegmented {
                options: ["png", "jpg", "webp", "avif"].map(f => ({
                            value: f,
                            label: f.toUpperCase()
                        }))
                current: MediaTools.format
                onActivated: v => MediaTools.format = v
            }
        }
        SettingsRow {
            visible: MediaTools.op === "convert" && MediaTools.format !== "png"
            label: "Quality"
            SettingsSlider {
                Layout.preferredWidth: 220
                from: 30
                to: 100
                step: 1
                value: MediaTools.quality
                onCommitted: v => MediaTools.quality = Math.round(v)
                onMoved: v => MediaTools.quality = Math.round(v)
            }
        }
        SettingsRow {
            visible: MediaTools.op === "convert"
            label: "Resize"
            hint: "Longest side; smaller images stay as they are"
            SettingsSelect {
                options: [0, 3840, 2560, 1920, 1280, 800, 400].map(v => ({
                            value: v,
                            label: v === 0 ? "Original size" : `${v} px`
                        }))
                current: MediaTools.maxSize
                onActivated: v => MediaTools.maxSize = v
            }
        }

        // gif
        SettingsRow {
            visible: MediaTools.op === "gif"
            label: "Size"
            SettingsSegmented {
                options: [320, 480, 640, 800].map(v => ({
                            value: v,
                            label: `${v} px`
                        }))
                current: MediaTools.gifWidth
                onActivated: v => MediaTools.gifWidth = v
            }
        }
        SettingsRow {
            visible: MediaTools.op === "gif"
            label: "Frame rate"
            SettingsSegmented {
                options: [10, 15, 24].map(v => ({
                            value: v,
                            label: `${v} fps`
                        }))
                current: MediaTools.fps
                onActivated: v => MediaTools.fps = v
            }
        }
        SettingsRow {
            visible: MediaTools.op === "gif"
            label: "Length"
            SettingsSelect {
                options: [0, 3, 5, 10, 20].map(v => ({
                            value: v,
                            label: v === 0 ? "Whole clip" : `First ${v} s`
                        }))
                current: MediaTools.gifSeconds
                onActivated: v => MediaTools.gifSeconds = v
            }
        }

        // watermark
        SettingsRow {
            visible: MediaTools.op === "watermark"
            label: "Text"
            hint: MediaTools.wmImage !== "" ? "an image is set: it's used instead" : ""
            SettingsTextField {
                Layout.preferredWidth: 260
                text: MediaTools.wmText
                placeholder: "© Your Name"
                onEdited: t => MediaTools.wmText = t
                onCommitted: t => MediaTools.wmText = t
            }
        }
        SettingsRow {
            visible: MediaTools.op === "watermark"
            label: "Or an image (logo)"
            hint: "path to a PNG with transparency"
            SettingsTextField {
                Layout.preferredWidth: 260
                text: MediaTools.wmImage
                placeholder: "~/Pictures/logo.png"
                onCommitted: t => MediaTools.wmImage = t.trim()
            }
        }
        SettingsRow {
            visible: MediaTools.op === "watermark"
            label: "Position"
            SettingsSegmented {
                options: [
                    {
                        value: "top-left",
                        label: "↖"
                    },
                    {
                        value: "top-right",
                        label: "↗"
                    },
                    {
                        value: "center",
                        label: "◎"
                    },
                    {
                        value: "bottom-left",
                        label: "↙"
                    },
                    {
                        value: "bottom-right",
                        label: "↘"
                    }
                ]
                current: MediaTools.wmPosition
                onActivated: v => MediaTools.wmPosition = v
            }
        }
        SettingsRow {
            visible: MediaTools.op === "watermark"
            label: "Opacity"
            SettingsSlider {
                Layout.preferredWidth: 220
                from: 0.1
                to: 1
                value: MediaTools.wmOpacity
                format: v => `${Math.round(v * 100)} %`
                onCommitted: v => MediaTools.wmOpacity = v
            }
        }

        // audio
        SettingsRow {
            visible: MediaTools.op === "audio"
            label: "Format"
            SettingsSegmented {
                options: [
                    {
                        value: "m4a",
                        label: "M4A (AAC)"
                    },
                    {
                        value: "mp3",
                        label: "MP3"
                    },
                    {
                        value: "flac",
                        label: "FLAC"
                    },
                    {
                        value: "wav",
                        label: "WAV"
                    }
                ]
                current: MediaTools.audioFormat
                onActivated: v => MediaTools.audioFormat = v
            }
        }

        SettingsRow {
            label: "Save to"
            hint: MediaTools.outDir === "" ? "Next to each original, with a suffix — nothing is overwritten" : ""
            SettingsTextField {
                Layout.preferredWidth: 260
                text: MediaTools.outDir
                placeholder: "Same folder as the original"
                onCommitted: t => MediaTools.outDir = t.trim()
            }
        }

        // Run / progress
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 10

            Rectangle {
                Layout.fillWidth: true
                visible: MediaTools.running || MediaTools.overall > 0
                implicitHeight: 6
                radius: 3
                color: Theme.withAlpha(Theme.text, 0.1)
                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, MediaTools.overall))
                    height: parent.height
                    radius: 3
                    color: Theme.accent
                    Behavior on width {
                        NumberAnimation {
                            duration: 200
                        }
                    }
                }
            }
            Sub {
                visible: MediaTools.running || MediaTools.overall > 0
                text: MediaTools.running ? `${Math.round(MediaTools.overall * 100)} % · ${MediaTools.current + 1} of ${MediaTools.applicable.length}` : "Done"
                font.features: {
                    "tnum": 1
                }
            }
            Item {
                Layout.fillWidth: true
                visible: !(MediaTools.running || MediaTools.overall > 0)
            }
            SettingsButton {
                visible: MediaTools.running
                text: "Stop"
                onClicked: MediaTools.cancel()
            }
            SettingsButton {
                visible: !MediaTools.running
                primary: true
                enabled: MediaTools.ready
                text: MediaTools.applicable.length > 0 ? `${MediaTools.opInfo.label} · ${MediaTools.applicable.length} file${MediaTools.applicable.length === 1 ? "" : "s"}` : MediaTools.opInfo.label
                onClicked: MediaTools.start()
            }
        }
        Sub {
            Layout.fillWidth: true
            visible: MediaTools.error !== "" || MediaTools.caps.ffmpeg === false
            text: MediaTools.caps.ffmpeg === false ? "ffmpeg isn't installed." : MediaTools.error
            color: Theme.urgent
        }
    }

    // ── Results ──────────────────────────────────────────────────────────
    SettingsCard {
        visible: MediaTools.results.length > 0
        spacing: 4
        PageHeader {
            title: "Results"
        }
        Repeater {
            model: MediaTools.results
            delegate: RowLayout {
                id: res
                required property var modelData
                readonly property real ratio: modelData.inBytes ? modelData.outBytes / modelData.inBytes : 1
                Layout.fillWidth: true
                spacing: 10
                Icon {
                    text: res.modelData.error ? "󰅚" : "󰄬"
                    size: 14
                    color: res.modelData.error ? Theme.urgent : Theme.ok
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                        Layout.fillWidth: true
                        text: res.modelData.error ? res.modelData.file.split("/").pop() : res.modelData.output.split("/").pop()
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        elide: Text.ElideMiddle
                    }
                    Sub {
                        Layout.fillWidth: true
                        text: res.modelData.error ? res.modelData.error : `${page.size(res.modelData.inBytes)} → ${page.size(res.modelData.outBytes)}` + (res.ratio < 1 ? `  (−${Math.round((1 - res.ratio) * 100)} %)` : res.ratio > 1.01 ? `  (+${Math.round((res.ratio - 1) * 100)} %)` : "")
                        color: res.modelData.error ? Theme.urgent : res.ratio < 1 ? Theme.ok : Theme.subtext
                        font.pixelSize: 10
                        elide: Text.ElideRight
                    }
                }
                SettingsButton {
                    visible: !res.modelData.error
                    text: "Show in Files"
                    onClicked: MediaTools.reveal(res.modelData.output)
                }
                SettingsButton {
                    visible: !res.modelData.error
                    text: "Open"
                    onClicked: MediaTools.openFile(res.modelData.output)
                }
            }
        }
    }
}
