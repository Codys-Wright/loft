import QtQuick
import qs.services

// A one-line text field; committed(text) on Enter or when focus leaves with
// a changed value. Shows `placeholder` when empty.
Rectangle {
    id: field
    property string text
    property string placeholder
    signal committed(string text)
    // Every keystroke (e.g. live search).
    signal edited(string text)

    function focusInput() {
        input.forceActiveFocus();
    }

    // Empty the field (e.g. after adding what was typed).
    function clear() {
        input.text = "";
        text = "";
    }

    implicitWidth: 200
    implicitHeight: 28
    radius: 8
    color: Theme.withAlpha(Theme.text, 0.06)
    border.width: 1
    border.color: input.activeFocus ? Theme.accent : Theme.withAlpha(Theme.text, 0.12)

    // Follow the stored value unless the user is typing.
    onTextChanged: if (!input.activeFocus)
        input.text = text
    Component.onCompleted: input.text = text

    TextInput {
        id: input
        anchors {
            fill: parent
            leftMargin: 9
            rightMargin: 9
        }
        verticalAlignment: TextInput.AlignVCenter
        clip: true
        color: Theme.text
        selectionColor: Theme.withAlpha(Theme.accent, 0.5)
        font.family: Theme.fontUi
        font.pixelSize: 12
        selectByMouse: true
        onTextEdited: field.edited(text)
        onAccepted: {
            field.committed(text);
            focus = false;
        }
        onActiveFocusChanged: if (!activeFocus && text !== field.text)
            field.committed(text)
        Keys.onEscapePressed: event => {
            text = field.text;
            focus = false;
            event.accepted = true;
        }
    }

    Text {
        anchors {
            left: parent.left
            leftMargin: 9
            verticalCenter: parent.verticalCenter
        }
        visible: input.text === "" && !input.activeFocus
        text: field.placeholder
        color: Theme.withAlpha(Theme.subtext, 0.7)
        font.family: Theme.fontUi
        font.pixelSize: 12
    }
}
