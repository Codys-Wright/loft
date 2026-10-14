import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Island page: today's screen time — total plus the top apps as bars.
Item {
    id: root

    readonly property var topApps: AppUsage.ranked.slice(0, 4)
    readonly property real max: topApps.length ? topApps[0].seconds : 1

    RowLayout {
        anchors {
            fill: parent
            margins: 18
            bottomMargin: 28
        }
        spacing: 22

        ColumnLayout {
            Layout.preferredWidth: 130
            Layout.alignment: Qt.AlignVCenter
            spacing: 2

            Text {
                text: "Screen Time"
                color: Theme.islandSubtext
                font.family: Theme.fontUi
                font.pixelSize: 12
            }

            Text {
                text: AppUsage.format(AppUsage.total)
                color: Theme.islandText
                font.family: Theme.fontUi
                font.pixelSize: 30
                font.weight: Font.Light
            }

            Text {
                text: "today"
                color: Theme.islandSubtext
                font.family: Theme.fontUi
                font.pixelSize: 12
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 8

            Text {
                visible: root.topApps.length === 0
                text: "Tracking starts as you use apps."
                color: Theme.islandSubtext
                font.family: Theme.fontUi
                font.pixelSize: 12
            }

            Repeater {
                model: root.topApps

                delegate: RowLayout {
                    id: bar
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 8

                    AppIcon {
                        Layout.preferredWidth: 20
                        Layout.preferredHeight: 20
                        appId: bar.modelData.appId
                        pixelSize: 40
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 20

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(8, parent.width * bar.modelData.seconds / root.max)
                            height: 8
                            radius: 4
                            color: Theme.accent
                            opacity: 0.85
                        }
                    }

                    Text {
                        Layout.preferredWidth: 52
                        horizontalAlignment: Text.AlignRight
                        text: AppUsage.format(bar.modelData.seconds)
                        color: Theme.islandText
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        font.features: { "tnum": 1 }
                    }
                }
            }
        }
    }
}
