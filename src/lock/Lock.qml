import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam
import qs.services

// The lock screen: an ext-session-lock (WlSessionLock) with one surface per
// screen, authenticated through PAM. Locking is driven over IPC so niri
// binds and swayidle can reach it:
//
//   qs ipc call lock lock                       (Mod+Ctrl+Q, see niri/shell-binds.kdl.in)
//   swayidle -w timeout 300 '<ipc> lock lock' before-sleep '<ipc> lock lock'
//
// Each surface shows the active theme pack's lock design (<pack>/lock/Main.qml)
// when it has one, else the built-in MacLock (docs/THEME-FORMAT-LOCK.md).
Scope {
    id: root

    readonly property string userName: Quickshell.env("USER") ?? ""
    property string realName: ""

    // The PAM service. "login" exists on every distro; a dedicated
    // `security.pam.services.studio-lock` can be selected with STUDIO_LOCK_PAM.
    readonly property string pamService: Quickshell.env("STUDIO_LOCK_PAM") || "login"

    // Only for automated tests of the dev session; never set in a real one.
    readonly property bool devMode: Quickshell.env("STUDIO_DEV") === "1"

    property bool busy: false
    property string info: ""
    property bool capsLock: false
    // Output name of the surface holding keyboard focus: the password field
    // shows there only ("" until one reports focus → show everywhere).
    property string focusedScreen: ""

    // The active pack's design, checked again at every lock so switching
    // themes switches lock designs without a restart.
    // The rendered theme's manifest names the pack's design (absolute path):
    // lock: { format: "studio" | "qylock", path } — see docs/THEME-FORMAT*.md.
    readonly property string themeDir: Theme.file.substring(0, Theme.file.lastIndexOf("/"))
    property string packLockDir: ""
    property string packFormat: ""
    // qylock designs are SDDM themes; their entry is Main.qml by convention.
    // One that needs SDDM modules we don't provide fails to compile and the
    // built-in design is used instead.
    readonly property string packDesign: packLockDir !== "" ? packLockDir + "/Main.qml" : ""
    property bool hasPackDesign: false

    function readManifest() {
        let lock = null;
        try {
            lock = JSON.parse(manifestView.text()).lock ?? null;
        } catch (e) {}
        packLockDir = lock?.path ?? "";
        packFormat = lock?.format ?? "";
    }

    // Present while locked. If the shell dies holding the lock, the
    // compositor keeps the screen locked with nothing on it; the restarted
    // shell sees this file and locks again, so the user gets a way back in.
    // Per Wayland display, so nested dev sessions don't lock each other.
    readonly property string marker: `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/studio-lock.${Quickshell.env("WAYLAND_DISPLAY") || "wayland"}.locked`

    signal failed(string message)

    function lock() {
        if (sessionLock.locked)
            return;
        // The compositor may have ended a lock behind our back (e.g. it
        // refused it); re-arm so the change below is a real edge.
        state.locked = false;
        info = "";
        busy = false;
        focusedScreen = "";
        manifestView.reload();
        readManifest();
        packCheck.reload();
        refreshCapsLock();
        state.locked = true;
        markerFile.setText(`${Date.now()}\n`); // changes every time: FileView skips identical writes
    }

    function unlock() {
        busy = false;
        pending = null;
        state.locked = false;
        Quickshell.execDetached(["rm", "-f", marker]);
    }

    // The single entry point for every design: run one PAM conversation
    // with this password.
    function tryUnlock(password) {
        if (!sessionLock.locked || pam.active)
            return;
        pending = password;
        busy = true;
        info = "";
        if (!pam.start()) {
            busy = false;
            pending = null;
            failed("Authentication is unavailable");
        }
    }

    // Caps lock isn't exposed by Qt; the keyboard LEDs in sysfs are.
    function refreshCapsLock() {
        capsProbe.running = true;
    }

    property var pending: null

    // Survives config reloads: a reload must never drop a held lock (the
    // new WlSessionLock takes the old one over when it starts out locked).
    PersistentProperties {
        id: state
        reloadableId: "studio-lock"
        property bool locked: false
    }

    WlSessionLock {
        id: sessionLock
        locked: state.locked

        LockSurface {
            host: root
        }
    }

    // Lock hook for other modules (services/LockState.qml). Follows the
    // lock request: WlSessionLock.locked doesn't notify when it's released.
    Binding {
        target: LockState
        property: "locked"
        value: state.locked
    }

    PamContext {
        id: pam
        config: root.pamService
        user: root.userName

        onPamMessage: {
            if (responseRequired) {
                if (root.pending !== null) {
                    respond(root.pending);
                    root.pending = null;
                } else {
                    // A second prompt (OTP, new password, …) has no UI yet.
                    abort();
                    root.busy = false;
                    root.failed(message || "Additional authentication is not supported");
                }
            } else if (message !== "") {
                root.info = message;
            }
        }

        onCompleted: result => {
            root.busy = false;
            root.pending = null;
            if (result === PamResult.Success)
                root.unlock();
            else
                root.failed(result === PamResult.MaxTries ? "Too many attempts" : "Incorrect password");
        }

        onError: error => {
            root.busy = false;
            root.pending = null;
            root.failed("Authentication error: " + PamError.toString(error));
        }
    }

    FileView {
        id: markerFile
        path: root.marker
        printErrors: false
        onLoaded: root.lock()
    }

    FileView {
        id: manifestView
        path: root.themeDir !== "" ? root.themeDir + "/manifest.json" : ""
        blockLoading: true
        printErrors: false
        onLoaded: root.readManifest()
    }

    FileView {
        id: packCheck
        path: root.packDesign
        printErrors: false
        onLoaded: root.hasPackDesign = true
        onLoadFailed: root.hasPackDesign = false
    }

    Process {
        id: capsProbe
        command: ["sh", "-c", "cat /sys/class/leds/*::capslock/brightness 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: root.capsLock = text.split("\n").some(l => l.trim() !== "" && l.trim() !== "0")
        }
    }

    // The LED changes just after the key event that toggled it.
    Timer {
        id: capsDelay
        interval: 120
        onTriggered: root.refreshCapsLock()
    }

    function capsLockPressed() {
        capsDelay.restart();
    }

    // Full name from the passwd GECOS field, for the card.
    Process {
        running: true
        command: ["getent", "passwd", root.userName]
        stdout: StdioCollector {
            onStreamFinished: {
                const gecos = (text.split(":")[4] ?? "").split(",")[0].trim();
                if (gecos !== "")
                    root.realName = gecos;
            }
        }
    }

    IpcHandler {
        target: "lock"

        function lock(): void {
            root.lock();
        }

        function isLocked(): bool {
            return sessionLock.locked;
        }

        // Dev-session test hooks (STUDIO_DEV=1 only): unlock without a
        // password / show the failure state without running PAM.
        function devUnlock(): string {
            if (!root.devMode)
                return "refused: STUDIO_DEV is not set";
            root.unlock();
            return "unlocked";
        }

        function devFail(): string {
            if (!root.devMode)
                return "refused: STUDIO_DEV is not set";
            root.failed("Incorrect password");
            return "failed";
        }
    }
}
