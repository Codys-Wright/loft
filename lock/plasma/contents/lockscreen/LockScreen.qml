import QtQuick
import org.kde.kscreenlocker as ScreenLocker

// Loft's lock design in Plasma's locker (docs/KWIN.md §4.3). kscreenlocker_greet
// loads this file once per screen, with these context properties:
//   authenticator            PAM (PamAuthenticators): startAuthenticating(),
//                            respond(), stopAuthenticating(), busy, prompts,
//                            failed / succeeded
//   kscreenlocker_userName   the login name
//   kscreenlocker_userImage  the user's picture (path, may be "")
//   config, wallpaper        Plasma's lock-screen settings and wallpaper item
//
// This file only holds the host side (authentication, messages, which screen
// takes input) and imports nothing beyond QtQuick and the greeter's own
// module, so it always compiles. The design (LoftLock.qml: src/lock/design,
// shared by nix/lock.nix) is loaded into it. If that fails to load, a plain
// password field takes its place, so the session can always be unlocked; if
// this file itself failed, the greeter would fall back to its built-in one.
Item {
    id: root

    // Set by the greeter (QQmlProperty writes; they must exist).
    property bool viewVisible: false
    property bool locked: false

    implicitWidth: 800
    implicitHeight: 600

    // ── Host state the design reads ──────────────────────────────────────
    readonly property string userName: typeof kscreenlocker_userName === "string" ? kscreenlocker_userName : ""
    readonly property string userImage: typeof kscreenlocker_userImage === "string" && kscreenlocker_userImage !== "" ? "file://" + kscreenlocker_userImage.split("/").map(encodeURIComponent).join("/") : ""

    // A password typed while PAM is still in its failure delay waits here.
    property string pendingPassword: ""
    // A password was sent and PAM hasn't answered yet. (authenticator.busy
    // is also true while PAM merely waits for the password, so it can't be
    // used: it would disable the field before anything was typed.)
    property bool submitting: false
    readonly property bool busy: submitting
    // PAM's info / error lines, the latest first.
    property string info: ""
    // Unlocked without a prompt (passwordless account): any key or click quits.
    property bool readyToUnlock: false

    // The card shows on the screen that has keyboard focus (as Loft's own
    // lock). It must fail open: if the greeter can't tell which screen is
    // active, or none of its windows is, every screen shows it.
    readonly property bool showInput: screenMonitor.active || root.Window.active || Qt.application.state !== Qt.ApplicationActive || Qt.application.screens.length <= 1

    signal failed(string message)

    function tryUnlock(password) {
        if (readyToUnlock) {
            Qt.quit();
            return;
        }
        info = "";
        submitting = true;
        answerTimeout.restart();
        if (authenticator.inPasswordDelay)
            pendingPassword = password;
        else
            authenticator.respond(password);
    }

    function showMessage(message) {
        if (message)
            info = message;
    }

    Connections {
        target: authenticator

        function onFailed(kind) {
            // Non-interactive authenticators (fingerprint) fail on their own;
            // only a rejected password shakes the card.
            if (kind != 0)
                return;
            root.pendingPassword = "";
            root.submitting = false;
            root.failed("Incorrect password");
            authenticator.startAuthenticating();
        }

        function onSucceeded() {
            // Stops pending authenticators (timeouts etc.).
            authenticator.stopAuthenticating();
            if (authenticator.hadPrompt) {
                Qt.quit();
            } else {
                root.readyToUnlock = true;
                root.info = "Press Return to unlock";
            }
        }

        function onInfoMessageChanged() {
            root.showMessage(authenticator.infoMessage);
        }

        function onErrorMessageChanged() {
            root.showMessage(authenticator.errorMessage);
        }

        function onPromptChanged() {
            root.showMessage(authenticator.prompt);
        }

        function onNoninteractiveError(kind, which) {
            root.showMessage(which.errorMessage);
        }

        function onInPasswordDelayChanged() {
            if (!authenticator.inPasswordDelay && root.pendingPassword !== "") {
                authenticator.respond(root.pendingPassword);
                root.pendingPassword = "";
            }
        }
    }

    // PAM conversations end (timeouts, a failed attempt); keep one running
    // while the lock is up, as Plasma's own lock screen does.
    // PAM never answered (a stuck module): give the field back.
    Timer {
        id: answerTimeout
        interval: 15000
        onTriggered: {
            root.submitting = false;
            root.pendingPassword = "";
        }
    }

    Timer {
        interval: 1000
        running: !authenticator.unlocked && !root.readyToUnlock
        repeat: true
        triggeredOnStart: true
        onTriggered: authenticator.startAuthenticating()
    }

    ScreenLocker.ActiveScreenMonitor {
        id: screenMonitor
        lockscreenState: ScreenLocker.LockscreenState
        window: root.Window.window
    }

    Keys.onPressed: event => {
        if (root.readyToUnlock && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
            Qt.quit();
            event.accepted = true;
        }
    }

    // ── The design ───────────────────────────────────────────────────────
    Loader {
        id: design
        anchors.fill: parent
        focus: true
        asynchronous: false
        onStatusChanged: {
            if (status === Loader.Error) {
                console.warn("Loft lock screen: the design failed to load; using the plain fallback");
                sourceComponent = plain;
            }
        }
        onLoaded: item.forceActiveFocus()
        Component.onCompleted: setSource(Qt.resolvedUrl("LoftLock.qml"), {
            host: root
        })
    }

    // The last resort: no shared design, no Theme, just a way in.
    Component {
        id: plain

        FocusScope {
            focus: true

            Rectangle {
                anchors.fill: parent
                color: "#1a1b26"

                Connections {
                    target: root
                    function onFailed(message) {
                        field.text = "";
                        statusLine.text = message;
                    }
                }

                Column {
                    anchors.centerIn: parent
                    spacing: 12
                    visible: root.showInput

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.userName
                        color: "#c0caf5"
                        font.pixelSize: 22
                    }

                    Rectangle {
                        width: 320
                        height: 40
                        radius: 20
                        color: "#24283b"
                        border.color: field.activeFocus ? "#7aa2f7" : "#414868"

                        TextInput {
                            id: field
                            anchors.fill: parent
                            anchors.leftMargin: 18
                            anchors.rightMargin: 18
                            verticalAlignment: TextInput.AlignVCenter
                            echoMode: TextInput.Password
                            color: "#c0caf5"
                            font.pixelSize: 15
                            focus: true
                            enabled: !root.busy
                            onAccepted: root.tryUnlock(text)
                        }
                    }

                    Text {
                        id: statusLine
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: root.info
                        color: "#a9b1d6"
                        font.pixelSize: 13
                    }
                }
            }

            Component.onCompleted: field.forceActiveFocus()
        }
    }
}
