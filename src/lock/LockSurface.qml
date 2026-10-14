import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.services
import qs.controlcenter
import qs.lock.design

// One lock surface (WlSessionLock makes one per screen). Loads the active
// pack's lock design if there is one, else the built-in MacLock.
//
// The root properties below are the pack contract (docs/THEME-FORMAT-LOCK.md):
// a design loaded from a file resolves unqualified names through this
// object, so `lock`, `sddm`, `userModel`, `config`, … work in it exactly as
// SDDM's context properties do in a greeter.
WlSessionLockSurface {
    id: surface

    required property var host

    color: Theme.bg

    readonly property bool focused: design.Window.active
    onFocusedChanged: if (focused)
        host.focusedScreen = screen?.name ?? ""

    readonly property bool showInput: host.focusedScreen === "" || host.focusedScreen === (screen?.name ?? "")

    // ── studio-native contract ──────────────────────────────────────────
    readonly property QtObject lock: QtObject {
        readonly property string userName: surface.host.userName
        readonly property string realName: surface.host.realName || surface.host.userName
        readonly property var avatarSources: surface.avatarSources
        readonly property bool busy: surface.host.busy
        readonly property string info: surface.host.info
        readonly property bool capsLock: surface.host.capsLock
        readonly property bool showInput: surface.showInput
        readonly property var screen: surface.screen
        readonly property bool isGreeter: false
        readonly property var theme: Theme
        // The desktop's wallpaper image (the user's choice, else the theme
        // pack's), as a URL; "" = the theme gradient.
        readonly property string wallpaper: {
            const p = Settings.wallpaper.path || Theme.wallpaperImage;
            if (!p)
                return "";
            const abs = p.startsWith("~/") ? Quickshell.env("HOME") + p.slice(1) : p;
            return abs.startsWith("/") ? "file://" + abs : abs;
        }

        signal failed(string message)

        function tryUnlock(password) {
            surface.host.tryUnlock(password);
        }
    }

    // ── SDDM-compatible subset (qylock-style designs) ───────────────────
    readonly property QtObject sddm: QtObject {
        readonly property string hostName: ""
        readonly property bool canPowerOff: false
        readonly property bool canReboot: false
        readonly property bool canSuspend: false
        readonly property bool canHibernate: false
        readonly property bool canHybridSleep: false

        signal loginFailed
        signal loginSucceeded
        signal informationMessage(string message)

        // A lock only ever authenticates the user who owns the session.
        function login(user, password, session) {
            surface.host.tryUnlock(password);
        }
        // Power actions belong to the session, not the lock screen.
        function powerOff() {}
        function reboot() {}
        function suspend() {}
        function hibernate() {}
        function hybridSleep() {}
    }

    readonly property ListModel userModel: ListModel {
        readonly property string lastUser: surface.host.userName
        readonly property int lastIndex: 0
        readonly property int disableAvatarsThreshold: 7
    }

    readonly property ListModel sessionModel: ListModel {
        readonly property int lastIndex: 0
    }

    readonly property QtObject keyboard: QtObject {
        readonly property bool capsLock: surface.host.capsLock
        property bool numLock: false
    }

    // The pack's lock/theme.conf as a flat key → value map (SDDM's `config`).
    property var config: ({})

    readonly property string packLockDir: host.packLockDir

    readonly property var avatarSources: [
        "file://" + (Quickshell.env("HOME") ?? "") + "/.face",
        "file:///var/lib/AccountsService/icons/" + host.userName
    ]

    Component.onCompleted: {
        userModel.append({
            name: host.userName,
            realName: host.realName || host.userName,
            homeDir: Quickshell.env("HOME") ?? "",
            icon: avatarSources[0],
            needsPassword: true
        });
        sessionModel.append({
            name: "Current session",
            file: "",
            exec: "",
            comment: ""
        });
    }

    Connections {
        target: surface.host

        function onFailed(message) {
            surface.lock.failed(message);
            surface.sddm.loginFailed();
            surface.builtinDesign()?.fail(message);
        }
    }

    function builtinDesign() {
        return design.sourceComponent === builtin ? design.item : null;
    }

    FileView {
        path: surface.host.hasPackDesign ? surface.packLockDir + "/theme.conf" : ""
        printErrors: false
        // Read synchronously so `config` is filled before the design loads.
        blockLoading: true
        onLoaded: {
            const out = {};
            for (const line of text().split("\n")) {
                const t = line.trim();
                const eq = t.indexOf("=");
                if (eq > 0 && !t.startsWith("#") && !t.startsWith("["))
                    out[t.slice(0, eq).trim()] = t.slice(eq + 1).trim();
            }
            surface.config = out;
        }
    }

    Component {
        id: builtin

        MacLock {
            userName: surface.host.userName
            realName: surface.host.realName
            avatarSources: surface.avatarSources
            busy: surface.host.busy
            info: surface.host.info
            capsLock: surface.host.capsLock
            showInput: surface.showInput
            wallpaper: surface.lock.wallpaper
            accessory: nowPlaying
            onSubmitted: password => surface.host.tryUnlock(password)
            onCapsLockPressed: surface.host.capsLockPressed()
        }
    }

    Component {
        id: nowPlaying

        MediaCard {}
    }

    // The pack's design if it compiles, else the built-in one: a broken pack
    // must never leave the screen locked without a way in.
    readonly property Component pack: {
        if (!host.hasPackDesign)
            return null;
        const c = Qt.createComponent("file://" + host.packDesign, Component.PreferSynchronous);
        if (c.status === Component.Ready)
            return c;
        console.warn(`lock: pack design ${host.packDesign} failed to load (${c.errorString().trim()}); using the built-in one`);
        return null;
    }

    Loader {
        id: design
        anchors.fill: parent
        focus: true
        sourceComponent: surface.pack ?? builtin
        onLoaded: item.forceActiveFocus()
    }
}
