import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// A pick list of audio devices (outputs or inputs) with a check on the
// current one. `followDefault` adds a first "Default output" entry, which
// picks null (per-app output: follow the system default).
ColumnLayout {
    id: root

    property var nodes: []
    property int currentId: -1
    property bool followDefault: false
    property bool followingDefault: false
    property string defaultLabel: "Default output"
    // node → glyph
    property var iconFor: n => Sound.outputIcon(n)

    signal picked(var node)

    spacing: 1

    component Entry: Rectangle {
        id: entry
        property string glyph
        property string text
        property bool checked
        signal clicked

        Layout.fillWidth: true
        implicitHeight: 30
        radius: 9
        color: hover.containsMouse ? Theme.withAlpha(Theme.text, 0.10) : "transparent"

        RowLayout {
            anchors {
                fill: parent
                leftMargin: 8
                rightMargin: 8
            }
            spacing: 10

            Rectangle {
                Layout.preferredWidth: 22
                Layout.preferredHeight: 22
                radius: 11
                color: entry.checked ? Theme.accent : Theme.withAlpha(Theme.text, 0.12)

                Icon {
                    anchors.centerIn: parent
                    text: entry.glyph
                    size: 12
                    color: entry.checked ? Theme.bg : Theme.text
                }
            }

            Text {
                Layout.fillWidth: true
                text: entry.text
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 12
                font.weight: entry.checked ? Font.DemiBold : Font.Normal
                elide: Text.ElideRight
            }

            Icon {
                visible: entry.checked
                text: "󰄬"
                size: 12
                color: Theme.accent
            }
        }

        MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: entry.clicked()
        }
    }

    Entry {
        visible: root.followDefault
        glyph: "󰒓"
        text: root.defaultLabel
        checked: root.followingDefault
        onClicked: root.picked(null)
    }

    Repeater {
        model: root.nodes
        delegate: Entry {
            required property var modelData
            glyph: root.iconFor(modelData)
            text: Sound.label(modelData)
            checked: !root.followingDefault && modelData.id === root.currentId
            onClicked: root.picked(modelData)
        }
    }
}
