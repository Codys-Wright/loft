import QtQuick
import qs.services
import qs.components

// The password field: a frosted pill with masked input, a show/hide toggle
// and a submit arrow (a spinner while authenticating). Return submits,
// Escape clears.
FrostedGlass {
    id: root

    property string placeholder: "Enter Password"
    property bool busy: false
    readonly property alias text: input.text

    signal submitted(string password)
    signal capsLockPressed

    function clear() {
        input.text = "";
    }

    function focusInput() {
        input.forceActiveFocus();
    }

    function submit() {
        if (input.text.length > 0 && !root.busy)
            root.submitted(input.text);
    }

    radius: height / 2
    strength: input.activeFocus ? 1.5 : 1.2
    showHighlight: false

    TextInput {
        id: input
        anchors {
            left: parent.left
            right: reveal.left
            verticalCenter: parent.verticalCenter
            leftMargin: 18
            rightMargin: 6
        }
        focus: true
        enabled: !root.busy
        echoMode: reveal.shown ? TextInput.Normal : TextInput.Password
        passwordCharacter: "●"
        color: Theme.text
        selectionColor: Theme.withAlpha(Theme.accent, 0.5)
        selectedTextColor: Theme.text
        font.family: Theme.fontUi
        font.pixelSize: 15
        font.letterSpacing: reveal.shown ? 0 : 2
        clip: true
        cursorDelegate: Rectangle {
            width: 2
            color: Theme.accent
            visible: input.activeFocus

            SequentialAnimation on opacity {
                loops: Animation.Infinite
                running: input.activeFocus
                NumberAnimation { to: 0; duration: 500 }
                NumberAnimation { to: 1; duration: 500 }
            }
        }

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.submit();
                event.accepted = true;
            } else if (event.key === Qt.Key_Escape) {
                root.clear();
                event.accepted = true;
            } else if (event.key === Qt.Key_CapsLock) {
                root.capsLockPressed();
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text.length === 0
            text: root.placeholder
            color: Theme.withAlpha(Theme.subtext, 0.8)
            font.family: Theme.fontUi
            font.pixelSize: input.font.pixelSize
        }
    }

    // Show / hide the typed password.
    Icon {
        id: reveal
        property bool shown: false
        anchors {
            right: action.left
            verticalCenter: parent.verticalCenter
            rightMargin: 8
        }
        visible: input.text.length > 0
        text: shown ? "󰈉" : "󰈈"
        size: 17
        color: Theme.subtext

        MouseArea {
            anchors.fill: parent
            anchors.margins: -6
            cursorShape: Qt.PointingHandCursor
            onClicked: {
                reveal.shown = !reveal.shown;
                input.forceActiveFocus();
            }
        }
    }

    // Submit arrow; turns into a spinner while authenticating.
    Rectangle {
        id: action
        anchors {
            right: parent.right
            verticalCenter: parent.verticalCenter
            rightMargin: 5
        }
        width: root.height - 10
        height: width
        radius: width / 2
        color: input.text.length > 0 || root.busy ? Theme.accent : Theme.withAlpha(Theme.text, 0.12)

        Behavior on color {
            ColorAnimation {
                duration: 180
            }
        }

        Icon {
            anchors.centerIn: parent
            visible: !root.busy
            text: "󰁔"
            size: 16
            color: input.text.length > 0 ? Theme.bg : Theme.subtext
        }

        Icon {
            anchors.centerIn: parent
            visible: root.busy
            text: "󰑓"
            size: 16
            color: Theme.bg

            RotationAnimation on rotation {
                running: root.busy
                loops: Animation.Infinite
                from: 0
                to: 360
                duration: 900
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.submit()
        }
    }
}
