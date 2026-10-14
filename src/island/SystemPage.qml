import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services

// Island system page: clock + date (+ Open Monitor), and CPU / GPU / memory gauges with
// temperatures. Gauges turn red past the alert thresholds.
Item {
    id: root

    component Gauge: ColumnLayout {
        id: gauge
        property string icon
        property real value
        property string detail
        property bool hot: false

        spacing: 6

        Item {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 78
            Layout.preferredHeight: 78

            ProgressRing {
                anchors.fill: parent
                value: gauge.value
                lineWidth: 7
                color: gauge.hot ? Theme.urgent : Theme.accent
            }

            Column {
                anchors.centerIn: parent

                Icon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: gauge.icon
                    size: 15
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: gauge.value < 0 ? "—" : `${Math.round(gauge.value * 100)}%`
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }
            }
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: gauge.detail
            color: gauge.hot ? Theme.urgent : Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
    }

    RowLayout {
        anchors {
            fill: parent
            margins: 18
            bottomMargin: 26
        }
        spacing: 18

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 2

            Text {
                // 12-hour, without the AM/PM suffix, like the lock screen.
                text: Qt.formatDateTime(clock.date, "h:mm AP").replace(/\s*[AP]M$/i, "")
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 40
                font.weight: Font.Light
            }

            Text {
                text: Qt.formatDateTime(clock.date, "dddd, MMMM d")
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 12
            }

            // System Monitor (graphs, processes, disks).
            Rectangle {
                visible: Features.on("systemMonitor")
                Layout.topMargin: 8
                implicitWidth: openRow.implicitWidth + 20
                implicitHeight: 24
                radius: 12
                color: openMouse.containsMouse ? Theme.withAlpha(Theme.text, 0.16) : Theme.withAlpha(Theme.text, 0.08)

                Row {
                    id: openRow
                    anchors.centerIn: parent
                    spacing: 6
                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "󰄧"
                        size: 11
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Open Monitor"
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        font.weight: Font.Medium
                    }
                }

                MouseArea {
                    id: openMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        SystemStats.monitorSection = "overview";
                        SystemStats.monitorOpen = true;
                    }
                }
            }
        }

        Gauge {
            icon: "󰍛"
            value: SystemStats.cpu
            detail: SystemStats.cpuTemp > 0 ? `CPU  ${Math.round(SystemStats.cpuTemp)}°` : "CPU"
            hot: SystemStats.cpuTemp > SystemStats.maxTemp || SystemStats.cpu > SystemStats.maxLoad
        }

        Gauge {
            visible: SystemStats.gpu >= 0
            icon: "󰢮"
            value: SystemStats.gpu
            detail: SystemStats.gpuTemp > 0 ? `GPU  ${Math.round(SystemStats.gpuTemp)}°` : "GPU"
            hot: SystemStats.gpuTemp > SystemStats.maxTemp
        }

        Gauge {
            icon: "󰘚"
            value: SystemStats.memory
            detail: `${SystemStats.memoryUsedGiB.toFixed(0)}/${SystemStats.memoryTotalGiB.toFixed(0)} GiB`
            hot: SystemStats.memory > SystemStats.maxLoad
        }
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }
}
