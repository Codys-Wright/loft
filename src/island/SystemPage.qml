import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services

// Island system page: date + CPU and memory gauges.
Item {
    id: root

    component Gauge: ColumnLayout {
        id: gauge
        property string icon
        property string label
        property real value
        property string detail

        spacing: 6

        Item {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 84
            Layout.preferredHeight: 84

            Canvas {
                id: ring
                anchors.fill: parent
                readonly property real v: gauge.value
                onVChanged: requestPaint()
                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    ctx.lineWidth = 7;
                    ctx.lineCap = "round";
                    const r = width / 2 - 5;
                    ctx.strokeStyle = Theme.withAlpha(Theme.text, 0.15);
                    ctx.beginPath();
                    ctx.arc(width / 2, height / 2, r, 0, 2 * Math.PI);
                    ctx.stroke();
                    ctx.strokeStyle = gauge.value > 0.85 ? Theme.urgent : Theme.accent;
                    ctx.beginPath();
                    ctx.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + 2 * Math.PI * Math.max(0.01, gauge.value));
                    ctx.stroke();
                }
            }

            Column {
                anchors.centerIn: parent

                Icon {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: gauge.icon
                    size: 16
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: `${Math.round(gauge.value * 100)}%`
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }
            }
        }

        Text {
            Layout.alignment: Qt.AlignHCenter
            text: gauge.detail || gauge.label
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
    }

    RowLayout {
        anchors.fill: parent
        anchors.bottomMargin: 8
        spacing: 24

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 2

            Text {
                // 12-hour, without the AM/PM suffix, like the lock screen.
                text: Qt.formatDateTime(clock.date, "h:mm AP").replace(/\s*[AP]M$/i, "")
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 44
                font.weight: Font.Light
            }

            Text {
                text: Qt.formatDateTime(clock.date, "dddd, MMMM d")
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 13
            }
        }

        Gauge {
            icon: "󰍛"
            label: "CPU"
            value: SystemStats.cpu
            detail: "CPU"
        }

        Gauge {
            icon: "󰘚"
            label: "Memory"
            value: SystemStats.memory
            detail: `${SystemStats.memoryUsedGiB.toFixed(1)} / ${SystemStats.memoryTotalGiB.toFixed(0)} GiB`
        }
    }

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }
}
