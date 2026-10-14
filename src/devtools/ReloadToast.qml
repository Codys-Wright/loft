import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.components
import qs.services

// Live-design feedback (replaces Quickshell's stock reload popup):
// a short "Reloaded" pill after each successful hot reload, and — when the
// edited QML doesn't load — the error, pinned until the next good reload
// (the previous version keeps running meanwhile).
// IPC: shell reload | hardReload. Bind: Mod+Shift+R.
Scope {
    id: root

    property string error: ""
    property bool showOk: false

    Connections {
        target: Quickshell

        function onReloadCompleted() {
            Quickshell.inhibitReloadPopup();
            root.error = "";
            root.showOk = true;
            hide.restart();
        }

        function onReloadFailed(errorString) {
            Quickshell.inhibitReloadPopup();
            root.error = errorString;
            root.showOk = false;
        }
    }

    // Quickshell stops watching files after a failed reload, so the fix you
    // save next wouldn't load by itself. While an error shows, watch the
    // shell's source tree ourselves and reload on the next write.
    Process {
        running: root.error !== ""
        command: ["inotifywait", "-qq", "-r", "-e", "close_write,moved_to,create,delete", Quickshell.shellDir]
        onExited: if (root.error !== "")
            Quickshell.reload(false)
    }

    Timer {
        id: hide
        interval: 1200
        onTriggered: root.showOk = false
    }

    IpcHandler {
        target: "shell"

        function reload(): void {
            Quickshell.reload(false);
        }

        // Rebuilds every window too (soft reload reuses them).
        function hardReload(): void {
            Quickshell.reload(true);
        }

        function lastError(): string {
            return root.error;
        }
    }

    PanelWindow {
        id: toast
        visible: root.error !== "" || root.showOk
        screen: Quickshell.screens.find(s => s.name === (Niri.focusedWorkspace?.output ?? "")) ?? Quickshell.screens[0]

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "loft:reload"
        exclusionMode: ExclusionMode.Ignore
        anchors {
            top: true
            right: true
        }
        margins {
            top: 50
            right: 14
        }
        implicitWidth: root.error !== "" ? 560 : okRow.implicitWidth + 32
        implicitHeight: root.error !== "" ? errorCol.implicitHeight + 28 : 40
        color: "transparent"
        mask: Region {
            item: card
        }

        BackgroundEffect.blurRegion: blur
        Region {
            id: blur
            item: Theme.blur ? card : null
            radius: card.radius
        }

        GlassSurface {
            id: card
            anchors.fill: parent
            radius: root.error !== "" ? 18 : height / 2
            strength: 1.7
            border.color: root.error !== "" ? Theme.urgent : Theme.glassBorder
            border.width: root.error !== "" ? 2 : 1

            RowLayout {
                id: okRow
                visible: root.error === ""
                anchors.centerIn: parent
                spacing: 8

                Icon {
                    text: "󰄬"
                    size: 15
                    color: Theme.ok
                }
                Text {
                    text: "Reloaded"
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                    font.weight: Font.Medium
                }
            }

            ColumnLayout {
                id: errorCol
                visible: root.error !== ""
                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                    margins: 14
                }
                spacing: 6

                RowLayout {
                    spacing: 8
                    Icon {
                        text: "󰀦"
                        size: 15
                        color: Theme.urgent
                    }
                    Text {
                        Layout.fillWidth: true
                        text: "Reload failed — still running the last good version · fix and save to retry"
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                    }
                    Icon {
                        text: "󰅖"
                        size: 13
                        color: Theme.subtext
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.error = ""
                        }
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: root.error.split("\n").slice(0, 8).join("\n")
                    color: Theme.subtext
                    font.family: "monospace"
                    font.pixelSize: 11
                    wrapMode: Text.WrapAnywhere
                    textFormat: Text.PlainText
                }
            }
        }
    }
}
