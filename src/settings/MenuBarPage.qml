import QtQuick
import QtQuick.Layouts
import qs.services

// Settings → Menu Bar: the app menu (click the app name / Mod+F10) and the
// global menu (the focused app's File / Edit / View … in the bar).
ColumnLayout {
    id: page
    spacing: 12

    SettingsCard {
        PageHeader {
            title: "Menus"
        }

        SettingsRow {
            label: "App menu"
            hint: "Click the app's name in the bar, or press Mod+F10"
            SettingsSwitch {
                checked: Features.on("appMenu")
                onToggled: on => Features.set("appMenu", on)
            }
        }

        SettingsRow {
            label: "Global menu"
            hint: "File, Edit, View … of Qt/KDE apps (opened after turning it on), GTK and X11 Electron apps"
            SettingsSwitch {
                checked: Features.on("globalMenu")
                onToggled: on => Features.set("globalMenu", on)
            }
        }

        SettingsRow {
            visible: Features.on("globalMenu")
            label: "Menu service"
            hint: {
                switch (AppMenu.registrar) {
                case "owned":
                    return "Running — apps register their menus with the shell";
                case "external":
                    return "Running — another menu registrar (e.g. Plasma) is active; menus are found by introspection";
                case "off":
                    return "Running — registrar disabled (STUDIO_APPMENU_REGISTRAR=0)";
                default:
                    return "Not running (studio-appmenu missing from PATH?)";
                }
            }
            hintColor: AppMenu.registrar === "" ? Theme.warn : Theme.subtext
        }

        SettingsRow {
            label: "Shortcut style"
            hint: "How menus print keyboard shortcuts"
            SettingsSegmented {
                options: [
                    { value: true, label: "⌃⇧S" },
                    { value: false, label: "Ctrl+Shift+S" }
                ]
                current: AppMenu.pref("symbols")
                onActivated: v => AppMenu.setPref("symbols", v)
            }
        }
    }

    SettingsCard {
        visible: Features.on("appMenu")

        PageHeader {
            title: "App menu contains"
        }

        SettingsRow {
            label: "New Window and app actions"
            hint: "From the app's .desktop file (e.g. New Private Window)"
            SettingsSwitch {
                checked: AppMenu.pref("desktopActions")
                onToggled: on => AppMenu.setPref("desktopActions", on)
            }
        }
        SettingsRow {
            label: "Move to Workspace / Display"
            SettingsSwitch {
                checked: AppMenu.pref("moveCommands")
                onToggled: on => AppMenu.setPref("moveCommands", on)
            }
        }
        SettingsRow {
            label: "Window commands"
            hint: "Float / Tile, Full Screen, Maximize Column, Center"
            SettingsSwitch {
                checked: AppMenu.pref("windowCommands")
                onToggled: on => AppMenu.setPref("windowCommands", on)
            }
        }
        SettingsRow {
            label: "Hide, Hide Others, Show All"
            hint: "niri has no minimize: hidden windows park on a \"hidden-<display>\" workspace"
            SettingsSwitch {
                checked: AppMenu.pref("hideCommands")
                onToggled: on => AppMenu.setPref("hideCommands", on)
            }
        }
    }

    SettingsCard {
        visible: Features.on("appMenu")

        PageHeader {
            title: "Quitting apps"
        }

        SettingsRow {
            label: "Confirm before quitting"
            hint: "Ask when the app has more than one window open"
            SettingsSwitch {
                checked: AppMenu.pref("confirmQuit")
                onToggled: on => AppMenu.setPref("confirmQuit", on)
            }
        }
        SettingsRow {
            label: "End apps that keep running"
            hint: "After Quit closes every window, send SIGTERM if the process is still alive"
            SettingsSegmented {
                options: [
                    { value: 0, label: "Never" },
                    { value: 3, label: "3 s" },
                    { value: 10, label: "10 s" }
                ]
                current: AppMenu.pref("forceQuitDelay")
                onActivated: v => AppMenu.setPref("forceQuitDelay", v)
            }
        }
    }
}
