import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services

// Settings → Dock: size and magnification, window previews (hover / click,
// delay, thumbnails), per-display dock (on/off; default / show /
// auto-hide / hidden, the default being "Default visibility"; position),
// behavior, the recent-apps section, docked folders and the Trash, and the
// pinned apps.
ColumnLayout {
    id: page
    spacing: 12

    SettingsCard {
        PageHeader {
            title: "Dock"
        }

        SettingsRow {
            label: "Size"
            SettingsSlider {
                from: 32
                to: 80
                step: 1
                suffix: " px"
                value: Settings.dock.iconSize
                onMoved: v => Settings.dock.iconSize = v
            }
        }

        SettingsRow {
            label: "Magnification"
            hint: "Icons grow under the pointer (1× = off)"
            SettingsSlider {
                from: 1
                to: 2
                step: 0.05
                decimals: 2
                suffix: "×"
                value: Settings.dock.magnification
                onMoved: v => Settings.dock.magnification = v
            }
        }

        SettingsRow {
            label: "Animate opening applications"
            hint: "The icon bounces until the app's first window opens"
            SettingsSwitch {
                checked: Settings.dock.bounce
                onToggled: on => Settings.dock.bounce = on
            }
        }

        SettingsRow {
            label: "Show indicators for open applications"
            SettingsSwitch {
                checked: Settings.dock.indicators
                onToggled: on => Settings.dock.indicators = on
            }
        }

        SettingsRow {
            label: "Hiding windows"
            hint: "niri has no minimize: Hide parks an app's windows on a \"hidden-<display>\" workspace; Show All brings them back"
        }
    }

    SettingsCard {
        PageHeader {
            title: "Window previews"
        }

        SettingsRow {
            label: "Show an app's windows"
            hint: Previews.mode === "click" ? "Click an app with several windows (one window just focuses)" : "Rest the pointer on a running app: a card per window"
            SettingsSegmented {
                options: [
                    { value: "off", label: "Off" },
                    { value: "hover", label: "On hover" },
                    { value: "click", label: "On click" }
                ]
                current: Features.on("dockPreview") ? Previews.mode : "off"
                onActivated: v => {
                    Features.set("dockPreview", v !== "off");
                    if (v !== "off")
                        Settings.dock.preview = v;
                }
            }
        }

        SettingsRow {
            visible: Features.on("dockPreview")
            label: "In the preview"
            hint: "Click focuses · × or middle-click closes · right-click or ⋯: move, hide"
        }

        SettingsRow {
            visible: Features.on("dockPreview") && Previews.mode === "hover"
            label: "Delay"
            hint: "How long the pointer rests on an icon first"
            SettingsSlider {
                from: 0
                to: 1500
                step: 50
                suffix: " ms"
                value: Settings.dock.previewDelay
                onMoved: v => Settings.dock.previewDelay = Math.round(v)
            }
        }

        SettingsRow {
            visible: Features.on("dockPreview")
            label: "Window thumbnails"
            hint: Previews.canCapture ? "Floating and fullscreen windows; tiled ones show their app icon" : Previews.support ? "Not available here (no GPU capture): cards show the app icon" : "Checking…"
            SettingsSwitch {
                checked: Settings.dock.previewThumbnails
                onToggled: on => Settings.dock.previewThumbnails = on
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: Quickshell.screens.length > 1 ? "Displays" : "Show and position"
        }

        SettingsRow {
            visible: Quickshell.screens.length > 1
            label: "Default position"
            hint: "For displays without their own choice"
            SettingsSegmented {
                options: [
                    { value: "left", label: "Left" },
                    { value: "bottom", label: "Bottom" },
                    { value: "right", label: "Right" }
                ]
                current: Settings.dock.position
                onActivated: v => Settings.dock.position = v
            }
        }

        // What displays set to Default do (Settings.dock.autoHide).
        SettingsRow {
            visible: Quickshell.screens.length > 1
            label: "Default visibility"
            hint: Settings.dock.autoHide === "always" ? "Hidden until the pointer touches the edge" : Settings.dock.autoHide === "whenWindows" ? "Shown on an empty desktop, hidden once a window is open there" : "Always there (an ultrawide display hides it once a window is open)"
            SettingsSegmented {
                options: [
                    { value: "never", label: "Show" },
                    { value: "whenWindows", label: "Hide with windows" },
                    { value: "always", label: "Auto-hide" }
                ]
                current: DockData.hideMode(Settings.dock.autoHide)
                onActivated: v => Settings.dock.autoHide = v
            }
        }

        // The active space's `dock.visible` wins over every display's own
        // choice while it's active (SPACES §5).
        SettingsRow {
            readonly property string spaceVis: Spaces.dock?.visible ?? ""
            visible: spaceVis !== ""
            label: `The space “${Spaces.active?.name ?? ""}” sets the Dock`
            hint: `${spaceVis === "show" ? "Shown" : spaceVis === "autohide" ? "Automatically hidden" : "Hidden"} on every display while it's active; your choices below apply in other spaces`
        }

        // One block per display (with one display: just its rows).
        Repeater {
            model: Quickshell.screens

            delegate: ColumnLayout {
                id: disp
                required property var modelData
                readonly property var prefs: DockData.displayPrefs(modelData)
                readonly property bool several: Quickshell.screens.length > 1
                readonly property bool followsDefault: several && !prefs.own
                Layout.fillWidth: true
                Layout.topMargin: several ? 8 : 0
                spacing: 8

                Rectangle {
                    visible: disp.several
                    Layout.fillWidth: true
                    height: 1
                    color: Theme.withAlpha(Theme.text, 0.08)
                }

                SettingsRow {
                    visible: disp.several
                    label: DockData.displayLabel(disp.modelData)
                    hint: `${disp.modelData.name} · ${disp.modelData.width}×${disp.modelData.height}` + (disp.prefs.enabled ? "" : " · no Dock on this display")
                    SettingsSwitch {
                        checked: disp.prefs.enabled
                        onToggled: on => DockData.setDisplayPref(disp.modelData, "enabled", on)
                    }
                }
                SettingsRow {
                    visible: disp.prefs.enabled
                    label: disp.several ? "Dock" : "Dock on this display"
                    hint: (disp.followsDefault ? `Default: ${disp.prefs.autoHide === "never" ? "shown" : disp.prefs.autoHide === "always" ? "auto-hides" : "hides with windows"}. ` : "") + (disp.prefs.visibility === "hidden" ? "Hidden: no Dock and no edge to summon it, unless a space shows it" : disp.prefs.visibility === "autohide" ? "Move the pointer to the edge to show it" : "Always there. Every dock steps aside while a window is fullscreen")
                    // With several displays, Default follows "Default
                    // visibility" above until the display gets its own.
                    SettingsSegmented {
                        options: (disp.several ? [{ value: "default", label: "Default" }] : []).concat([
                            { value: "show", label: "Show" },
                            { value: "autohide", label: "Auto-hide" },
                            { value: "hidden", label: "Hidden" }
                        ])
                        current: disp.followsDefault ? "default" : disp.prefs.visibility
                        onActivated: v => DockData.chooseDisplayVisibility(disp.modelData, v)
                    }
                }
                SettingsRow {
                    visible: disp.prefs.enabled && disp.prefs.visibility === "autohide" && !disp.followsDefault
                    label: "Automatically hide"
                    hint: "With windows: shown on an empty desktop, hidden once a window is open there"
                    SettingsSegmented {
                        options: [
                            { value: "whenWindows", label: "With windows" },
                            { value: "always", label: "Always" }
                        ]
                        current: disp.prefs.autoHide
                        onActivated: v => DockData.setDisplayPref(disp.modelData, "autoHide", v)
                    }
                }
                SettingsRow {
                    visible: disp.prefs.enabled && disp.prefs.visibility !== "hidden"
                    label: "Position on screen"
                    SettingsSegmented {
                        options: [
                            { value: "left", label: "Left" },
                            { value: "bottom", label: "Bottom" },
                            { value: "right", label: "Right" }
                        ]
                        current: disp.prefs.position
                        onActivated: v => DockData.setDisplayPref(disp.modelData, "position", v)
                    }
                }
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: "Recent apps"
        }

        SettingsRow {
            label: "Show suggested and recent apps in Dock"
            hint: "Apps you used lately that aren't in the dock, in their own section"
            SettingsSwitch {
                checked: Features.on("dockRecents")
                onToggled: on => Features.set("dockRecents", on)
            }
        }

        SettingsRow {
            visible: Features.on("dockRecents")
            label: "How many"
            SettingsSlider {
                from: 1
                to: 8
                step: 1
                value: Settings.dock.recentCount
                onMoved: v => Settings.dock.recentCount = Math.round(v)
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: "Folders and Trash"
        }

        SettingsRow {
            label: "Folders in the Dock"
            hint: "Stacks left of the Trash; right-click one to sort it or change how it opens"
            SettingsSwitch {
                checked: Features.on("dockStacks")
                onToggled: on => Features.set("dockStacks", on)
            }
        }

        Repeater {
            model: Features.on("dockStacks") ? Settings.dock.folders : []

            delegate: SettingsRow {
                id: fr
                required property var modelData
                required property int index
                label: DockData.folder(modelData.path)?.listing?.name || modelData.path
                hint: modelData.path

                RowLayout {
                    spacing: 6
                    SettingsSelect {
                        options: [
                            { value: "auto", label: "Automatic" },
                            { value: "fan", label: "Fan" },
                            { value: "grid", label: "Grid" },
                            { value: "list", label: "List" }
                        ]
                        current: fr.modelData.view ?? "auto"
                        onActivated: v => DockData.setFolder(fr.index, { view: v })
                    }
                    SettingsSelect {
                        options: [
                            { value: "added", label: "Date Added" },
                            { value: "modified", label: "Date Modified" },
                            { value: "name", label: "Name" },
                            { value: "kind", label: "Kind" }
                        ]
                        current: fr.modelData.sort ?? "added"
                        onActivated: v => DockData.setFolder(fr.index, { sort: v })
                    }
                    SettingsSegmented {
                        options: [
                            { value: "stack", label: "Stack" },
                            { value: "folder", label: "Folder" }
                        ]
                        current: fr.modelData.display ?? "stack"
                        onActivated: v => DockData.setFolder(fr.index, { display: v })
                    }
                    Icon {
                        text: "󰅖"
                        size: 13
                        color: Theme.subtext
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            onClicked: DockData.removeFolder(fr.index)
                        }
                    }
                }
            }
        }

        SettingsRow {
            visible: Features.on("dockStacks")
            label: "Add folder to Dock"
            hint: "A path (~/Documents), or pick one"
            RowLayout {
                spacing: 6
                SettingsTextField {
                    id: newFolder
                    implicitWidth: 220
                    placeholder: "~/Documents/Loft"
                    onCommitted: t => {
                        DockData.addFolder(t);
                        text = "";
                    }
                }
                SettingsButton {
                    text: "Add"
                    onClicked: {
                        DockData.addFolder(newFolder.text);
                        newFolder.text = "";
                    }
                }
            }
        }

        Flow {
            visible: Features.on("dockStacks")
            Layout.fillWidth: true
            spacing: 6

            Repeater {
                model: [
                    { path: "xdg:DOWNLOAD", label: "Downloads" },
                    { path: "xdg:DOCUMENTS", label: "Documents" },
                    { path: "~/Documents/Loft", label: "Theme library" },
                    { path: "xdg:PICTURES", label: "Pictures" },
                    { path: "xdg:DESKTOP", label: "Desktop" },
                    { path: "~", label: "Home" }
                ].filter(o => !Array.from(Settings.dock.folders).some(f => f.path === o.path))

                delegate: SettingsButton {
                    required property var modelData
                    text: "+ " + modelData.label
                    onClicked: DockData.addFolder(modelData.path)
                }
            }
        }

        SettingsRow {
            visible: Features.on("dockStacks")
            label: "Trash"
            hint: "Click opens it; drop files on it to trash them; right-click to empty"
            SettingsSwitch {
                checked: Settings.dock.trash
                onToggled: on => Settings.dock.trash = on
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: "Pinned apps"
        }

        SettingsRow {
            label: "In the Dock"
            hint: "Right-click an app → Options → Keep in Dock to add one; × to remove"
        }

        Flow {
            Layout.fillWidth: true
            spacing: 8

            Repeater {
                model: Settings.dock.pinned
                delegate: Rectangle {
                    id: pin
                    required property string modelData
                    required property int index
                    width: pinRow.implicitWidth + 20
                    height: 34
                    radius: 17
                    color: Theme.withAlpha(Theme.text, 0.08)

                    RowLayout {
                        id: pinRow
                        anchors.centerIn: parent
                        spacing: 8

                        AppIcon {
                            Layout.preferredWidth: 20
                            Layout.preferredHeight: 20
                            appId: pin.modelData
                            pixelSize: 40
                        }
                        Text {
                            text: Apps.name(pin.modelData)
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 12
                        }
                        Icon {
                            text: "󰅖"
                            size: 12
                            color: Theme.subtext
                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -6
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const l = Array.from(Settings.dock.pinned);
                                    l.splice(pin.index, 1);
                                    Settings.dock.pinned = l;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
