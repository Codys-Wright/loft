import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// An incoming iPhone call in the island (iOS's live activity): who's calling
// and round Decline / Answer buttons. tetherd controls the call over
// Bluetooth HFP; the audio stays on the phone (Phone.qml).
Item {
    id: root

    property var call: null

    readonly property color green: "#34c759"
    readonly property color red: "#ff3b30"

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 4
        spacing: 12

        // The caller's initial in a disc, ringing.
        Rectangle {
            Layout.preferredWidth: 52
            Layout.preferredHeight: 52
            radius: 26
            color: Theme.withAlpha(Theme.islandText, 0.14)

            Text {
                anchors.centerIn: parent
                visible: initial.text !== ""
                id: initial
                text: {
                    const n = Phone.callerName(root.call);
                    return /^[A-Za-z]/.test(n) ? n[0].toUpperCase() : "";
                }
                color: Theme.islandText
                font.family: Theme.fontUi
                font.pixelSize: 22
                font.weight: Font.DemiBold
            }
            Icon {
                anchors.centerIn: parent
                visible: initial.text === ""
                text: "󰀉"
                size: 30
                color: Theme.islandSubtext
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 1

            RowLayout {
                spacing: 5
                Icon {
                    text: "󰏷"
                    size: 11
                    color: root.green

                    SequentialAnimation on opacity {
                        running: root.visible
                        loops: Animation.Infinite
                        NumberAnimation {
                            to: 0.35
                            duration: 500
                        }
                        NumberAnimation {
                            to: 1
                            duration: 500
                        }
                    }
                }
                Text {
                    text: `${Phone.callStateLabel(root.call)} · ${Phone.deviceName}`
                    color: Theme.islandSubtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }

            Text {
                Layout.fillWidth: true
                text: Phone.callerName(root.call)
                color: Theme.islandText
                font.family: Theme.fontUi
                font.pixelSize: 15
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: root.call?.name && root.call?.number ? root.call.number : ""
                color: Theme.islandSubtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }

        IslandButton {
            size: 44
            icon: "󰏵"
            tint: root.red
            on: true
            onClicked: Phone.decline()
        }

        IslandButton {
            Layout.rightMargin: 4
            size: 44
            icon: "󰏲"
            tint: root.green
            on: true
            onClicked: Phone.answer()
        }
    }
}
