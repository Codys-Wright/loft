import QtQuick
import QtQuick.Layouts
import qs.components
import qs.palette
import qs.services

// Settings → Quick Panel: the ⌃⌘V palette (palette/QuickPanel.qml) — its
// tools (any action of the catalog, dragged into order), its size and where
// it opens, and how much clipboard history and snippets it shows.
ColumnLayout {
    id: page
    spacing: 12

    property bool adding: false

    SettingsCard {
        SettingsRow {
            label: "Quick panel"
            hint: "⌃⌘V (Mod+Ctrl+V) opens a palette of your tools at the pointer"
            SettingsSwitch {
                checked: Features.on("quickPanel")
                onToggled: on => Features.set("quickPanel", on)
            }
        }

        SettingsRow {
            label: "Preview"
            hint: "Opens it in the middle of this display (Esc closes)"
            SettingsButton {
                text: "Show Quick Panel"
                enabled: Features.on("quickPanel")
                onClicked: QuickPanel.show(Niri.focusedWorkspace?.output ?? "")
            }
        }

        SettingsRow {
            label: "Size"
            hint: `${QuickPanel.columns} tools per row`
            SettingsSegmented {
                options: [
                    { value: "small", label: "Small" },
                    { value: "medium", label: "Medium" },
                    { value: "large", label: "Large" }
                ]
                current: QuickPanel.size
                onActivated: v => QuickPanel.setOption("size", v)
            }
        }

        SettingsRow {
            label: "Opens"
            SettingsSegmented {
                options: [
                    { value: "pointer", label: "At the pointer" },
                    { value: "center", label: "Centered" }
                ]
                current: QuickPanel.cfg.position
                onActivated: v => QuickPanel.setOption("position", v)
            }
        }

        SettingsRow {
            label: "Clipboard entries"
            hint: Features.on("clipboard") ? "The latest items of the clipboard history; Enter pastes" : "Clipboard history is off (Features)"
            enabled: Features.on("clipboard")
            SettingsSlider {
                from: 0
                to: 10
                step: 1
                value: QuickPanel.cfg.clipboard ?? 5
                format: v => v === 0 ? "Off" : String(Math.round(v))
                onCommitted: v => QuickPanel.setOption("clipboard", Math.round(v))
            }
        }

        SettingsRow {
            label: "Snippets"
            hint: Features.on("snippets") ? "Your snippets under the tools (typing filters them)" : "Text snippets are off (Features)"
            enabled: Features.on("snippets")
            SettingsSwitch {
                checked: QuickPanel.cfg.snippets !== false
                onToggled: on => QuickPanel.setOption("snippets", on)
            }
        }
    }

    SettingsCard {
        spacing: 4

        PageHeader {
            Layout.bottomMargin: 6
            title: "Tools"
            SettingsButton {
                text: "Reset"
                onClicked: QuickPanel.reset()
            }
            SettingsButton {
                text: page.adding ? "Close" : "Add…"
                primary: !page.adding
                onClicked: {
                    page.adding = !page.adding;
                    if (page.adding)
                        picker.focusSearch();
                }
            }
        }

        ActionPicker {
            id: picker
            Layout.fillWidth: true
            Layout.bottomMargin: 8
            visible: page.adding
            exclude: QuickPanel.favorites
            onPicked: id => QuickPanel.add(id)
            onCanceled: page.adding = false
        }

        Text {
            Layout.fillWidth: true
            visible: QuickPanel.favorites.length === 0
            text: "No tools yet — Add… picks any control, capture mode, window action, app or snippet."
            color: Theme.subtext
            wrapMode: Text.Wrap
            font.family: Theme.fontUi
            font.pixelSize: 12
        }

        ActionList {
            Layout.fillWidth: true
            items: QuickPanel.favorites.map(id => {
                const e = Actions.entry(id);
                const ok = Actions.available(id);
                return {
                    icon: Actions.icon(id),
                    label: e?.label ?? id,
                    sub: ok ? (e?.group ?? "") : "Not shown: its module is off (Features)",
                    warn: !ok,
                    badge: Actions.badge(e?.group),
                    appId: e?.kind === "app" ? e.appId : ""
                };
            })
            onMoved: (from, to) => QuickPanel.move(QuickPanel.favorites[from], to)
            onRemoved: i => QuickPanel.remove(QuickPanel.favorites[i])
        }
    }
}
