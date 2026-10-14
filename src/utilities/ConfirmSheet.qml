import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services
import qs.settings

// A modal sheet over the Utilities window: icon, title, text and buttons
// ([{ label, primary, run }], left to right). A click outside or `dismissed`
// cancels.
Rectangle {
    id: sheet

    property bool shown: false
    property string icon: "󰀦"
    property color iconColor: Theme.urgent
    property string title
    property string text
    property var buttons: []
    // Extra content under the text (e.g. a command to copy).
    default property alias extra: extraSlot.data

    signal dismissed

    anchors.fill: parent
    visible: shown
    color: Theme.withAlpha("#000000", 0.35)

    MouseArea {
        anchors.fill: parent
        onClicked: sheet.dismissed()
    }

    GlassSurface {
        anchors.centerIn: parent
        width: 420
        height: col.implicitHeight + 40
        radius: 20
        strength: 2.2

        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            id: col
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: 20
            }
            spacing: 10

            Icon {
                Layout.alignment: Qt.AlignHCenter
                text: sheet.icon
                size: 30
                color: sheet.iconColor
            }
            Text {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: sheet.title
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 15
                font.weight: Font.DemiBold
                wrapMode: Text.Wrap
            }
            Text {
                Layout.fillWidth: true
                visible: text !== ""
                horizontalAlignment: Text.AlignHCenter
                text: sheet.text
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }
            ColumnLayout {
                id: extraSlot
                Layout.fillWidth: true
                spacing: 6
            }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.topMargin: 6
                spacing: 8
                Repeater {
                    model: sheet.buttons
                    delegate: SettingsButton {
                        required property var modelData
                        text: modelData.label
                        primary: modelData.primary === true
                        enabled: modelData.enabled !== false
                        onClicked: modelData.run()
                    }
                }
            }
        }
    }
}
