import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.components
import qs.services
import qs.settings

// System Monitor: a floating glass window (like macOS Activity Monitor) with
// history graphs, processes, network and disks/sensors. While it's open,
// SystemStats samples every second and reads processes, sensors and disks;
// closed, none of that runs.
// Open from the island's system page, a bar readout, or IPC monitor toggle.
Scope {
    id: root

    readonly property bool open: SystemStats.monitorOpen
    readonly property string section: SystemStats.monitorSection

    readonly property var sections: [
        {
            id: "overview",
            icon: "󰄧",
            label: "Overview"
        },
        {
            id: "processes",
            icon: "󰉹",
            label: "Processes"
        },
        {
            id: "network",
            icon: "󰛳",
            label: "Network",
            feature: "network"
        },
        {
            id: "disks",
            icon: "󰋊",
            label: "Disks & Sensors"
        }
    ]

    function show(section) {
        SystemStats.monitorSection = section;
        SystemStats.monitorOpen = true;
    }

    IpcHandler {
        target: "monitor"

        function toggle(): void {
            SystemStats.monitorOpen = !SystemStats.monitorOpen;
        }
        function open(): void {
            SystemStats.monitorOpen = true;
        }
        function close(): void {
            SystemStats.monitorOpen = false;
        }
        function overview(): void {
            root.show("overview");
        }
        function processes(): void {
            root.show("processes");
        }
        function network(): void {
            root.show("network");
        }
        function disks(): void {
            root.show("disks");
        }
    }

    FloatingWindow {
        id: window
        visible: root.open
        title: "System Monitor"
        implicitWidth: 940
        implicitHeight: 660
        color: "transparent"
        onVisibleChanged: if (!visible)
            SystemStats.monitorOpen = false

        BackgroundEffect.blurRegion: Theme.blur ? blur : null
        Region {
            id: blur
            item: frame
            radius: frame.radius
        }

        GlassSurface {
            id: frame
            anchors.fill: parent
            radius: 24
            strength: 1.7

            focus: root.open
            Keys.onEscapePressed: {
                if (processes.confirming)
                    processes.confirming = null;
                else
                    SystemStats.monitorOpen = false;
            }

            RowLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 12

                // Sidebar
                ColumnLayout {
                    Layout.preferredWidth: 190
                    Layout.maximumWidth: 190
                    Layout.fillHeight: true
                    spacing: 4

                    Text {
                        Layout.leftMargin: 10
                        Layout.topMargin: 6
                        Layout.bottomMargin: 8
                        text: "System Monitor"
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 18
                        font.weight: Font.DemiBold
                    }

                    Repeater {
                        model: root.sections.filter(s => !s.feature || Features.on(s.feature))
                        delegate: Rectangle {
                            id: item
                            required property var modelData
                            readonly property bool current: root.section === modelData.id
                            Layout.fillWidth: true
                            Layout.preferredHeight: 36
                            radius: 10
                            color: current ? Theme.accent : mouse.containsMouse ? Theme.withAlpha(Theme.text, 0.08) : "transparent"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                spacing: 10

                                Icon {
                                    text: item.modelData.icon
                                    size: 15
                                    color: item.current ? Theme.bg : Theme.text
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: item.modelData.label
                                    color: item.current ? Theme.bg : Theme.text
                                    font.family: Theme.fontUi
                                    font.pixelSize: 13
                                }
                            }

                            MouseArea {
                                id: mouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: SystemStats.monitorSection = item.modelData.id
                            }
                        }
                    }

                    Item {
                        Layout.fillHeight: true
                    }

                    // At-a-glance, whatever page is open.
                    ColumnLayout {
                        Layout.leftMargin: 10
                        Layout.bottomMargin: 6
                        spacing: 3

                        Repeater {
                            model: [
                                ["CPU", `${Math.round(SystemStats.cpu * 100)}%`],
                                ["Memory", `${Math.round(SystemStats.memory * 100)}%`],
                                ["GPU", SystemStats.gpu >= 0 ? `${Math.round(SystemStats.gpu * 100)}%` : "—"],
                                ["Uptime", SystemStats.formatDuration(SystemStats.uptime)]
                            ]
                            delegate: RowLayout {
                                required property var modelData
                                spacing: 6
                                Text {
                                    Layout.preferredWidth: 58
                                    text: modelData[0]
                                    color: Theme.subtext
                                    font.family: Theme.fontUi
                                    font.pixelSize: 11
                                }
                                Text {
                                    text: modelData[1]
                                    color: Theme.text
                                    font.family: Theme.fontUi
                                    font.pixelSize: 11
                                    font.features: {
                                        "tnum": 1
                                    }
                                }
                            }
                        }
                    }
                }

                // Content
                Flickable {
                    id: content
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: pages.implicitHeight + 6
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: pages
                        width: content.width
                        spacing: 12

                        Text {
                            Layout.topMargin: 6
                            text: root.sections.find(s => s.id === root.section)?.label ?? ""
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 22
                            font.weight: Font.DemiBold
                        }

                        OverviewPage {
                            Layout.fillWidth: true
                            visible: root.section === "overview"
                        }

                        ProcessesPage {
                            id: processes
                            Layout.fillWidth: true
                            visible: root.section === "processes"
                        }

                        NetworkPage {
                            Layout.fillWidth: true
                            visible: root.section === "network" && Features.on("network")
                        }

                        DisksPage {
                            Layout.fillWidth: true
                            visible: root.section === "disks"
                        }
                    }
                }
            }

            // ── Quit confirmation ───────────────────────────────────────
            Rectangle {
                anchors.fill: parent
                radius: frame.radius
                visible: processes.confirming !== null
                color: Theme.withAlpha("#000000", 0.35)

                MouseArea {
                    anchors.fill: parent
                    onClicked: processes.confirming = null
                }

                GlassSurface {
                    anchors.centerIn: parent
                    width: 380
                    height: sheet.implicitHeight + 40
                    radius: 20
                    strength: 2.2

                    // Swallow clicks on the sheet itself.
                    MouseArea {
                        anchors.fill: parent
                    }

                    ColumnLayout {
                        id: sheet
                        anchors {
                            left: parent.left
                            right: parent.right
                            top: parent.top
                            margins: 20
                        }
                        spacing: 10

                        readonly property var p: processes.confirming ?? {
                            pid: 0,
                            name: "",
                            cpu: 0,
                            rssKiB: 0
                        }

                        Icon {
                            Layout.alignment: Qt.AlignHCenter
                            text: "󰅚"
                            size: 30
                            color: Theme.urgent
                        }
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: `Quit “${sheet.p.name}”?`
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 15
                            font.weight: Font.DemiBold
                            wrapMode: Text.Wrap
                        }
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: `PID ${sheet.p.pid} · ${SystemStats.formatKiB(sheet.p.rssKiB)} · ${sheet.p.cpu.toFixed(1)}% CPU\nUnsaved work in it may be lost. Force Quit doesn't let it clean up.`
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            wrapMode: Text.Wrap
                        }
                        RowLayout {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.topMargin: 6
                            spacing: 8
                            SettingsButton {
                                text: "Cancel"
                                onClicked: processes.confirming = null
                            }
                            SettingsButton {
                                text: "Force Quit"
                                onClicked: {
                                    SystemStats.kill(sheet.p.pid, true);
                                    processes.confirming = null;
                                }
                            }
                            SettingsButton {
                                text: "Quit"
                                primary: true
                                onClicked: {
                                    SystemStats.kill(sheet.p.pid, false);
                                    processes.confirming = null;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
