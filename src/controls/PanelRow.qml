import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// A row in a control panel (menu bar dropdown / expanded Control Center
// module), shaped like MenuPanel's rows: highlight on hover or keyboard
// (Nav), an optional device disc on the left, text + detail, something on
// the right. Children go under the row (inline password field, details).
Item {
    id: row

    property string text
    property string detail
    property string trailing // text on the right
    property string trailingGlyph // glyph on the right (Wi-Fi bars, lock, ›)
    property string trailingGlyph2
    property string glyph // device disc on the left ("" = none)
    property bool glyphActive: false
    property bool checked: false // ✓ on the right
    property bool dim: false
    property bool bold: false
    default property alias extra: below.data

    readonly property bool navigable: enabled
    readonly property bool lit: enabled && Nav.item === row

    signal clicked
    signal rightClicked

    function activate() {
        clicked();
    }

    Layout.fillWidth: true
    implicitWidth: line.implicitWidth + 20
    implicitHeight: head.height + (below.children.length > 0 && below.visible ? below.implicitHeight + 4 : 0)

    Item {
        id: head
        width: parent.width
        height: row.glyph !== "" ? (row.detail !== "" ? 42 : 36) : (row.detail !== "" ? 38 : 26)

        Rectangle {
            anchors.fill: parent
            radius: 7
            color: row.lit ? Theme.accent : "transparent"
        }

        RowLayout {
            id: line
            anchors {
                fill: parent
                leftMargin: row.glyph !== "" ? 6 : 10
                rightMargin: 10
            }
            spacing: 10

            DeviceDisc {
                visible: row.glyph !== ""
                glyph: row.glyph
                active: row.glyphActive
                inverted: row.lit
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                    Layout.fillWidth: true
                    text: row.text
                    color: row.lit ? Theme.bg : Theme.text
                    opacity: row.enabled && !row.dim ? 1 : 0.45
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                    font.weight: row.bold ? Font.DemiBold : Font.Normal
                    elide: Text.ElideRight
                }
                Text {
                    Layout.fillWidth: true
                    visible: row.detail !== ""
                    text: row.detail
                    color: row.lit ? Theme.bg : Theme.subtext
                    opacity: 0.9
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }

            Text {
                visible: row.trailing !== ""
                text: row.trailing
                color: row.lit ? Theme.bg : Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 12
                font.features: {
                    "tnum": 1
                }
            }
            Icon {
                visible: row.trailingGlyph2 !== ""
                text: row.trailingGlyph2
                size: 13
                color: row.lit ? Theme.bg : Theme.subtext
            }
            Icon {
                visible: row.trailingGlyph !== ""
                text: row.trailingGlyph
                size: 14
                color: row.lit ? Theme.bg : Theme.text
            }
            Icon {
                visible: row.checked
                text: "󰄬"
                size: 13
                color: row.lit ? Theme.bg : Theme.accent
            }
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            enabled: row.enabled
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: Qt.PointingHandCursor
            onEntered: Nav.item = row
            onExited: if (Nav.item === row)
                Nav.item = null
            onClicked: mouse => mouse.button === Qt.RightButton ? row.rightClicked() : row.clicked()
        }
    }

    ColumnLayout {
        id: below
        visible: children.length > 0
        anchors {
            left: parent.left
            right: parent.right
            top: head.bottom
            topMargin: 4
            leftMargin: 10
            rightMargin: 10
        }
        spacing: 6
    }
}
