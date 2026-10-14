import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// Trim a recording: pick the first and last frame (with previews), then
// Capture.trim writes "<name>-trimmed.mp4" next to it.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property var job: Capture.trimming
    readonly property real duration: job?.duration ?? 0
    property real start: 0
    property real end: 0
    property string startFrame: ""
    property string endFrame: ""

    visible: job !== null && Capture.screenFocused?.name === modelData.name
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "studio:capture-trim"
    WlrLayershell.keyboardFocus: visible ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: 560
    implicitHeight: 330
    color: "transparent"

    onJobChanged: {
        if (!job)
            return;
        start = 0;
        end = job.duration;
        frame(0, "start");
        frame(Math.max(0, job.duration - 0.05), "end");
    }

    function fmt(t) {
        const m = Math.floor(t / 60), s = t - m * 60;
        return `${m}:${s < 10 ? "0" : ""}${s.toFixed(1)}`;
    }

    // Grab a preview frame at t seconds.
    function frame(t, which) {
        const out = `${Capture.tmp}/trim-${which}-${Date.now()}.png`;
        Capture.exec(["ffmpeg", "-v", "error", "-y", "-ss", t.toFixed(3), "-i", job.path, "-frames:v", "1", "-vf", "scale=480:-2", "-update", "1", out], code => {
            if (code !== 0)
                return;
            if (which === "start")
                root.startFrame = out;
            else
                root.endFrame = out;
        });
    }

    component PillButton: Rectangle {
        id: btn
        property string text
        property bool primary: false
        signal clicked
        implicitWidth: label.implicitWidth + 28
        implicitHeight: 30
        radius: 15
        color: primary ? (mouse.containsMouse ? Qt.lighter(Theme.accent, 1.1) : Theme.accent) : mouse.containsMouse ? Theme.withAlpha(Theme.text, 0.16) : Theme.withAlpha(Theme.text, 0.09)

        Text {
            id: label
            anchors.centerIn: parent
            text: btn.text
            color: btn.primary ? Theme.bg : Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 12
            font.weight: btn.primary ? Font.DemiBold : Font.Medium
        }
        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }

    BackgroundEffect.blurRegion: Theme.blur ? blur : null
    Region {
        id: blur
        item: panel
        radius: panel.radius
    }

    GlassSurface {
        id: panel
        anchors.fill: parent
        radius: 22
        strength: 1.8
        focus: root.visible
        Keys.onEscapePressed: Capture.trimming = null

        ColumnLayout {
            anchors {
                fill: parent
                margins: 18
            }
            spacing: 12

            Text {
                text: "Trim Recording"
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 16
                font.weight: Font.DemiBold
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 12

                Repeater {
                    model: [
                        {
                            label: "Start",
                            which: "start"
                        },
                        {
                            label: "End",
                            which: "end"
                        }
                    ]
                    delegate: ColumnLayout {
                        id: preview
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: 4

                        RoundedClip {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 130
                            radius: 10

                            Rectangle {
                                anchors.fill: parent
                                color: Theme.overlay
                            }
                            Image {
                                anchors.fill: parent
                                readonly property string f: preview.modelData.which === "start" ? root.startFrame : root.endFrame
                                source: f ? "file://" + f : ""
                                fillMode: Image.PreserveAspectFit
                                cache: false
                                asynchronous: true
                            }
                        }
                        Text {
                            text: `${preview.modelData.label}  ${root.fmt(preview.modelData.which === "start" ? root.start : root.end)}`
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 12
                            font.features: {
                                "tnum": 1
                            }
                        }
                    }
                }
            }

            // Range: drag either handle.
            Item {
                id: range
                Layout.fillWidth: true
                Layout.preferredHeight: 28
                readonly property real span: Math.max(0.001, root.duration)
                function at(x) {
                    return Math.max(0, Math.min(1, x / width)) * span;
                }

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: 6
                    radius: 3
                    color: Theme.withAlpha(Theme.text, 0.15)
                }
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    x: root.start / range.span * range.width
                    width: (root.end - root.start) / range.span * range.width
                    height: 6
                    radius: 3
                    color: Theme.accent
                }
                Repeater {
                    model: ["start", "end"]
                    delegate: Rectangle {
                        required property string modelData
                        anchors.verticalCenter: parent.verticalCenter
                        x: (modelData === "start" ? root.start : root.end) / range.span * range.width - width / 2
                        width: 18
                        height: 18
                        radius: 9
                        color: "white"
                        border.width: 1
                        border.color: Theme.withAlpha("#000000", 0.15)
                    }
                }
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -8
                    cursorShape: Qt.PointingHandCursor
                    property string handle: ""
                    onPressed: mouse => {
                        const t = range.at(mouse.x - 8);
                        handle = Math.abs(t - root.start) <= Math.abs(t - root.end) ? "start" : "end";
                        positionChanged(mouse);
                    }
                    onPositionChanged: mouse => {
                        if (!pressed)
                            return;
                        const t = range.at(mouse.x - 8);
                        if (handle === "start")
                            root.start = Math.min(t, root.end - 0.1);
                        else
                            root.end = Math.max(t, root.start + 0.1);
                    }
                    onReleased: handle === "start" ? root.frame(root.start, "start") : root.frame(Math.max(0, root.end - 0.05), "end")
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.topMargin: 2

                Text {
                    Layout.fillWidth: true
                    text: `${root.fmt(root.end - root.start)} of ${root.fmt(root.duration)}`
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                }
                PillButton {
                    text: "Cancel"
                    onClicked: Capture.trimming = null
                }
                PillButton {
                    text: "Trim"
                    primary: true
                    onClicked: Capture.trim(root.job.path, root.start, root.end)
                }
            }
        }
    }
}
