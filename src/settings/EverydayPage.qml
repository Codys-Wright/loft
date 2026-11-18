import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Everyday: Cleaning Mode, Quit on close, Quit protection,
// Arrange and mouse notes (Keep Awake and Sleep: LockSleepPage). Each card
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

    // Keep Awake and Sleep moved to Settings → Lock & Sleep.
    SettingsCard {
        visible: Features.on("keepAwake")
        PageHeader {
            title: "Keep Awake & Sleep"
            SettingsButton {
                text: "Lock & Sleep…"
                onClicked: Panels.openSettings("locksleep", "keepawake")
            }
        }
        Note {
            text: `Keep Awake (now: ${KeepAwake.status.toLowerCase()}) and Bluetooth during sleep are in Settings → Lock & Sleep.`
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
