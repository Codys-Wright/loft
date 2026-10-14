import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services
import qs.settings

// System Monitor → Network: live traffic (/proc/net/dev), totals for this
// session, interfaces with their local addresses, and a speed test that
// only runs when asked to.
ColumnLayout {
    id: page
    spacing: 12

    // Addresses change rarely: re-read them while the page is shown.
    Timer {
        running: page.visible && SystemStats.monitorOpen
        interval: 30000
        repeat: true
        triggeredOnStart: true
        onTriggered: NetworkInfo.refresh()
    }

    component Stat: ColumnLayout {
        property string label
        property string value
        property color dot: "transparent"
        spacing: 2
        RowLayout {
            spacing: 5
            Rectangle {
                visible: parent.parent.dot.a > 0
                width: 8
                height: 8
                radius: 4
                color: parent.parent.dot
            }
            Text {
                text: parent.parent.label
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 10
                font.capitalization: Font.AllUppercase
                font.letterSpacing: 0.4
            }
        }
        Text {
            text: parent.value
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 17
            font.weight: Font.Light
            font.features: {
                "tnum": 1
            }
        }
    }

    // ── Traffic ─────────────────────────────────────────────────────────
    MonitorCard {
        icon: "󰛳"
        title: "Traffic"
        caption: "Physical interfaces, last five minutes"
        value: ""

        HistoryGraph {
            Layout.fillWidth: true
            Layout.preferredHeight: 130
            values: SystemStats.history.rx
            values2: SystemStats.history.tx
            max: 0
            minMax: 64000
            color: Theme.accent
            color2: Theme.ok
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 24
            Stat {
                label: "Download"
                value: SystemStats.formatRate(SystemStats.netRx)
                dot: Theme.accent
            }
            Stat {
                label: "Upload"
                value: SystemStats.formatRate(SystemStats.netTx)
                dot: Theme.ok
            }
            Item {
                Layout.fillWidth: true
            }
            Stat {
                label: "Received (session)"
                value: SystemStats.formatBytes(SystemStats.sessionRx)
            }
            Stat {
                label: "Sent (session)"
                value: SystemStats.formatBytes(SystemStats.sessionTx)
            }
        }
    }

    // ── Interfaces ──────────────────────────────────────────────────────
    SettingsCard {
        spacing: 10

        PageHeader {
            title: "Interfaces"
            SettingsButton {
                text: "Refresh"
                icon: "󰑐"
                onClicked: NetworkInfo.refresh()
            }
        }

        Repeater {
            // Physical ones, plus virtual ones with a routable address (VPNs,
            // bridges) — not every container's veth.
            model: SystemStats.interfaces.filter(i => i.physical || NetworkInfo.addressesOf(i.name).some(a => a.scope !== "link"))

            delegate: RowLayout {
                id: iface
                required property var modelData
                readonly property var addrs: NetworkInfo.addressesOf(modelData.name)
                Layout.fillWidth: true
                spacing: 12

                Rectangle {
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    Layout.alignment: Qt.AlignTop
                    radius: 10
                    color: iface.modelData.physical ? Theme.withAlpha(Theme.accent, 0.18) : Theme.withAlpha(Theme.text, 0.08)
                    Icon {
                        anchors.centerIn: parent
                        text: iface.modelData.wireless ? "󰖩" : iface.modelData.physical ? "󰈀" : "󰒄"
                        size: 15
                        color: iface.modelData.physical ? Theme.accent : Theme.subtext
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Text {
                        text: iface.modelData.name + (iface.modelData.physical ? "" : "  · virtual")
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                        font.weight: Font.Medium
                    }
                    Text {
                        Layout.fillWidth: true
                        text: iface.addrs.length ? iface.addrs.filter(a => a.scope !== "link").concat(iface.addrs.filter(a => a.scope === "link")).slice(0, 3).map(a => `${a.address}/${a.prefix}`).join("   ") : "No address"
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }

                ColumnLayout {
                    spacing: 2
                    Text {
                        Layout.alignment: Qt.AlignRight
                        text: `↓ ${SystemStats.formatRate(iface.modelData.rxRate)}   ↑ ${SystemStats.formatRate(iface.modelData.txRate)}`
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.features: {
                            "tnum": 1
                        }
                    }
                    Text {
                        Layout.alignment: Qt.AlignRight
                        text: `session ↓ ${SystemStats.formatBytes(iface.modelData.rxSession)}  ↑ ${SystemStats.formatBytes(iface.modelData.txSession)}`
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 10
                        font.features: {
                            "tnum": 1
                        }
                    }
                }
            }
        }
    }

    // ── Speed test ──────────────────────────────────────────────────────
    SettingsCard {
        spacing: 12

        PageHeader {
            title: "Speed test"
            SettingsButton {
                text: NetworkInfo.speedRunning ? "Cancel" : NetworkInfo.speedResult ? "Run again" : "Run"
                icon: NetworkInfo.speedRunning ? "󰜺" : "󰓅"
                primary: !NetworkInfo.speedRunning
                onClicked: NetworkInfo.speedRunning ? NetworkInfo.cancelSpeedTest() : NetworkInfo.runSpeedTest()
            }
        }

        Text {
            Layout.fillWidth: true
            text: NetworkInfo.speedRunning ? "Testing download and upload against the nearest LibreSpeed server — about 30 seconds…" : NetworkInfo.speedError !== "" ? NetworkInfo.speedError : NetworkInfo.speedResult ? `${NetworkInfo.speedResult.server} · ${Qt.formatDateTime(NetworkInfo.speedResult.at, "h:mm AP")}` : "Measures your connection with LibreSpeed. Nothing is sent until you press Run."
            color: NetworkInfo.speedError !== "" && !NetworkInfo.speedRunning ? Theme.urgent : Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        RowLayout {
            Layout.fillWidth: true
            visible: NetworkInfo.speedResult !== null
            spacing: 24
            Stat {
                label: "Download"
                value: NetworkInfo.speedResult ? `${NetworkInfo.speedResult.download.toFixed(1)} Mbit/s` : ""
                dot: Theme.accent
            }
            Stat {
                label: "Upload"
                value: NetworkInfo.speedResult ? `${NetworkInfo.speedResult.upload.toFixed(1)} Mbit/s` : ""
                dot: Theme.ok
            }
            Stat {
                label: "Ping"
                value: NetworkInfo.speedResult ? `${NetworkInfo.speedResult.ping.toFixed(0)} ms` : ""
            }
            Stat {
                label: "Jitter"
                value: NetworkInfo.speedResult ? `${NetworkInfo.speedResult.jitter.toFixed(1)} ms` : ""
            }
        }
    }
}
