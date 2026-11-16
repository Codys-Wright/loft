import QtQuick
import QtCore
import "services"
import "design"

// Loft's lock design (src/lock/design/MacLock.qml, copied in by nix/lock.nix)
// under Plasma's locker. `host` is LockScreen.qml: it owns authentication;
// this file only colors and feeds the design.
//
// Colors and wallpaper come from the user's rendered Loft theme, read fresh at
// every lock: <XDG_STATE_HOME>/loft/current/{theme.json,wallpapers.json}.
// Reading files from QML needs QML_XHR_ALLOW_FILE_READ=1 in the greeter's
// environment (set next to PLASMA_DEFAULT_SHELL, see nix/modules/home.nix);
// without it the bundled default theme and the theme gradient are used.
FocusScope {
    id: root

    required property Item host

    readonly property string stateDir: {
        const s = String(StandardPaths.writableLocation(StandardPaths.GenericStateLocation) ?? "");
        const home = String(StandardPaths.writableLocation(StandardPaths.HomeLocation) ?? "");
        return (s !== "" ? s : home + "/.local/state").replace(/^file:\/\//, "") + "/loft";
    }

    property string realName: ""
    property string homeDir: ""
    property string wallpaper: ""

    // Caps Lock from Plasma's key-state helper, created at runtime so a
    // missing module can never take the design down with it.
    property QtObject capsState: null
    readonly property bool capsLock: capsState?.locked ?? false

    // Same order as Loft's own lock: ~/.face, AccountsService, then the
    // picture the greeter found.
    readonly property var avatarSources: {
        const s = [];
        if (homeDir !== "")
            s.push("file://" + homeDir + "/.face");
        if (host.userName !== "")
            s.push("file:///var/lib/AccountsService/icons/" + host.userName);
        if (host.userImage !== "")
            s.push(host.userImage);
        return s;
    }

    function read(path, done) {
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = () => {
            if (xhr.readyState === XMLHttpRequest.DONE)
                done(xhr.responseText || "");
        };
        try {
            xhr.open("GET", "file://" + path);
            xhr.send();
        } catch (e) {
            done("");
        }
    }

    // The desktop's wallpaper for this screen, as `loft greeter sync` picks it
    // (cli/loft/greeter.py): this display's, else the arrangement's, else the
    // theme's default. Displays are keyed "<make> <model> <serial>".
    function pickWallpaper(json) {
        let w = {};
        try {
            w = JSON.parse(json);
        } catch (e) {
            return "";
        }
        const arr = w.arrangement ?? {};
        const scr = root.Window.window?.screen;
        const id = scr ? [scr.manufacturer, scr.model, scr.serialNumber || "Unknown"].join(" ") : "";
        const cands = [(arr.displays ?? {})[id], arr.wallpaper, w["default"]];
        for (const c of cands)
            if (typeof c === "string" && c !== "")
                return "file://" + c.split("/").map(encodeURIComponent).join("/");
        return "";
    }

    Component.onCompleted: {
        Theme.load([root.stateDir + "/current/theme.json", Qt.resolvedUrl("default/theme.json")]);
        read(root.stateDir + "/current/wallpapers.json", text => root.wallpaper = root.pickWallpaper(text));
        // The GECOS name, as Loft's lock shows it (the greeter only knows the login).
        read("/etc/passwd", text => {
            for (const line of text.split("\n")) {
                const f = line.split(":");
                if (f[0] === root.host.userName && f.length >= 6) {
                    root.realName = (f[4] ?? "").split(",")[0];
                    root.homeDir = f[5];
                    return;
                }
            }
        });
        try {
            capsState = Qt.createQmlObject("import org.kde.plasma.private.keyboardindicator as K; K.KeyState { key: Qt.Key_CapsLock }", root, "capsLock");
        } catch (e) {
            console.warn(`Loft lock screen: no Caps Lock indicator: ${e}`);
        }
        lock.forceActiveFocus();
    }

    Connections {
        target: root.host
        function onFailed(message) {
            lock.fail(message);
        }
    }

    MacLock {
        id: lock
        anchors.fill: parent
        focus: true
        userName: root.host.userName
        realName: root.realName
        avatarSources: root.avatarSources
        wallpaper: root.wallpaper
        busy: root.host.busy
        info: root.host.info
        capsLock: root.capsLock
        showInput: root.host.showInput
        onSubmitted: password => root.host.tryUnlock(password)
    }

    // Unlocked without a prompt (passwordless account): Return or a click.
    Item {
        id: unlockNow
        anchors.fill: parent
        visible: root.host.readyToUnlock
        onVisibleChanged: if (visible)
            forceActiveFocus()
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.host.tryUnlock("");
                event.accepted = true;
            }
        }
        TapHandler {
            onTapped: root.host.tryUnlock("")
        }
    }
}
