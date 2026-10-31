import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services
import qs.settings

// Utilities → Ports: who is listening. Dev servers first (your own TCP
// servers started from a project folder or by a dev tool), with the
// project, the page title when it answers HTTP, Open in the browser, Show
// the folder and Stop (your own processes only; services/Ports.qml asks
// first and offers Force Quit when SIGTERM isn't enough). Root's and other
// users' sockets are listed without a process (Linux doesn't show us theirs).
ColumnLayout {
    id: page
    spacing: 12

    readonly property int portWidth: 64
    readonly property int addrWidth: 120

    component HeaderText: Text {
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 10
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.4
    }

    component RowButton: Rectangle {
        id: rb
        property string icon
        property string tip
        property color hot: Theme.accent
        signal clicked
        implicitWidth: 24
        implicitHeight: 24
        radius: 12
        color: ma.containsMouse ? hot : Theme.withAlpha(Theme.text, 0.08)
        Icon {
            anchors.centerIn: parent
            text: rb.icon
            size: 12
            color: ma.containsMouse ? Theme.bg : Theme.text
        }
        MouseArea {
            id: ma
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: rb.clicked()
        }
        Rectangle {
            visible: ma.containsMouse && rb.tip !== ""
            z: 10
            anchors.bottom: parent.top
            anchors.bottomMargin: 4
            anchors.horizontalCenter: parent.horizontalCenter
            width: tipText.implicitWidth + 12
            height: 20
            radius: 6
            color: Theme.withAlpha(Theme.bg, 0.92)
            Text {
                id: tipText
                anchors.centerIn: parent
                text: rb.tip
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 10
            }
        }
    }

    SettingsCard {
        spacing: 8

        PageHeader {
            title: `${Ports.filtered.length} of ${Ports.ports.length} listening` + (Ports.devCount > 0 ? ` · ${Ports.devCount} dev server${Ports.devCount === 1 ? "" : "s"}` : "")
            SettingsSegmented {
                options: [
                    {
                        value: false,
                        label: "All"
                    },
                    {
                        value: true,
                        label: "Dev servers"
                    }
                ]
                current: Ports.devOnly
                onActivated: v => Ports.devOnly = v
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 14

            SettingsTextField {
                Layout.fillWidth: true
                placeholder: "Filter by port, process or project"
                text: Ports.query
                onEdited: t => Ports.query = t
                onCommitted: t => Ports.query = t
            }
            RowLayout {
                spacing: 6
                SettingsSwitch {
                    checked: Ports.showUdp
                    onToggled: on => Ports.showUdp = on
                }
                Text {
                    text: "UDP"
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                }
            }
            RowLayout {
                spacing: 6
                SettingsSwitch {
                    checked: Ports.showOthers
                    onToggled: on => Ports.showOthers = on
                }
                Text {
                    text: "System"
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                }
            }
        }

        Text {
            Layout.fillWidth: true
            visible: Ports.notice !== "" || Ports.error !== ""
            text: Ports.error !== "" ? Ports.error : Ports.notice
            color: Ports.error !== "" ? Theme.urgent : Theme.ok
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 4
            spacing: 8
            HeaderText {
                Layout.preferredWidth: page.portWidth
                Layout.leftMargin: 8
                text: "Port"
            }
            HeaderText {
                Layout.fillWidth: true
                Layout.leftMargin: 26
                text: "Process"
            }
            HeaderText {
                Layout.preferredWidth: page.addrWidth
                text: "Address"
            }
            Item {
                Layout.preferredWidth: 88
            }
        }

        Text {
            visible: Ports.loaded && Ports.filtered.length === 0
            Layout.fillWidth: true
            Layout.topMargin: 10
            Layout.bottomMargin: 10
            horizontalAlignment: Text.AlignHCenter
            text: Ports.devOnly ? "No dev servers running." : "Nothing matches."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 12
        }

        Repeater {
            model: Ports.filtered

            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                readonly property var pr: modelData.process
                readonly property string iconSource: pr ? Apps.themed(pr.name.toLowerCase()) : ""
                readonly property bool canStop: modelData.mine && modelData.pid !== null

                Layout.fillWidth: true
                implicitHeight: Math.max(36, info.implicitHeight + 12)
                radius: 8
                color: hover.hovered ? Theme.withAlpha(Theme.text, 0.08) : index % 2 === 1 ? Theme.withAlpha(Theme.text, 0.03) : "transparent"

                HoverHandler {
                    id: hover
                }

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 8
                        rightMargin: 6
                    }
                    spacing: 8

                    ColumnLayout {
                        Layout.preferredWidth: page.portWidth
                        spacing: 0
                        Text {
                            text: row.modelData.port
                            color: row.modelData.dev ? Theme.accent : Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                            font.features: {
                                "tnum": 1
                            }
                        }
                        Text {
                            text: row.modelData.proto.toUpperCase()
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 9
                        }
                    }

                    Item {
                        Layout.preferredWidth: 18
                        Layout.preferredHeight: 18
                        Image {
                            anchors.fill: parent
                            visible: row.iconSource !== ""
                            source: row.iconSource
                            sourceSize: Qt.size(36, 36)
                            asynchronous: true
                        }
                        Icon {
                            anchors.centerIn: parent
                            visible: row.iconSource === ""
                            text: row.modelData.dev ? "󰅩" : row.modelData.uid === 0 ? "󰒓" : "󰆍"
                            size: 13
                            color: row.modelData.dev ? Theme.accent : Theme.subtext
                        }
                    }

                    ColumnLayout {
                        id: info
                        Layout.fillWidth: true
                        Layout.preferredWidth: 100 // grows; long paths elide instead of pushing
                        spacing: 1
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            Text {
                                text: row.pr ? row.pr.name : (row.modelData.uid === 0 ? "system service" : `uid ${row.modelData.uid}`)
                                color: row.modelData.mine ? Theme.text : Theme.subtext
                                font.family: Theme.fontUi
                                font.pixelSize: 12
                                font.weight: row.modelData.dev ? Font.DemiBold : Font.Normal
                            }
                            Text {
                                visible: !!row.pr?.detail && row.pr.detail !== row.pr.name
                                text: row.pr?.detail ?? ""
                                color: Theme.subtext
                                font.family: Theme.fontUi
                                font.pixelSize: 11
                            }
                            Rectangle {
                                visible: !!row.pr?.project
                                implicitWidth: projText.implicitWidth + 12
                                implicitHeight: 16
                                radius: 8
                                color: Theme.withAlpha(Theme.accent, 0.16)
                                Text {
                                    id: projText
                                    anchors.centerIn: parent
                                    text: row.pr?.project?.name ?? ""
                                    color: Theme.accent
                                    font.family: Theme.fontUi
                                    font.pixelSize: 10
                                    font.weight: Font.Medium
                                }
                            }
                            Item {
                                Layout.fillWidth: true
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: {
                                const p = row.modelData.httpProbe;
                                if (p && p.title)
                                    return `“${p.title}” · HTTP ${p.status}`;
                                if (row.pr?.cwd && row.modelData.dev)
                                    return row.pr.cwd.replace(Quickshell.env("HOME"), "~");
                                if (!row.pr && !row.modelData.mine)
                                    return "owned by another user — stop it with its service";
                                return row.modelData.pid ? `PID ${row.modelData.pid}` : "";
                            }
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 10
                            elide: Text.ElideMiddle
                        }
                    }

                    Text {
                        Layout.preferredWidth: page.addrWidth
                        text: row.modelData.addresses.length > 2 ? `${row.modelData.addresses[0]} +${row.modelData.addresses.length - 1}` : row.modelData.addresses.join(", ")
                        color: row.modelData.public ? Theme.warn : Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }

                    RowLayout {
                        Layout.preferredWidth: 88
                        Layout.maximumWidth: 88
                        layoutDirection: Qt.RightToLeft
                        spacing: 4
                        opacity: row.modelData.dev || hover.hovered ? 1 : 0
                        RowButton {
                            visible: row.canStop
                            icon: "󰓛"
                            tip: "Stop…"
                            hot: Theme.urgent
                            onClicked: Ports.ask(row.modelData)
                        }
                        RowButton {
                            visible: row.modelData.http && !!row.modelData.url
                            icon: "󰖟"
                            tip: "Open in browser"
                            onClicked: Ports.openUrl(row.modelData.url)
                        }
                        RowButton {
                            visible: !!row.pr?.project || (row.modelData.dev && !!row.pr?.cwd)
                            icon: "󰉋"
                            tip: "Show folder"
                            onClicked: Ports.openFolder(row.pr.project?.path ?? row.pr.cwd)
                        }
                    }
                }
            }
        }
    }

    Text {
        Layout.fillWidth: true
        text: "Amber addresses listen on every network interface. Only your own processes can be stopped here; system services stop with systemctl."
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 10
        wrapMode: Text.Wrap
    }
}
