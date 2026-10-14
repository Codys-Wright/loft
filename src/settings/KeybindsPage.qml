import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services

// Settings → Keybinds: every bind in the active niri config tree, grouped by
// the file it comes from (read-only). A key bound more than once is a
// conflict: the later definition wins (niri's include semantics), the
// earlier ones are dimmed with "overridden by …".
ColumnLayout {
    id: page
    spacing: 12

    property string query: ""
    property bool conflictsOnly: false


    readonly property var bd: NiriSettings.bindsData
    readonly property var conflictSet: new Set((bd.conflicts ?? []).map(c => c.toLowerCase()))

    readonly property var filtered: (bd.binds ?? []).filter(b => {
        if (conflictsOnly && !conflictSet.has(b.combo.toLowerCase()))
            return false;
        if (query === "")
            return true;
        const q = query.toLowerCase();
        return b.combo.toLowerCase().includes(q) || b.action_text.toLowerCase().includes(q) || (typeof b.title === "string" && b.title.toLowerCase().includes(q));
    })

    // [{ file, binds }] in config order.
    readonly property var groups: {
        const out = [];
        for (const b of filtered) {
            let g = out.find(g => g.file === b.file);
            if (!g) {
                g = { file: b.file, binds: [] };
                out.push(g);
            }
            g.binds.push(b);
        }
        return out;
    }

    function shortPath(p) {
        const home = Quickshell.env("HOME");
        let s = home && p.startsWith(home) ? "~" + p.slice(home.length) : p;
        // Store paths: keep the package name, drop the hash.
        s = s.replace(/^\/nix\/store\/[a-z0-9]{32}-/, "");
        return s;
    }

    function keyCap(part) {
        return ({
                Shift: "⇧",
                Ctrl: "⌃",
                Alt: "⌥",
                Super: "❖",
                Return: "↩",
                Tab: "⇥",
                BackSpace: "⌫",
                Delete: "⌦",
                Escape: "Esc",
                Left: "←",
                Right: "→",
                Up: "↑",
                Down: "↓",
                Slash: "/",
                Comma: ",",
                Period: ".",
                Minus: "−",
                Equal: "=",
                Semicolon: ";",
                Apostrophe: "'",
                Grave: "`",
                BracketLeft: "[",
                BracketRight: "]",
                Backslash: "\\"
            })[part] ?? part;
    }

    // Search + summary
    SettingsCard {
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            Icon {
                text: "󰍉"
                size: 14
                color: Theme.subtext
            }

            SettingsTextField {
                Layout.fillWidth: true
                placeholder: "Search keys, actions, titles"
                onEdited: t => page.query = t.trim()
            }

            SettingsSegmented {
                options: [
                    { value: false, label: "All" },
                    { value: true, label: `Conflicts (${(page.bd.conflicts ?? []).length})` }
                ]
                current: page.conflictsOnly
                onActivated: v => page.conflictsOnly = v
            }
        }

        Text {
            Layout.fillWidth: true
            text: `${(page.bd.binds ?? []).length} binds in ${(page.bd.files ?? []).length} files · ${NiriSettings.configPath !== "" ? page.shortPath(page.bd.config ?? NiriSettings.configPath) : "no config"} · read-only`
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            elide: Text.ElideMiddle
        }

        Repeater {
            model: page.bd.errors ?? []
            delegate: Text {
                required property string modelData
                Layout.fillWidth: true
                text: modelData
                color: Theme.warn
                font.family: Theme.fontUi
                font.pixelSize: 11
                wrapMode: Text.Wrap
            }
        }
    }

    Repeater {
        model: page.groups

        delegate: SettingsCard {
            id: group
            required property var modelData
            spacing: 2

            PageHeader {
                title: group.modelData.file.replace(/^.*\//, "")
                Text {
                    text: `${group.modelData.binds.length}`
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 12
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.bottomMargin: 6
                text: page.shortPath(group.modelData.file)
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 10
                elide: Text.ElideMiddle
            }

            Repeater {
                model: group.modelData.binds

                delegate: Rectangle {
                    id: bindRow
                    required property var modelData
                    readonly property bool conflict: page.conflictSet.has(modelData.combo.toLowerCase())
                    Layout.fillWidth: true
                    implicitHeight: rowLayout.implicitHeight + 10
                    radius: 8
                    color: conflict && !modelData.shadowed ? Theme.withAlpha(Theme.warn, 0.1) : rowHover.containsMouse ? Theme.withAlpha(Theme.text, 0.05) : "transparent"
                    opacity: modelData.shadowed ? 0.5 : 1

                    HoverHandler {
                        id: rowHover
                    }

                    Rectangle {
                        visible: bindRow.conflict
                        width: 3
                        radius: 1.5
                        anchors {
                            left: parent.left
                            top: parent.top
                            bottom: parent.bottom
                            margins: 4
                        }
                        color: Theme.warn
                    }

                    RowLayout {
                        id: rowLayout
                        anchors {
                            left: parent.left
                            right: parent.right
                            verticalCenter: parent.verticalCenter
                            leftMargin: 12
                            rightMargin: 8
                        }
                        spacing: 12

                        // Key caps
                        Row {
                            Layout.preferredWidth: 190
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 3

                            Repeater {
                                model: bindRow.modelData.modifiers.concat([bindRow.modelData.trigger])
                                delegate: Rectangle {
                                    required property string modelData
                                    width: Math.max(22, capText.implicitWidth + 10)
                                    height: 22
                                    radius: 5
                                    color: Theme.withAlpha(Theme.text, 0.1)
                                    border.width: 1
                                    border.color: Theme.withAlpha(Theme.text, 0.12)

                                    Text {
                                        id: capText
                                        anchors.centerIn: parent
                                        text: page.keyCap(parent.modelData)
                                        color: Theme.text
                                        font.family: Theme.fontUi
                                        font.pixelSize: 11
                                        font.weight: Font.Medium
                                    }
                                }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 1

                            Text {
                                Layout.fillWidth: true
                                visible: typeof bindRow.modelData.title === "string"
                                text: bindRow.modelData.title ?? ""
                                color: Theme.text
                                font.family: Theme.fontUi
                                font.pixelSize: 12
                                font.weight: Font.Medium
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                text: bindRow.modelData.action_text
                                color: typeof bindRow.modelData.title === "string" ? Theme.subtext : Theme.text
                                font.family: "monospace"
                                font.pixelSize: 11
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                visible: bindRow.modelData.shadowed
                                text: `overridden by ${(bindRow.modelData.shadowed_by ?? "").replace(/^.*\//, "")}`
                                color: Theme.warn
                                font.family: Theme.fontUi
                                font.pixelSize: 10
                                elide: Text.ElideMiddle
                            }
                        }

                        Text {
                            text: `:${bindRow.modelData.line}`
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 10
                            font.features: {
                                "tnum": 1
                            }
                        }
                    }
                }
            }
        }
    }

    Text {
        Layout.fillWidth: true
        Layout.topMargin: 20
        visible: page.groups.length === 0
        horizontalAlignment: Text.AlignHCenter
        text: (page.bd.binds ?? []).length === 0 ? "No binds found — is the niri config readable?" : "No binds match."
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 13
    }
}
