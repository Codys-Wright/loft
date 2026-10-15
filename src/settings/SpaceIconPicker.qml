import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Spaces: pick a space's icon — a Nerd Font glyph or an emoji
// from the grid, or anything typed / pasted into the field. Emits
// picked(icon); the owner sets `current`.
ColumnLayout {
    id: picker
    property string current: ""
    signal picked(string icon)
    spacing: 8

    // Material Design glyphs (Nerd Fonts' nf-md range), by code point so a
    // file encoding can't mangle them.
    readonly property var glyphs: [0xF02DC, 0xF075A, 0xF0567, 0xF0B79, 0xF0297, 0xF0135, 0xF0169, 0xF018D, 0xF059F, 0xF14F7, 0xF03EB, 0xF03D8, 0xF0100, 0xF036C, 0xF02CB, 0xF02E9, 0xF024B, 0xF00ED, 0xF01EE, 0xF00D6, 0xF0474, 0xF048B, 0xF012A, 0xF0093, 0xF14DE, 0xF0176, 0xF0493, 0xF02D1, 0xF04CE, 0xF0570].map(c => String.fromCodePoint(c))
    readonly property var emoji: ["🏠", "🎵", "🎬", "💬", "🎮", "💻", "📚", "✍️", "🎨", "🧪", "📈", "🛠️", "🌙", "☕", "🚀", "🌿"]

    component Choice: Rectangle {
        id: choice
        property string icon
        property bool isEmoji: false
        readonly property bool selected: picker.current === icon
        implicitWidth: 30
        implicitHeight: 30
        radius: 7
        color: selected ? Theme.withAlpha(Theme.accent, 0.3) : hov.containsMouse ? Theme.withAlpha(Theme.text, 0.1) : "transparent"
        border.width: selected ? 1 : 0
        border.color: Theme.accent

        Icon {
            visible: !choice.isEmoji
            anchors.centerIn: parent
            text: choice.icon
            size: 16
            color: Theme.text
        }
        Text {
            visible: choice.isEmoji
            anchors.centerIn: parent
            text: choice.icon
            font.pixelSize: 16
        }
        MouseArea {
            id: hov
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: picker.picked(choice.icon)
        }
    }

    Flow {
        Layout.fillWidth: true
        spacing: 2
        Repeater {
            model: picker.glyphs
            delegate: Choice {
                required property string modelData
                icon: modelData
            }
        }
    }
    Flow {
        Layout.fillWidth: true
        spacing: 2
        Repeater {
            model: picker.emoji
            delegate: Choice {
                required property string modelData
                icon: modelData
                isEmoji: true
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Text {
            text: "Or type / paste one"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
        SettingsTextField {
            implicitWidth: 90
            text: picker.current
            placeholder: "󰕰"
            onCommitted: t => {
                const v = t.trim();
                if (v !== picker.current)
                    picker.picked(v);
            }
        }
    }
}
