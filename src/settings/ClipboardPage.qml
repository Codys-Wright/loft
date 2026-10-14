import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Clipboard & Files: clipboard history, auto-clear, Clean URL,
// the Shelf and the Scratchpad. Each card shows while its module is on
// (Settings → Features). Values: services/ClipboardConfig.qml.
ColumnLayout {
    id: page
    spacing: 12

    readonly property bool clipboardOn: Features.on("clipboard")
    onVisibleChanged: if (visible && clipboardOn)
        Clipboard.refresh()

    SettingsCard {
        visible: !page.clipboardOn && !Features.on("shelf") && !Features.on("scratchpad")
        SettingsRow {
            label: "Clipboard history, the Shelf and the Scratchpad are off"
            hint: "Turn them on in Features"
            SettingsButton {
                text: "Features…"
                onClicked: Panels.settingsSection = "features"
            }
        }
    }

    // ── History
    SettingsCard {
        visible: page.clipboardOn

        PageHeader {
            title: "Clipboard history"
            SettingsButton {
                text: "Open"
                onClicked: {
                    Panels.settingsOpen = false;
                    Clipboard.panelOpen = true;
                }
            }
        }

        SettingsRow {
            label: "Record history"
            hint: "Runs wl-paste --watch cliphist store · turn off if something else already records into cliphist"
            SettingsSwitch {
                checked: ClipboardConfig.history.record
                onToggled: on => ClipboardConfig.history.record = on
            }
        }

        SettingsRow {
            label: "Keep"
            hint: "Older entries are dropped; pins are kept separately"
            SettingsSlider {
                from: 50
                to: 2000
                step: 50
                suffix: " items"
                implicitWidth: 260
                value: ClipboardConfig.history.maxItems
                onCommitted: v => ClipboardConfig.history.maxItems = Math.round(v)
            }
        }

        SettingsRow {
            label: "Enter pastes into the focused app"
            hint: "Off: Enter only copies. Pasting sends Ctrl+V with wtype to whatever had focus"
            SettingsSwitch {
                checked: ClipboardConfig.paste.onSelect
                onToggled: on => ClipboardConfig.paste.onSelect = on
            }
        }

        SettingsRow {
            label: "Terminals"
            hint: "App ids (regex) that paste with Ctrl+Shift+V"
            SettingsTextField {
                implicitWidth: 240
                text: ClipboardConfig.paste.terminals
                onCommitted: t => ClipboardConfig.paste.terminals = t
            }
        }

        SettingsRow {
            id: wipeRow
            property bool armed: false
            label: "Clear history"
            hint: armed ? "Click again — this deletes every entry (pins stay)" : `${Clipboard.entries.length} entries in cliphist`
            hintColor: armed ? Theme.urgent : Theme.subtext
            SettingsButton {
                text: wipeRow.armed ? "Delete all" : "Clear…"
                onClicked: {
                    if (wipeRow.armed)
                        Clipboard.wipe();
                    wipeRow.armed = !wipeRow.armed;
                }
            }
            Timer {
                running: wipeRow.armed
                interval: 4000
                onTriggered: wipeRow.armed = false
            }
        }

        SettingsRow {
            label: "Shortcuts"
            hint: "Mod+Shift+V history · Mod+Shift+Alt+V paste as plain text"
        }
    }

    // ── Privacy
    SettingsCard {
        visible: page.clipboardOn

        PageHeader {
            title: "Privacy"
            SettingsButton {
                text: "Clear clipboard now"
                onClicked: Clipboard.clear()
            }
        }

        SettingsRow {
            label: "Clear the clipboard"
            hint: "After the last copy · the saved history is kept"
            SettingsSlider {
                from: 0
                to: 60
                step: 1
                implicitWidth: 260
                format: v => Math.round(v) === 0 ? "Never" : `${Math.round(v)} min`
                value: ClipboardConfig.autoClear.minutes
                onCommitted: v => ClipboardConfig.autoClear.minutes = Math.round(v)
            }
        }

        SettingsRow {
            label: "Clear when the screen locks"
            SettingsSwitch {
                checked: ClipboardConfig.autoClear.onLock
                onToggled: on => ClipboardConfig.autoClear.onLock = on
            }
        }
    }

    // ── Links
    SettingsCard {
        visible: page.clipboardOn

        PageHeader {
            title: "Clean URL"
        }

        SettingsRow {
            label: "Remove tracking from copied links"
            hint: "utm_*, fbclid, gclid, YouTube/Spotify si=, … — the clean link replaces the copy"
            SettingsSwitch {
                checked: ClipboardConfig.cleanUrls
                onToggled: on => ClipboardConfig.cleanUrls = on
            }
        }

        SettingsRow {
            id: tryRow
            property string result: ""
            label: "Try it"
            hint: result !== "" ? result : "Paste a link to see what's removed"
            hintColor: result !== "" ? Theme.accent : Theme.subtext
            SettingsTextField {
                implicitWidth: 240
                placeholder: "https://…?utm_source=…"
                onEdited: t => tryRow.result = t.trim() === "" ? "" : Clipboard.isTrackedUrl(t) ? Clipboard.cleanUrl(t).trim() : "Nothing to remove"
            }
        }
    }

    // ── Shelf
    SettingsCard {
        visible: Features.on("shelf")

        PageHeader {
            title: "Shelf"
            SettingsButton {
                text: "Open"
                onClicked: Shelf.open = true
            }
            SettingsButton {
                visible: Shelf.items.length > 0
                text: `Clear ${Shelf.items.length}`
                onClicked: Shelf.clear()
            }
        }

        SettingsRow {
            label: "Screen edge"
            SettingsSegmented {
                options: [
                    { value: "left", label: "Left" },
                    { value: "right", label: "Right" }
                ]
                current: ClipboardConfig.shelf.edge
                onActivated: v => ClipboardConfig.shelf.edge = v
            }
        }

        SettingsRow {
            label: "Slide out while dragging"
            hint: "A thin strip in the middle of the edge notices drags; off: open it with IPC shelf toggle"
            SettingsSwitch {
                checked: ClipboardConfig.shelf.revealOnDrag
                onToggled: on => ClipboardConfig.shelf.revealOnDrag = on
            }
        }
    }

    // ── Scratchpad
    SettingsCard {
        visible: Features.on("scratchpad")

        PageHeader {
            title: "Scratchpad"
            SettingsButton {
                text: "Open"
                onClicked: Scratchpad.open = true
            }
        }

        SettingsRow {
            label: "Export folder"
            hint: "Ctrl+S in the Scratchpad saves the note here as <title>.md"
            SettingsTextField {
                implicitWidth: 240
                text: ClipboardConfig.scratchpad.exportDir
                onCommitted: t => ClipboardConfig.scratchpad.exportDir = t.trim() || "~/Documents/Scratchpad"
            }
        }

        SettingsRow {
            label: "Notes"
            hint: `${Scratchpad.notes.length} tab${Scratchpad.notes.length === 1 ? "" : "s"} · saved in ${Settings.stateDir.replace(/^\/home\/[^/]+/, "~")}/scratchpad.json · Mod+Shift+N`
        }
    }
}
