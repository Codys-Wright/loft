import QtQuick
import QtQuick.Layouts
import qs.services

// A glass text field for inline entry (Wi-Fi password, hidden SSID).
// While it has focus, Nav.typing tells the menu not to steal Enter/Space.
Rectangle {
    id: field
    property alias text: input.text
    property string placeholder
    property bool password: false
    signal accepted
    signal cancelled

    function focusField() {
        input.forceActiveFocus();
    }

    Layout.fillWidth: true
    implicitHeight: 28
    radius: Theme.controlRadius
    color: Theme.withAlpha(Theme.text, 0.08)
    border.width: 1
    border.color: input.activeFocus ? Theme.accent : Theme.glassBorder

    TextInput {
        id: input
        anchors {
            fill: parent
            leftMargin: 9
            rightMargin: 9
        }
        verticalAlignment: TextInput.AlignVCenter
        color: Theme.text
        selectionColor: Theme.accent
        selectedTextColor: Theme.bg
        font.family: Theme.fontUi
        font.pixelSize: 13
        echoMode: field.password ? TextInput.Password : TextInput.Normal
        clip: true
        onAccepted: field.accepted()
        onActiveFocusChanged: Nav.typing = activeFocus
        Keys.onEscapePressed: event => {
            field.cancelled();
            event.accepted = true;
        }

        Text {
            visible: input.text === ""
            anchors.verticalCenter: parent.verticalCenter
            text: field.placeholder
            color: Theme.subtext
            font: input.font
        }
    }
}
