import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.components
import qs.services

// Cleaning Mode's surfaces (state: services/Cleaning.qml). An
// ext-session-lock rather than layer surfaces: while a session is locked
// niri sends every key and click to the lock surfaces and runs only binds
// marked allow-when-locked (+ quit / VT switch / suspend / monitor power),
// so wiping the keyboard can't type into apps or fire shortcuts. An
// exclusive-keyboard layer surface would still let niri run every bind.
//
// Leave: hold Esc (or the key Esc becomes when held, e.g. xremap's
// Esc-hold → Alt_R = ISO_Level3_Shift), the timer, or `cleaning stop`.
Scope {
    id: root

    readonly property int holdMs: Math.max(1, EverydayConfig.cleaning.holdSeconds) * 1000
    property real now: Date.now()
    readonly property real remaining: Cleaning.endsAt > 0 ? Math.max(0, Cleaning.endsAt - now) : 0

    // If the shell dies mid-clean, niri keeps the screen locked with nothing
    // on it. This marker lets the restarted shell hand over to the real lock
    // screen (password), so there's always a way back.
    readonly property string marker: `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/loft-cleaning.${Quickshell.env("WAYLAND_DISPLAY") || "wayland"}`

    Connections {
        target: Cleaning
        function onActiveChanged() {
            if (Cleaning.active) {
                markerFile.setText(`${Date.now()}\n`);
                root.now = Date.now();
            } else {
                Quickshell.execDetached(["rm", "-f", root.marker]);
            }
        }
    }

    FileView {
        id: markerFile
        path: root.marker
        printErrors: false
        // Present at startup without an active clean: the last shell died.
        onLoaded: if (!Cleaning.active) {
            Quickshell.execDetached(["rm", "-f", root.marker]);
            LockState.requestLock();
        }
    }

    Timer {
        running: Cleaning.active
        interval: 250
        repeat: true
        onTriggered: {
            root.now = Date.now();
            if (Cleaning.endsAt > 0 && root.now >= Cleaning.endsAt)
                Cleaning.stop();
        }
    }

    // Hold-to-exit: the progress fills while the key is down, then ends it.
    property bool holding: false
    NumberAnimation {
        id: fill
        target: Cleaning
        property: "holdProgress"
        to: 1
        duration: root.holdMs * (1 - Cleaning.holdProgress)
        onFinished: if (root.holding && Cleaning.holdProgress >= 1)
            Cleaning.stop()
    }
    NumberAnimation {
        id: drain
        target: Cleaning
        property: "holdProgress"
        to: 0
        duration: 250
        easing.type: Easing.OutCubic
    }

    function isExitKey(key) {
        return key === Qt.Key_Escape || key === Qt.Key_AltGr;
    }

    function press(event) {
        event.accepted = true;
        if (!isExitKey(event.key) || event.isAutoRepeat || holding)
            return;
        holding = true;
        drain.stop();
        fill.duration = holdMs * (1 - Cleaning.holdProgress);
        fill.start();
    }

    function release(event) {
        event.accepted = true;
        if (!isExitKey(event.key) || event.isAutoRepeat)
            return;
        holding = false;
        fill.stop();
        drain.start();
    }

    WlSessionLock {
        locked: Cleaning.active

        WlSessionLockSurface {
            id: surface
            color: "#000000"

            Item {
                id: keys
                anchors.fill: parent
                focus: true
                Keys.onPressed: event => root.press(event)
                Keys.onReleased: event => root.release(event)
                Component.onCompleted: forceActiveFocus()

                // Swallow every click and scroll.
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                    hoverEnabled: true
                    onWheel: wheel => wheel.accepted = true
                }
            }

            ColumnLayout {
                anchors.centerIn: parent
                spacing: 18
                opacity: 0.92

                // The timer ring with the seconds left (or a broom without one).
                Item {
                    Layout.alignment: Qt.AlignHCenter
                    implicitWidth: 132
                    implicitHeight: 132

                    ProgressRing {
                        anchors.fill: parent
                        visible: Cleaning.endsAt > 0
                        lineWidth: 5
                        color: "#ffffff"
                        trackColor: Qt.rgba(1, 1, 1, 0.12)
                        value: Cleaning.endsAt > 0 ? root.remaining / Math.max(1, Cleaning.endsAt - Cleaning.startedAt) : 0
                    }

                    Text {
                        anchors.centerIn: parent
                        text: Cleaning.endsAt > 0 ? String(Math.ceil(root.remaining / 1000)) : "󰃢"
                        color: "#ffffff"
                        font.family: Cleaning.endsAt > 0 ? Theme.fontUi : Theme.fontIcons
                        font.pixelSize: Cleaning.endsAt > 0 ? 44 : 56
                        font.weight: Font.Light
                        font.features: ({ tnum: 1 })
                    }
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Cleaning"
                    color: "#ffffff"
                    font.family: Theme.fontUi
                    font.pixelSize: 26
                    font.weight: Font.DemiBold
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    horizontalAlignment: Text.AlignHCenter
                    text: "Keyboard, mouse and trackpad are locked."
                    color: Qt.rgba(1, 1, 1, 0.6)
                    font.family: Theme.fontUi
                    font.pixelSize: 14
                }

                // "Hold esc for 3 s to exit" with the hold progress under the keycap.
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: 10
                    spacing: 10

                    Text {
                        text: "Hold"
                        color: Qt.rgba(1, 1, 1, 0.6)
                        font.family: Theme.fontUi
                        font.pixelSize: 14
                    }

                    Rectangle {
                        implicitWidth: 52
                        implicitHeight: 28
                        radius: 7
                        color: Qt.rgba(1, 1, 1, 0.1)
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.25)
                        clip: true

                        Rectangle {
                            anchors {
                                left: parent.left
                                top: parent.top
                                bottom: parent.bottom
                            }
                            width: parent.width * Cleaning.holdProgress
                            color: Qt.rgba(1, 1, 1, 0.35)
                        }

                        Text {
                            anchors.centerIn: parent
                            text: "esc"
                            color: "#ffffff"
                            font.family: Theme.fontUi
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                        }
                    }

                    Text {
                        text: `for ${EverydayConfig.cleaning.holdSeconds} s to exit`
                        color: Qt.rgba(1, 1, 1, 0.6)
                        font.family: Theme.fontUi
                        font.pixelSize: 14
                    }
                }
            }
        }
    }
}
