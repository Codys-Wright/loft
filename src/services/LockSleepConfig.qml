pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Settings → Lock & Sleep (and the Screen Saver look under Appearance):
// what happens while the computer sits idle, how it sleeps, and what the
// screen saver shows. Stored in $LOFT_STATE_DIR/overrides/lock-sleep.json;
// services/Idle.qml acts on it.
//
// The idle steps are seconds of no input, separate on power and on
// battery; 0 = never. The first defaults come from Settings.idle (where
// Settings → Lock Screen → When Idle kept them before), else from the Nix
// options programs.loft.idle.lockAfter / .screenOffAfter (through
// LOFT_IDLE_LOCK_AFTER / LOFT_IDLE_SCREEN_OFF_AFTER, "never" = 0). Under
// KWin, Idle.qml passes the lock / displays-off / sleep times to Plasma and
// mirrors them into Settings.idle.
Singleton {
    id: root

    readonly property string stateDir: Settings.stateDir
    readonly property string file: `${stateDir}/overrides/lock-sleep.json`

    // The idle steps, in the order they normally happen.
    readonly property var steps: ["dim", "screenSaver", "lock", "displayOff", "sleep"]

    readonly property alias idle: cfg.idle
    readonly property alias sleepMode: cfg.sleepMode
    readonly property alias battery: cfg.battery
    readonly property alias screenSaver: cfg.screenSaver
    readonly property alias powerButton: cfg.powerButton
    readonly property alias lid: cfg.lid
    readonly property alias showHibernate: cfg.showHibernate

    // A first default: what was set earlier in Settings → Lock Screen
    // (Settings.idle, before this page; -1 = not set), else Nix's.
    function seed(idleKey, envName, fallback) {
        const v = Settings.idle?.[idleKey] ?? -1;
        return v >= 0 ? v : envSeconds(envName, fallback);
    }

    function envSeconds(name, fallback) {
        const v = Quickshell.env(name);
        if (v === null || v === undefined || v === "")
            return fallback;
        if (v === "never" || v === "null")
            return 0;
        const n = parseInt(v);
        return isNaN(n) || n < 0 ? fallback : n;
    }

    // Seconds for one step: `power` is "ac" or "battery".
    function seconds(step, power) {
        const s = cfg.idle[step];
        return Math.max(0, s?.[power] ?? 0);
    }

    function setSeconds(step, power, secs) {
        const next = Object.assign({}, cfg.idle[step] ?? {});
        next[power] = secs;
        cfg.idle[step] = next;
    }

    FileView {
        id: view
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onAdapterUpdated: writeAdapter()
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound)
                mkdir.running = true;
        }

        JsonAdapter {
            id: cfg

            property JsonObject idle: JsonObject {
                // Darken the screens a little: the warning before what follows.
                property var dim: ({ ac: 0, battery: 0 })
                property var screenSaver: ({ ac: 0, battery: 0 })
                property var lock: ({
                        ac: root.seed("lockAfter", "LOFT_IDLE_LOCK_AFTER", 300),
                        battery: root.seed("lockAfter", "LOFT_IDLE_LOCK_AFTER", 300)
                    })
                property var displayOff: ({
                        ac: root.seed("screenOffAfter", "LOFT_IDLE_SCREEN_OFF_AFTER", 600),
                        battery: root.seed("screenOffAfter", "LOFT_IDLE_SCREEN_OFF_AFTER", 600)
                    })
                property var sleep: ({
                        ac: Math.max(0, Settings.idle?.suspendAfter ?? 0),
                        battery: Math.max(0, Settings.idle?.suspendAfter ?? 0)
                    })
            }

            // How the computer sleeps, for the idle step and the critical
            // battery action: suspend | hibernate | hybrid-sleep |
            // suspend-then-hibernate (systemctl verbs).
            property string sleepMode: "suspend"

            // Hibernate in the system menu (when the computer can).
            property bool showHibernate: true

            // The power key: sleep (the sleep mode above) | hibernate |
            // lock | displayOff | ask (the Shut Down dialog) | poweroff |
            // nothing | system (systemd-logind's HandlePowerKey). Plain
            // sleep with the suspend mode is niri's own handling; anything
            // else turns that off and the shell's XF86PowerOff bind acts.
            property string powerButton: "sleep"

            // Closing the lid, on battery / on power / with an external
            // display: system (systemd-logind's HandleLidSwitch*) | sleep |
            // hibernate | lock | displayOff | nothing. Anything but
            // "system" takes the lid over from logind (niri's lid-close
            // switch event reaches the shell).
            property JsonObject lid: JsonObject {
                property string battery: "system"
                property string ac: "system"
                property string docked: "system"
            }

            property JsonObject battery: JsonObject {
                // At or below this % on battery, do `criticalAction`
                // (0 = never): sleep (the sleep mode above) | hibernate |
                // poweroff | none.
                property int criticalPercent: 5
                property string criticalAction: "hibernate"
            }

            // The look (Settings → Appearance → Screen Saver).
            property JsonObject screenSaver: JsonObject {
                // clock: the wallpaper, darkened, under a large clock |
                // drift: the wallpaper slowly panning, small clock |
                // black: black with a dim clock that moves (OLED-safe).
                property string style: "clock"
                property bool showClock: true
                property bool showMedia: true
            }
        }
    }

    Component.onCompleted: view.path = file

    Process {
        id: mkdir
        command: ["mkdir", "-p", `${root.stateDir}/overrides`]
        onExited: {
            view.writeAdapter();
            view.path = "";
            view.path = root.file;
        }
    }
}
