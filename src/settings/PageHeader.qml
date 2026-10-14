import QtQuick
import QtQuick.Layouts
import qs.services

// A card's title line, with an optional right-aligned action (children).
RowLayout {
    id: header
    property string title
    default property alias actions: slot.data
    Layout.fillWidth: true
    spacing: 8

    Text {
        Layout.fillWidth: true
        text: header.title
        color: Theme.text
        font.family: Theme.fontUi
        font.pixelSize: 14
        font.weight: Font.DemiBold
    }

    RowLayout {
        id: slot
        spacing: 8
    }
}
