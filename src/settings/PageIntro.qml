import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// The head of a top-level Settings page (System Settings' header card): a
// large badge, the page's name and a line about it, then `facts` — short
// "what's on" chips ([{ label, on }] or strings) — so the state of the page
// reads at a glance. Children go to the right (a wallpaper thumbnail, …).
SettingsCard {
    id: intro

    property string icon
    property string badge: "gray"
    property string title
    property string description
    property var facts: []
    default property alias aside: asideSlot.data

    RowLayout {
        Layout.fillWidth: true
        spacing: 14

        IconBadge {
            Layout.alignment: Qt.AlignTop
            icon: intro.icon
            badge: intro.badge
            size: 48
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 4

            Text {
                Layout.fillWidth: true
                text: intro.title
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 18
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: intro.description
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 12
                wrapMode: Text.Wrap
            }

            Flow {
                Layout.fillWidth: true
                Layout.topMargin: 4
                visible: intro.facts.length > 0
                spacing: 6

                Repeater {
                    model: intro.facts
                    delegate: Rectangle {
                        id: chip
                        required property var modelData
                        readonly property bool isObj: typeof modelData === "object" && modelData !== null
                        readonly property bool on: isObj ? modelData.on !== false : true
                        implicitWidth: chipRow.implicitWidth + 16
                        implicitHeight: 22
                        radius: 11
                        color: Theme.withAlpha(Theme.text, 0.07)

                        Row {
                            id: chipRow
                            anchors.centerIn: parent
                            spacing: 5
                            Rectangle {
                                visible: chip.isObj
                                anchors.verticalCenter: parent.verticalCenter
                                width: 6
                                height: 6
                                radius: 3
                                color: chip.on ? Theme.badgeColor("green") : Theme.withAlpha(Theme.text, 0.3)
                            }
                            Text {
                                text: chip.isObj ? chip.modelData.label : chip.modelData
                                color: chip.on ? Theme.text : Theme.subtext
                                font.family: Theme.fontUi
                                font.pixelSize: 11
                            }
                        }
                    }
                }
            }
        }

        RowLayout {
            id: asideSlot
            Layout.alignment: Qt.AlignVCenter
            spacing: 8
        }
    }
}
