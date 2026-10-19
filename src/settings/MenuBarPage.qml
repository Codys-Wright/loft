import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Menu Bar: the status items (MenuBarArrange), the app menu
// (click the app name / Mod+F10) and the global menu (the focused app's
// File / Edit / View … in the bar), and the workspace icons
// (WorkspaceIcons).
ColumnLayout {
    id: page
    spacing: 12

    // The status area: items, tray, clock, Control Center.
    MenuBarArrange {
        Layout.fillWidth: true
    }

    SettingsCard {
        PageHeader {
            title: "Full screen"
        }

        SettingsRow {
            label: "Hide in full screen"
            hint: AppMenu.pref("hideInFullscreen") ? "The menu bar slides away while a window is full screen on its display" : "The menu bar stays, drawn over the full-screen app"
            SettingsSwitch {
                checked: AppMenu.pref("hideInFullscreen")
                onToggled: on => AppMenu.setPref("hideInFullscreen", on)
            }
        }

        SettingsRow {
            visible: AppMenu.pref("hideInFullscreen")
            label: "Show menu bar when pointer reaches top"
            hint: "Rest the pointer at the top edge of the screen and the bar slides back down, with the Dynamic Island"
            SettingsSwitch {
                checked: AppMenu.pref("revealAtTop")
                onToggled: on => AppMenu.setPref("revealAtTop", on)
            }
        }
    }

    // ── Workspace icons ─────────────────────────────────────────────────
    SettingsCard {
        id: wsCard

        // The named workspaces: live ones (one row per name, with the
        // displays they're on), then names with a choice that aren't open.
        readonly property var rows: {
            const out = [];
            const byKey = {};
            for (const w of Niri.workspaces) {
                if (!w.name || w.name.startsWith("hidden-"))
                    continue;
                const k = WorkspaceIcons.key(w.name);
                if (!byKey[k]) {
                    byKey[k] = { name: w.name, outputs: [], live: true };
                    out.push(byKey[k]);
                }
                if (w.output && !byKey[k].outputs.includes(w.output))
                    byKey[k].outputs.push(w.output);
            }
            for (const k of Object.keys(WorkspaceIcons.user))
                if (!byKey[k])
                    out.push({ name: k, outputs: [], live: false });
            return out;
        }
        property string editing: ""

        function where(output) {
            const s = Displays.screens.find(x => x.name === output);
            return s ? DockData.displayLabel(s) : output;
        }

        PageHeader {
            title: "Workspace Icons"
        }

        SettingsRow {
            label: "Show workspace icons"
            hint: Features.on("spaces") ? "Spaces is on: the bar shows your spaces and their icons instead" : WorkspaceIcons.enabled ? "Named workspaces show an icon instead of a dot; the one each display is on is named next to them" : "Every workspace is a dot"
            SettingsSwitch {
                checked: WorkspaceIcons.enabled
                onToggled: on => WorkspaceIcons.setEnabled(on)
            }
        }

        Text {
            visible: WorkspaceIcons.enabled && wsCard.rows.length === 0
            Layout.fillWidth: true
            text: "No named workspaces. Name them in your niri config (workspace \"music\" { … }) and they show up here."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            wrapMode: Text.Wrap
        }

        Repeater {
            model: WorkspaceIcons.enabled ? wsCard.rows : []

            delegate: ColumnLayout {
                id: wsRow
                required property var modelData
                readonly property string name: modelData.name
                readonly property string icon: WorkspaceIcons.iconFor(name)
                readonly property bool custom: WorkspaceIcons.isCustom(name)
                readonly property bool open: wsCard.editing === WorkspaceIcons.key(name)
                Layout.fillWidth: true
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Rectangle {
                        implicitWidth: 30
                        implicitHeight: 30
                        radius: 7
                        color: Theme.withAlpha(Theme.text, 0.07)
                        Icon {
                            anchors.centerIn: parent
                            text: wsRow.icon || "󰧞"
                            size: wsRow.icon ? 16 : 10
                            color: wsRow.icon ? Theme.text : Theme.subtext
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Text {
                            text: wsRow.name
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 13
                            font.weight: Font.Medium
                        }
                        Text {
                            Layout.fillWidth: true
                            text: [wsRow.modelData.live ? wsRow.modelData.outputs.map(o => wsCard.where(o)).join(", ") : "not open now", wsRow.custom ? (wsRow.icon ? "your choice" : "no icon (a dot)") : wsRow.icon ? "default" : "no default icon"].filter(t => t).join("  ·  ")
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                    }
                    SettingsButton {
                        visible: wsRow.custom
                        text: "Reset"
                        icon: "󰑓"
                        onClicked: WorkspaceIcons.reset(wsRow.name)
                    }
                    SettingsButton {
                        text: wsRow.open ? "Done" : "Change"
                        primary: wsRow.open
                        onClicked: wsCard.editing = wsRow.open ? "" : WorkspaceIcons.key(wsRow.name)
                    }
                }

                SpaceIconPicker {
                    visible: wsRow.open
                    Layout.fillWidth: true
                    Layout.leftMargin: 40
                    current: wsRow.icon
                    onPicked: icon => WorkspaceIcons.set(wsRow.name, icon)
                }
            }
        }
    }

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
            label: "System menu"
            hint: "Click the NixOS logo: About This Computer, Settings, Sleep, Restart, Shut Down, Lock, Log Out. Off, or middle-click it: the overview"
            SettingsSwitch {
                checked: Features.on("systemMenu")
                onToggled: on => Features.set("systemMenu", on)
            }
        }

        SettingsRow {
            visible: Features.on("systemMenu")
            label: "Restart / Shut Down countdown"
            hint: "The confirmation goes ahead by itself after 60 seconds, like macOS"
            SettingsSwitch {
                checked: AppMenu.pref("powerCountdown")
                onToggled: on => AppMenu.setPref("powerCountdown", on)
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
                    return "Running — registrar disabled (LOFT_APPMENU_REGISTRAR=0)";
                default:
                    return "Not running (loft-appmenu missing from PATH?)";
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
