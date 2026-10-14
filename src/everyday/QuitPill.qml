import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// "Hold ⌘Q to quit <App>" — a glass pill with a progress ring, centred on
// the display of the window being quit (QuitGuard drives it). Click-through.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property string output: QuitGuard.window ? (Niri.workspaceMap[QuitGuard.window.workspace_id]?.output ?? "") : ""
    readonly property bool shown: QuitGuard.phase !== "" && (output === "" ? (Niri.focusedWorkspace?.output ?? "") === modelData.name : output === modelData.name)
    readonly property string appName: Apps.name(QuitGuard.appId)

    visible: shown || fadeAnim.running
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:quit-pill"
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: Math.min(560, label.implicitWidth + 96)
    implicitHeight: 60
    color: "transparent"
    mask: Region {}

    BackgroundEffect.blurRegion: Theme.blur && shown ? blur : null
    Region {
        id: blur
        item: pill
        radius: pill.radius
    }

    GlassSurface {
        id: pill
        anchors.fill: parent
        radius: height / 2
        strength: 1.5
        opacity: root.shown ? 1 : 0
        scale: root.shown ? 1 : 0.94

        Behavior on opacity {
            NumberAnimation {
                id: fadeAnim
                duration: 180
            }
        }
        Behavior on scale {
            NumberAnimation {
                duration: 180
                easing.type: Easing.OutCubic
            }
        }

        RowLayout {
            anchors {
                fill: parent
                leftMargin: 16
                rightMargin: 22
            }
            spacing: 14

            Item {
                implicitWidth: 30
                implicitHeight: 30

                ProgressRing {
                    id: ring
                    anchors.fill: parent
                    lineWidth: 3.5
                    value: QuitGuard.progress
                    Behavior on value {
                        enabled: !QuitGuard.holding
                        NumberAnimation {
                            duration: 220
                            easing.type: Easing.OutCubic
                        }
                    }
                }
                Text {
                    anchors.centerIn: parent
                    text: "⌘"
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }
            }

            Text {
                id: label
                Layout.fillWidth: true
                text: QuitGuard.phase === "quitting" ? `Quitting ${root.appName}…` : `Hold ⌘Q to quit ${root.appName}`
                elide: Text.ElideRight
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 14
                font.weight: Font.DemiBold
            }
        }
    }

    // The cancelled ring drains back to empty.
    Connections {
        target: QuitGuard
        function onPhaseChanged() {
            if (QuitGuard.phase === "cancelled")
                QuitGuard.progress = 0;
        }
    }
}
