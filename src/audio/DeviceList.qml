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

    // Devices, then routing under its own heading (Sound.sinks puts
    // devices first).
    Repeater {
        model: root.nodes
        delegate: ColumnLayout {
            id: row
            required property var modelData
            required property int index
            readonly property bool routing: !Sound.isHardware(modelData)
            Layout.fillWidth: true
            spacing: 1

            Text {
                visible: row.routing && (row.index === 0 || Sound.isHardware(root.nodes[row.index - 1]))
                Layout.fillWidth: true
                Layout.topMargin: row.index === 0 ? 0 : 6
                Layout.leftMargin: 8
                text: "Routing"
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
            }

            Entry {
                glyph: root.iconFor(row.modelData)
                text: Sound.label(row.modelData)
                checked: !root.followingDefault && row.modelData.id === root.currentId
                onClicked: root.picked(row.modelData)
            }
        }
    }
}
