import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// A System Monitor tile: icon + title, a big current value on the right,
// then its content (graph, details).
GlassSurface {
    id: card

    property string icon
    property string title
    property string value
    property color valueColor: Theme.text
    property string caption
    default property alias content: col.data

    Layout.fillWidth: true
    implicitHeight: col.implicitHeight + 28
    radius: 18
    showHighlight: false
    strength: 0.9

    ColumnLayout {
        id: col
        anchors {
            left: parent.left
            right: parent.right
            top: parent.top
            margins: 14
        }
        spacing: 10

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Icon {
                text: card.icon
                size: 15
                color: Theme.accent
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                    text: card.title
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }
                Text {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: card.caption
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }
            Text {
                text: card.value
                color: card.valueColor
                font.family: Theme.fontUi
                font.pixelSize: 22
                font.weight: Font.Light
                font.features: {
                    "tnum": 1
                }
            }
        }
    }
}
