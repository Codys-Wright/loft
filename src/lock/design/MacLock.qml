import QtQuick
import qs.services
import qs.components

// Loft's default lock / login design (macOS-style): date + big clock up
// top, an optional accessory (now playing) under it, and a frosted card
// with avatar, name and password pill in the lower middle.
//
// Host-agnostic on purpose: it imports only QtQuick plus Theme and the glass
// components, and talks to its host through the properties and signals
// below. The Quickshell lock (src/lock/) and the SDDM greeter (lock/sddm/)
// both instantiate it, so the lock screen and the login screen are the same
// design. Pack designs use a different contract (docs/THEME-FORMAT-LOCK.md).
// A FocusScope, so a host focusing the design lands in the password field.
FocusScope {
    id: root

    // ── Host → design ───────────────────────────────────────────────────
    property string userName: ""
    property string realName: ""
    // Avatar candidates (URLs), tried in order; initial letter otherwise.
    property var avatarSources: []
    property bool busy: false
    property bool capsLock: false
    // Show the card + input here (false on screens without keyboard focus).
    property bool showInput: true
    property string placeholder: "Enter Password"
    // Wallpaper image URL; "" = the theme gradient (the login screen).
    property string wallpaper: ""
    // Informational line under the pill (PAM prompts, greeter messages).
    property string info: ""
    // Optional extra under the clock, e.g. the lock's now-playing card.
    property Component accessory: null
    // Optional row at the bottom edge, e.g. the greeter's session + power.
    property Component footer: null
    // Greeter: the name becomes a button that cycles users.
    property bool canSwitchUser: false

    // ── Design → host ───────────────────────────────────────────────────
    signal submitted(string password)
    signal capsLockPressed
    signal switchUserClicked

    // The host reports a failed attempt: shake, clear, say why.
    function fail(message) {
        errorText.text = message || "Incorrect password";
        errorTimer.restart();
        pill.clear();
        shake.restart();
        pill.focusInput();
    }

    function focusInput() {
        pill.focusInput();
    }

    // Screens of very different sizes get the same proportions.
    readonly property real sizeScale: Math.max(0.6, Math.min(1.6, height / 1080))

    Backdrop {
        id: backdrop
        anchors.fill: parent
        image: root.wallpaper
    }

    // A light scrim keeps text legible over bright wallpapers.
    Rectangle {
        anchors.fill: parent
        color: Theme.withAlpha(Theme.bg, Theme.dark ? 0.18 : 0.08)
    }

    // Clicking anywhere returns focus to the password field.
    MouseArea {
        anchors.fill: parent
        onClicked: pill.focusInput()
    }

    LockClock {
        id: clock
        anchors {
            horizontalCenter: parent.horizontalCenter
            top: parent.top
            topMargin: root.height * 0.08
        }
        sizeScale: root.sizeScale
    }

    Loader {
        anchors {
            horizontalCenter: parent.horizontalCenter
            top: clock.bottom
            topMargin: 24 * root.sizeScale
        }
        width: 380 * root.sizeScale
        active: root.accessory !== null
        sourceComponent: root.accessory
    }

    Loader {
        anchors {
            horizontalCenter: parent.horizontalCenter
            bottom: parent.bottom
            bottomMargin: 28 * root.sizeScale
        }
        active: root.footer !== null && root.showInput
        sourceComponent: root.footer
    }

    Item {
        id: card
        width: 340 * root.sizeScale
        height: column.implicitHeight + 2 * column.anchors.margins
        anchors {
            horizontalCenter: parent.horizontalCenter
            bottom: parent.bottom
            bottomMargin: root.height * 0.14
        }
        visible: opacity > 0
        opacity: root.showInput ? 1 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: 200
            }
        }

        transform: Translate {
            id: offset
        }

        SequentialAnimation {
            id: shake
            NumberAnimation { target: offset; property: "x"; to: -16; duration: 50; easing.type: Easing.OutQuad }
            NumberAnimation { target: offset; property: "x"; to: 14; duration: 70; easing.type: Easing.InOutQuad }
            NumberAnimation { target: offset; property: "x"; to: -10; duration: 65; easing.type: Easing.InOutQuad }
            NumberAnimation { target: offset; property: "x"; to: 7; duration: 60; easing.type: Easing.InOutQuad }
            NumberAnimation { target: offset; property: "x"; to: -3; duration: 55; easing.type: Easing.InOutQuad }
            NumberAnimation { target: offset; property: "x"; to: 0; duration: 50; easing.type: Easing.OutQuad }
        }

        FrostedGlass {
            anchors.fill: parent
            backdrop: backdrop
            radius: Theme.radius * 2
        }

        Column {
            id: column
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: 24 * root.sizeScale
            }
            spacing: 14 * root.sizeScale

            Avatar {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 96 * root.sizeScale
                height: width
                sources: root.avatarSources
                name: root.realName || root.userName
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 6

                Text {
                    text: root.realName || root.userName
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 20 * root.sizeScale
                    font.weight: Font.DemiBold
                }

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: root.canSwitchUser
                    text: "󰅀"
                    size: 14 * root.sizeScale
                    color: Theme.subtext
                }

                TapHandler {
                    enabled: root.canSwitchUser
                    onTapped: root.switchUserClicked()
                }
            }

            PasswordPill {
                id: pill
                width: parent.width
                height: 40 * root.sizeScale
                backdrop: backdrop
                busy: root.busy
                placeholder: root.placeholder
                onSubmitted: password => root.submitted(password)
                onCapsLockPressed: root.capsLockPressed()
            }

            // Error (after a failed attempt), else caps lock, else host info.
            Text {
                id: errorText
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                visible: errorTimer.running
                color: Theme.urgent
                font.family: Theme.fontUi
                font.pixelSize: 13 * root.sizeScale
                font.weight: Font.Medium
                wrapMode: Text.WordWrap

                Timer {
                    id: errorTimer
                    interval: 4000
                }
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: !errorText.visible && root.capsLock
                spacing: 6

                Icon {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰪛"
                    size: 14 * root.sizeScale
                    color: Theme.warn
                }

                Text {
                    text: "Caps Lock is on"
                    color: Theme.warn
                    font.family: Theme.fontUi
                    font.pixelSize: 13 * root.sizeScale
                }
            }

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                visible: !errorText.visible && !root.capsLock && root.info !== ""
                text: root.info
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 13 * root.sizeScale
                wrapMode: Text.WordWrap
            }
        }
    }

    onShowInputChanged: if (showInput)
        pill.focusInput()
    Component.onCompleted: if (showInput)
        pill.focusInput()
}
