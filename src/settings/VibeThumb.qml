import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// A selectable thumbnail for the Wallpaper and Lock Screen pages: a picture
// (an image, or custom content such as LockPreviewCard) over a caption, an
// accent ring when it's the one in use, chips for default / match / video.
Item {
    id: thumb

    property string image: ""
    property string title
    property string subtitle
    property bool selected: false
    property bool isDefault: false
    property string badge: ""
    // 0..1 palette closeness; < 0 hides the chip.
    property real score: -1
    property bool available: true
    // Custom picture, drawn instead of `image`.
    default property alias picture: canvas.data
    signal clicked

    implicitWidth: 162
    implicitHeight: 92 + caption.implicitHeight + 6
    opacity: available ? 1 : 0.5

    Rectangle {
        id: frame
        width: parent.width
        height: 92
        radius: 12
        color: Theme.withAlpha(Theme.text, 0.08)
        border.width: thumb.selected ? 3 : hover.containsMouse && thumb.available ? 1 : 0
        border.color: thumb.selected ? Theme.accent : Theme.withAlpha(Theme.text, 0.45)

        Item {
            id: canvas
            anchors.fill: parent
            anchors.margins: 3
            clip: true

            Image {
                anchors.fill: parent
                visible: thumb.image !== "" && status === Image.Ready
                source: thumb.image ? Vibes.url(thumb.image) : ""
                sourceSize: Qt.size(320, 180)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
            }
        }

        Icon {
            anchors.centerIn: parent
            visible: thumb.image === "" && canvas.children.length <= 1
            text: thumb.badge === "video" ? "󰕧" : "󰋩"
            size: 22
            color: Theme.subtext
        }

        // Chips over the picture.
        Row {
            anchors {
                left: parent.left
                top: parent.top
                margins: 7
            }
            spacing: 4
            z: 2

            Chip {
                visible: thumb.isDefault
                text: "Default"
            }
            Chip {
                visible: thumb.badge !== ""
                text: thumb.badge
            }
        }

        Chip {
            anchors {
                right: parent.right
                top: parent.top
                margins: 7
            }
            z: 2
            visible: thumb.score >= 0
            text: `${Math.round(thumb.score * 100)}%`
        }

        Rectangle {
            anchors {
                right: parent.right
                bottom: parent.bottom
                margins: 7
            }
            z: 2
            visible: thumb.selected
            width: 20
            height: 20
            radius: 10
            color: Theme.accent

            Icon {
                anchors.centerIn: parent
                text: "󰄬"
                size: 12
                color: Theme.bg
            }
        }
    }

    ColumnLayout {
        id: caption
        anchors {
            left: parent.left
            right: parent.right
            top: frame.bottom
            topMargin: 5
            leftMargin: 2
            rightMargin: 2
        }
        spacing: 0

        Text {
            Layout.fillWidth: true
            text: thumb.title
            color: Theme.text
            font.family: Theme.fontUi
            font.pixelSize: 12
            font.weight: thumb.selected ? Font.DemiBold : Font.Normal
            elide: Text.ElideMiddle
        }
        Text {
            Layout.fillWidth: true
            visible: text !== ""
            text: thumb.subtitle
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 10
            elide: Text.ElideRight
        }
    }

    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        enabled: thumb.available
        cursorShape: Qt.PointingHandCursor
        onClicked: thumb.clicked()
    }

    component Chip: Rectangle {
        property alias text: label.text
        width: label.implicitWidth + 12
        height: 17
        radius: 8.5
        color: Theme.withAlpha("#000000", 0.55)

        Text {
            id: label
            anchors.centerIn: parent
            color: "white"
            font.family: Theme.fontUi
            font.pixelSize: 9
            font.weight: Font.DemiBold
        }
    }
}
