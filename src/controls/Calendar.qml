import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.components
import qs.services

// Month calendar: header with month/year and arrows, weekday row, day grid
// with today highlighted. Scroll or click the arrows to change month.
GlassSurface {
    id: root

    property int month: new Date().getMonth()
    property int year: new Date().getFullYear()

    function shift(delta) {
        const d = new Date(year, month + delta, 1);
        month = d.getMonth();
        year = d.getFullYear();
    }

    implicitHeight: column.implicitHeight + 24
    radius: 22
    showHighlight: false

    WheelHandler {
        onWheel: event => root.shift(event.angleDelta.y > 0 ? -1 : 1)
    }

    ColumnLayout {
        id: column
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            margins: 12
        }
        spacing: 6

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 4

            Text {
                Layout.fillWidth: true
                text: new Date(root.year, root.month, 1).toLocaleDateString(Qt.locale(), "MMMM yyyy")
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 14
                font.weight: Font.DemiBold
            }

            Repeater {
                model: [
                    { icon: "󰅁", delta: -1 },
                    { icon: "󰅂", delta: 1 }
                ]
                delegate: Icon {
                    required property var modelData
                    text: modelData.icon
                    size: 18
                    color: Theme.subtext
                    Layout.preferredWidth: 26

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.shift(parent.modelData.delta)
                    }
                }
            }
        }

        DayOfWeekRow {
            Layout.fillWidth: true
            locale: grid.locale
            delegate: Text {
                required property string shortName
                text: shortName.slice(0, 2)
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                horizontalAlignment: Text.AlignHCenter
            }
        }

        MonthGrid {
            id: grid
            Layout.fillWidth: true
            // MonthGrid doesn't derive a size inside layouts: 6 rows of cells.
            Layout.preferredHeight: 6 * 30 + 5 * spacing
            month: root.month
            year: root.year
            locale: Qt.locale()
            spacing: 2

            delegate: Item {
                id: day
                required property var model
                readonly property bool today: model.today
                implicitWidth: 30
                implicitHeight: 30

                Rectangle {
                    anchors.centerIn: parent
                    width: 28
                    height: 28
                    radius: 14
                    color: day.today ? Theme.accent : "transparent"
                }

                Text {
                    anchors.centerIn: parent
                    text: day.model.day
                    color: day.today ? Theme.bg : Theme.text
                    opacity: day.model.month === root.month ? 1 : 0.35
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                    font.weight: day.today ? Font.Bold : Font.Normal
                }
            }
        }
    }
}
