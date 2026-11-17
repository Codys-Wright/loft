import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Spaces under KWin: pick a KDE Activity's icon. KDE keeps a
// freedesktop icon name (what Plasma shows); the grid offers the ones the
// bar has a glyph for (Spaces.activityIcons), and the field takes any icon
// name (an app's, e.g. "zed" or "cockos-reaper"). Emits picked(name).
ColumnLayout {
    id: picker
    property string current: ""
    signal picked(string icon)
    spacing: 8

    Flow {
        Layout.fillWidth: true
        spacing: 2
        Repeater {
            model: Spaces.activityIcons
            delegate: Rectangle {
                id: choice
                required property var modelData
                readonly property bool selected: picker.current === modelData.kde
                implicitWidth: 30
                implicitHeight: 30
                radius: 7
                color: selected ? Theme.withAlpha(Theme.accent, 0.3) : hov.containsMouse ? Theme.withAlpha(Theme.text, 0.1) : "transparent"
                border.width: selected ? 1 : 0
                border.color: Theme.accent

                Icon {
                    anchors.centerIn: parent
                    text: choice.modelData.glyph
                    size: 16
                    color: Theme.text
                }
                MouseArea {
                    id: hov
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: picker.picked(choice.modelData.kde)
                }
            }
        }
    }

    RowLayout {
        spacing: 8
        SettingsTextField {
            implicitWidth: 200
            text: picker.current
            placeholder: "or any icon name"
            onCommitted: t => {
                if (t.trim() !== "")
                    picker.picked(t.trim());
            }
        }
        Text {
            text: "KDE icon name; Plasma shows it, the bar a glyph like it"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
    }
}
