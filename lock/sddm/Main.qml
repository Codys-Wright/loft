import QtQuick
import QtQml.Models
import "services"
import "components"
import "design"

// studio's SDDM theme: a static loader. It shows the greeter pack's own
// design (<packDir>/lock/Main.qml) when there is one, else the built-in
// MacLock — the very same design the Quickshell lock screen uses (shared
// from src/lock/design by nix/lock.nix), colored by the pack's theme.json.
// Switching the login screen's look never changes SDDM's configured theme.
Item {
    id: root

    width: 1920
    height: 1080

    // A directory holding theme.json (+ optionally lock/Main.qml); normally
    // a symlink to a pack under /var/lib/studio-linux/themes (PLAN §4.5).
    readonly property string packDir: config.packDir || "/var/lib/studio-linux/greeter"

    // SDDM makes one view per screen; only the primary one takes input.
    readonly property bool primary: typeof primaryScreen === "undefined" || primaryScreen

    property int userIndex: Math.max(0, userModel.lastIndex)
    property int sessionIndex: Math.max(0, sessionModel.lastIndex)
    property bool busy: false
    property string info: ""

    readonly property var currentUser: users.count > userIndex ? users.objectAt(userIndex) : null
    readonly property var currentSession: sessions.count > sessionIndex ? sessions.objectAt(sessionIndex) : null

    function login(password) {
        if (!currentUser || busy)
            return;
        busy = true;
        info = "";
        sddm.login(currentUser.name, password, sessionIndex);
    }

    // SDDM's models are only readable through delegates.
    Instantiator {
        id: users
        model: userModel
        delegate: QtObject {
            required property string name
            required property string realName
            required property var icon
        }
    }

    Instantiator {
        id: sessions
        model: sessionModel
        delegate: QtObject {
            required property string name
        }
    }

    // ── studio-native contract for pack designs (docs/THEME-FORMAT-LOCK.md);
    // SDDM's own sddm/userModel/sessionModel/config/keyboard are context
    // properties, visible to a loaded design as they are.
    readonly property QtObject lock: QtObject {
        readonly property string userName: root.currentUser?.name ?? ""
        readonly property string realName: root.currentUser?.realName || (root.currentUser?.name ?? "")
        // SDDM substitutes its generic face for users without a picture; the
        // design's initial-letter disc reads better than that.
        readonly property var avatarSources: {
            const icon = String(root.currentUser?.icon ?? "");
            return icon !== "" && !icon.endsWith("faces/.face.icon") ? [icon] : [];
        }
        readonly property bool busy: root.busy
        readonly property string info: root.info
        readonly property bool capsLock: keyboard.capsLock
        readonly property bool showInput: root.primary
        readonly property var screen: null
        readonly property bool isGreeter: true
        readonly property var theme: Theme

        signal failed(string message)

        function tryUnlock(password) {
            root.login(password);
        }
    }

    Connections {
        target: sddm

        function onLoginFailed() {
            root.busy = false;
            root.lock.failed("Incorrect password");
            if (design.sourceComponent === builtin && design.item)
                design.item.fail("Incorrect password");
        }

        function onInformationMessage(message) {
            root.info = message;
        }
    }

    Component.onCompleted: {
        Theme.load([root.packDir + "/theme.json", Qt.resolvedUrl("default/theme.json")]);
        mergePackConfig();
    }

    // A pack design reads its own lock/theme.conf through `config`, as it
    // does under the lock screen. SDDM's `config` holds this theme's
    // theme.conf, so the pack's keys are merged into it (it's a property
    // map; bindings in the design update when keys arrive).
    function mergePackConfig() {
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE || !xhr.responseText)
                return;
            for (const line of xhr.responseText.split("\n")) {
                const t = line.trim();
                const eq = t.indexOf("=");
                const key = t.slice(0, eq).trim();
                if (eq > 0 && !t.startsWith("#") && !t.startsWith("[") && key !== "packDir")
                    config[key] = t.slice(eq + 1).trim();
            }
        };
        try {
            xhr.open("GET", "file://" + root.packDir + "/lock/theme.conf");
            xhr.send();
        } catch (e) {}
    }

    Component {
        id: builtin

        MacLock {
            userName: root.currentUser?.name ?? ""
            realName: root.currentUser?.realName ?? ""
            avatarSources: root.lock.avatarSources
            busy: root.busy
            info: root.info
            capsLock: keyboard.capsLock
            showInput: root.primary
            canSwitchUser: users.count > 1
            footer: footerRow
            onSubmitted: password => root.login(password)
            onSwitchUserClicked: root.userIndex = (root.userIndex + 1) % users.count
        }
    }

    // Session picker + power actions, macOS login-window style.
    Component {
        id: footerRow

        Row {
            spacing: 18

            GlassSurface {
                anchors.verticalCenter: parent.verticalCenter
                width: sessionLabel.implicitWidth + 52
                height: 34
                radius: height / 2
                showHighlight: false
                visible: sessions.count > 1

                Row {
                    anchors.centerIn: parent
                    spacing: 8

                    Icon {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "󰍹"
                        size: 14
                    }

                    Text {
                        id: sessionLabel
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.currentSession?.name ?? ""
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.sessionIndex = (root.sessionIndex + 1) % sessions.count
                }
            }

            Repeater {
                model: [
                    { icon: "󰒲", label: "Sleep", show: sddm.canSuspend, act: () => sddm.suspend() },
                    { icon: "󰜉", label: "Restart", show: sddm.canReboot, act: () => sddm.reboot() },
                    { icon: "󰐥", label: "Shut Down", show: sddm.canPowerOff, act: () => sddm.powerOff() }
                ]

                delegate: Column {
                    required property var modelData
                    visible: modelData.show
                    spacing: 6

                    GlassSurface {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 40
                        height: 40
                        radius: 20
                        showHighlight: false
                        strength: hover.hovered ? 1.6 : 1.0

                        Icon {
                            anchors.centerIn: parent
                            text: modelData.icon
                            size: 17
                        }

                        HoverHandler {
                            id: hover
                            cursorShape: Qt.PointingHandCursor
                        }

                        TapHandler {
                            onTapped: modelData.act()
                        }
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: modelData.label
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                    }
                }
            }
        }
    }

    // The pack's design if it compiles, else the built-in one: a missing or
    // broken pack must never leave the login screen without a way in.
    readonly property Component pack: {
        const c = Qt.createComponent("file://" + root.packDir + "/lock/Main.qml", Component.PreferSynchronous);
        return c.status === Component.Ready ? c : null;
    }

    Loader {
        id: design
        anchors.fill: parent
        focus: true
        sourceComponent: root.pack ?? builtin
        onLoaded: item.forceActiveFocus()
    }
}
