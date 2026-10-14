import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.components
import qs.services

// Settings → Everyday: Keep Awake rules, Sleep (Bluetooth off), Cleaning
// Mode, Quit on close, Quit protection, Arrange and mouse notes. Each card
// shows while its module is on (Settings → Features). Values:
// services/EverydayConfig.qml.
ColumnLayout {
    id: page
    spacing: 12

    readonly property var cfg: EverydayConfig

    component Note: Text {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 12
    }

    // ── Keep Awake
    SettingsCard {
        visible: Features.on("keepAwake")

        PageHeader {
            title: "Keep Awake"
        }
        Note {
            text: (KeepAwake.inhibitError ? `systemd-logind refused the inhibitor (${KeepAwake.inhibitError}); idle is still inhibited through Wayland. ` : "") + `Now: ${KeepAwake.status}. While awake the screen doesn't blank or lock on idle (an idle inhibitor, which niri passes to swayidle and friends) and, with the option below, the system doesn't suspend (a systemd-logind inhibitor).`
        }

        SettingsRow {
            label: "The toggle keeps awake"
            hint: "Control Center / menu bar click; the menu has more durations"
            SettingsSegmented {
                options: [{ value: 0, label: "Until off" }, { value: 15, label: "15 min" }, { value: 60, label: "1 h" }, { value: 120, label: "2 h" }]
                current: page.cfg.keepAwake.defaultMinutes
                onActivated: v => page.cfg.keepAwake.defaultMinutes = v
            }
        }
        SettingsRow {
            label: "Also block suspend"
            hint: "systemd-inhibit --what=idle:sleep while awake"
            SettingsSwitch {
                checked: page.cfg.keepAwake.blockSleep
                onToggled: on => page.cfg.keepAwake.blockSleep = on
            }
        }
        SettingsRow {
            visible: KeepAwake.hasBattery
            label: "Stay awake with the lid closed"
            hint: "While awake, closing the lid doesn't suspend (logind handle-lid-switch inhibitor)"
            SettingsSwitch {
                checked: page.cfg.keepAwake.lidClosed
                onToggled: on => page.cfg.keepAwake.lidClosed = on
            }
        }
        SettingsRow {
            label: "While on power"
            hint: KeepAwake.hasBattery ? (KeepAwake.onAC ? "On power now" : "On battery now") : "No battery: always on power"
            SettingsSwitch {
                checked: page.cfg.keepAwake.onAC
                onToggled: on => page.cfg.keepAwake.onAC = on
            }
        }
        SettingsRow {
            label: "While an external display is connected"
            hint: KeepAwake.externalScreens.length > 0 ? `Connected: ${KeepAwake.externalScreens.map(s => s.name).join(", ")}` : "None connected (eDP / LVDS / DSI panels are internal)"
            SettingsSwitch {
                checked: page.cfg.keepAwake.externalDisplay
                onToggled: on => page.cfg.keepAwake.externalDisplay = on
            }
        }
        SettingsRow {
            label: "While these apps have a window open"
        }
        AppIdList {
            apps: Array.from(page.cfg.keepAwake.apps)
            emptyText: "No apps — e.g. a video player or a presentation app"
            onChanged: l => page.cfg.keepAwake.apps = l
        }
    }

    // ── Sleep (the loft-sleep user service does the work)
    SettingsCard {
        id: sleepCard

        // `loft-sleep status`: { enabled, remembered, adapters: [{ path, powered }] }
        property var status: null
        property bool serviceActive: false
        readonly property var adapters: status?.adapters ?? []

        function refresh() {
            sleepStatus.running = true;
            sleepUnit.running = true;
        }
        Component.onCompleted: refresh()
        onVisibleChanged: if (visible)
            refresh()

        Process {
            id: sleepStatus
            command: ["loft-sleep", "status"]
            stdout: StdioCollector {
                onStreamFinished: {
                    try {
                        sleepCard.status = JSON.parse(text);
                    } catch (e) {
                        sleepCard.status = null;
                    }
                }
            }
        }
        // Read-only: is the user service there and running?
        Process {
            id: sleepUnit
            command: ["systemctl", "--user", "is-active", "--quiet", "loft-sleep.service"]
            onExited: code => sleepCard.serviceActive = code === 0
        }

        PageHeader {
            title: "Sleep"
        }
        SettingsRow {
            label: "Turn Bluetooth off during sleep"
            hint: sleepCard.adapters.length === 0 ? "No Bluetooth adapter found" : sleepCard.adapters.map(a => `${a.path.replace(/^.*\//, "")}: ${a.powered ? "on" : "off"}`).join(" · ") + " — back on after the wake if it was on"
            SettingsSwitch {
                checked: page.cfg.sleep.bluetoothOff
                onToggled: on => page.cfg.sleep.bluetoothOff = on
            }
        }
        Note {
            text: (sleepCard.serviceActive ? "" : "The loft-sleep service isn't running, so this has no effect yet (programs.loft.sleepWatcher in home-manager starts it). ") + "Before the system suspends or hibernates, every Bluetooth adapter that's on is switched off, so headphones and mice don't wake it or drain; after the wake the same adapters are switched back on. Adapters that were off stay off. A user service listens for logind's PrepareForSleep (no root) and holds a short sleep delay so the adapters are off first."
        }
    }

    // ── Cleaning Mode
    SettingsCard {
        visible: Features.on("cleaningMode")

        PageHeader {
            title: "Cleaning Mode"
            SettingsButton {
                text: "Start"
                onClicked: {
                    Panels.settingsOpen = false;
                    Cleaning.start();
                }
            }
        }
        Note {
            text: "Every display goes dark and keys, clicks and shortcuts stop reaching apps and niri (it's a session lock), so you can wipe the keyboard, trackpad and screens. Hold Esc to leave (also the key Esc becomes when held, with xremap's Esc → Mod). Also: the Cleaning Mode control (Control Center → Edit Controls), Spotlight “Cleaning Mode”, `qs ipc call cleaning start|stop`. niri still runs binds marked allow-when-locked (usually media keys)."
        }
        SettingsRow {
            label: "Ends by itself after"
            SettingsSegmented {
                options: [{ value: 30, label: "30 s" }, { value: 60, label: "1 min" }, { value: 120, label: "2 min" }, { value: 300, label: "5 min" }, { value: 0, label: "Never" }]
                current: page.cfg.cleaning.seconds
                onActivated: v => page.cfg.cleaning.seconds = v
            }
        }
        SettingsRow {
            label: "Hold Esc for"
            SettingsSegmented {
                options: [{ value: 2, label: "2 s" }, { value: 3, label: "3 s" }, { value: 5, label: "5 s" }]
                current: page.cfg.cleaning.holdSeconds
                onActivated: v => page.cfg.cleaning.holdSeconds = v
            }
        }
    }

    // ── Quit protection
    SettingsCard {
        visible: Features.on("quitProtection")

        PageHeader {
            title: "Quit protection"
        }
        Note {
            text: "⌘Q (Mod+Q — Super+Q in a real session — and Alt+F4, what xremap's macOS layout sends for ⌘Q) runs through the shell: for the apps below a tap only shows “Hold ⌘Q to quit”; holding it quits the app (every window). Other apps: the focused window closes, as before. niri has no key-release events, so a hold is detected from the key's repeats — a release is noticed up to ~0.4 s late. ⌘W is the app's own shortcut (niri never sees it), so it can't be protected here."
        }
        SettingsRow {
            label: "Every app"
            hint: "Otherwise only the apps below"
            SettingsSwitch {
                checked: page.cfg.quit.protectAll
                onToggled: on => page.cfg.quit.protectAll = on
            }
        }
        SettingsRow {
            label: "Hold for"
            SettingsSegmented {
                options: [{ value: 700, label: "0.7 s" }, { value: 1000, label: "1 s" }, { value: 1500, label: "1.5 s" }]
                current: page.cfg.quit.holdMs
                onActivated: v => page.cfg.quit.holdMs = v
            }
        }
        AppIdList {
            visible: !page.cfg.quit.protectAll
            apps: Array.from(page.cfg.quit.protect)
            emptyText: "No apps — or right-click an app in the dock → Options → Hold ⌘Q to Quit"
            onChanged: l => page.cfg.quit.protect = l
        }
    }

    // ── Quit on close
    SettingsCard {
        visible: Features.on("quitOnClose")

        PageHeader {
            title: "Quit on close"
        }
        Note {
            text: "When the last window of one of these apps closes, its process is asked to quit (SIGTERM) — for apps that otherwise stay in the tray or the background. Skipped when the process still has another window, or when it's Xwayland (every X11 app shares it)."
        }
        SettingsRow {
            label: "Wait before quitting"
            SettingsSegmented {
                options: [{ value: 0, label: "Now" }, { value: 2, label: "2 s" }, { value: 5, label: "5 s" }, { value: 10, label: "10 s" }]
                current: page.cfg.quit.graceSeconds
                onActivated: v => page.cfg.quit.graceSeconds = v
            }
        }
        AppIdList {
            apps: Array.from(page.cfg.quit.onClose)
            emptyText: "No apps — or right-click an app in the dock → Options → Quit When Last Window Closes"
            onChanged: l => page.cfg.quit.onClose = l
        }
    }

    // ── Arrange
    SettingsCard {
        visible: Features.on("arrange")

        PageHeader {
            title: "Arrange windows"
        }
        Note {
            text: "The app menu and the dock's right-click menu have Arrange ▸; Mod+Ctrl+A opens it as a palette at the focused window (arrow keys, Enter). Floating windows snap to halves, thirds, two thirds, quarters, fill and center. Tiled windows sit in niri's scrolling columns, so there it sets the column width (⅓ ½ ⅔ full), window height, centers, joins or splits columns — or floats and snaps the window."
        }
    }

    // ── Mouse
    SettingsCard {
        PageHeader {
            title: "Mouse extras"
        }
        Note {
            text: "Side buttons: apps already map them to Back / Forward (browsers, file managers, editors), so niri leaves them alone; niri can bind them (MouseBack / MouseForward, e.g. Mod+MouseBack) in your niri config. Scrolling sideways: hold Shift while scrolling in GTK, Firefox, Chromium and Electron apps; Qt apps use Alt. Pointer speed and scroll direction: Keyboard & Mouse."
        }
    }
}
