import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Island page: every countdown and stopwatch (pause, +1 min, stop), and
// quick starts. More: `loft island timer 25m tea` or IPC `timers start`.
Item {
    id: root

    readonly property var presets: [60, 180, 300, 600, 1500]

    component Chip: Rectangle {
        id: chip
        property string text
        property string icon
        signal clicked
        implicitWidth: chipRow.implicitWidth + 20
        implicitHeight: 28
        radius: 14
        color: chipMouse.containsMouse ? Theme.withAlpha(Theme.warn, 0.32) : Theme.withAlpha(Theme.warn, 0.16)

        Row {
            id: chipRow
            anchors.centerIn: parent
            spacing: 4
            Icon {
                visible: chip.icon !== ""
                anchors.verticalCenter: parent.verticalCenter
                text: chip.icon
                size: 12
                color: Theme.warn
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: chip.text
                color: Theme.warn
                font.family: Theme.fontUi
                font.pixelSize: 12
                font.weight: Font.DemiBold
            }
        }

        MouseArea {
            id: chipMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.clicked()
        }
    }

    ColumnLayout {
        anchors {
            fill: parent
            margins: 18
            bottomMargin: 26
        }
        spacing: 8

        Text {
            visible: Timers.timers.length === 0
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: 14
            text: "Timers"
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 16
            font.weight: Font.DemiBold
        }
        Text {
            visible: Timers.timers.length === 0
            Layout.alignment: Qt.AlignHCenter
            text: "Start one below, or: loft island timer 25m tea"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }

        Repeater {
            model: Timers.timers.slice(0, 3)

            delegate: RowLayout {
                id: row
                required property var modelData
                Layout.fillWidth: true
                spacing: 12

                Item {
                    Layout.preferredWidth: 32
                    Layout.preferredHeight: 32
                    ProgressRing {
                        anchors.fill: parent
                        value: Timers.progress(row.modelData)
                        color: Theme.warn
                        lineWidth: 4
                        visible: row.modelData.kind === "timer"
                    }
                    Icon {
                        anchors.centerIn: parent
                        visible: row.modelData.kind === "stopwatch"
                        text: "󱎫"
                        size: 18
                        color: Theme.warn
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                        Layout.fillWidth: true
                        text: Timers.title(row.modelData)
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                    Text {
                        text: Timers.display(row.modelData)
                        color: row.modelData.paused ? Theme.subtext : Theme.warn
                        font.family: Theme.fontUi
                        font.pixelSize: 22
                        font.weight: Font.Light
                        font.features: { "tnum": 1 }
                    }
                }

                IslandButton {
                    size: 32
                    visible: row.modelData.kind === "timer"
                    icon: "󰐕"
                    onClicked: Timers.addTime(row.modelData.id, 60)
                }
                IslandButton {
                    size: 32
                    icon: row.modelData.paused ? "󰐊" : "󰏤"
                    tint: Theme.warn
                    onClicked: Timers.pause(row.modelData.id)
                }
                IslandButton {
                    size: 32
                    icon: "󰅖"
                    onClicked: Timers.stop(row.modelData.id)
                }
            }
        }

        Item {
            Layout.fillHeight: true
        }

        Row {
            visible: Timers.timers.length < 3
            Layout.alignment: Qt.AlignHCenter
            spacing: 6

            Repeater {
                model: root.presets
                delegate: Chip {
                    required property int modelData
                    text: modelData < 60 ? `${modelData}s` : `${modelData / 60}m`
                    onClicked: Timers.start(modelData, "")
                }
            }

            Chip {
                icon: "󱎫"
                text: "Stopwatch"
                onClicked: Timers.stopwatch("")
            }
        }
    }
}
