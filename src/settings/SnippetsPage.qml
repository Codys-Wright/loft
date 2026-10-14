import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Snippets: the snippet editor. Each snippet has a trigger (what
// you type in the picker), a name and the text, with variables filled in when
// it's typed. Changes save as you leave a field. Data: services/Snippets.qml.
ColumnLayout {
    id: page
    spacing: 12

    SettingsCard {
        PageHeader {
            title: "Snippets"
            SettingsButton {
                text: "Open picker"
                onClicked: {
                    Panels.settingsOpen = false;
                    Snippets.pickerOpen = true;
                }
            }
            SettingsButton {
                primary: true
                text: "Add snippet"
                onClicked: Snippets.add()
            }
        }

        Text {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: "Mod+Shift+Period opens the picker: type a trigger (or search), Enter types the snippet into the app you were in. Variables: " + Snippets.variables.map(v => `{${v}}`).join("  ") + "  ·  {{ and }} for literal braces."
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 12
        }
    }

    // Keyed by count, not the array: saving one snippet must not rebuild
    // every card (and steal focus from the field being edited).
    Repeater {
        model: Snippets.items.length

        delegate: SettingsCard {
            id: card
            required property int index
            readonly property var snip: Snippets.items[index] ?? ({})
            Layout.fillWidth: true
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                SettingsTextField {
                    implicitWidth: 110
                    placeholder: ";trigger"
                    text: card.snip.trigger ?? ""
                    onCommitted: t => Snippets.update(card.snip.id, {
                            trigger: t.trim()
                        })
                }
                SettingsTextField {
                    Layout.fillWidth: true
                    placeholder: "Name"
                    text: card.snip.name ?? ""
                    onCommitted: t => Snippets.update(card.snip.id, {
                            name: t
                        })
                }
                SettingsButton {
                    text: "Delete"
                    onClicked: Snippets.remove(card.snip.id)
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.max(64, Math.min(220, body.implicitHeight + 16))
                radius: 8
                color: Theme.withAlpha(Theme.text, 0.06)
                border.width: 1
                border.color: body.activeFocus ? Theme.accent : Theme.withAlpha(Theme.text, 0.12)
                clip: true

                Flickable {
                    id: flick
                    anchors.fill: parent
                    anchors.margins: 8
                    contentHeight: body.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds

                    TextEdit {
                        id: body
                        width: flick.width
                        // Fill the box, so a click anywhere in it focuses the text.
                        height: Math.max(implicitHeight, flick.height)
                        color: Theme.text
                        selectionColor: Theme.withAlpha(Theme.accent, 0.5)
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        wrapMode: TextEdit.Wrap
                        selectByMouse: true
                        textFormat: TextEdit.PlainText
                        Component.onCompleted: text = card.snip.text ?? ""
                        onActiveFocusChanged: if (!activeFocus && text !== (card.snip.text ?? ""))
                            Snippets.update(card.snip.id, {
                                text: text
                            })

                        Text {
                            visible: body.text === "" && !body.activeFocus
                            text: "Snippet text — e.g. Hi {clipboard}, see you {weekday}."
                            color: Theme.withAlpha(Theme.subtext, 0.7)
                            font: body.font
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Repeater {
                    model: Snippets.variables
                    delegate: Rectangle {
                        required property string modelData
                        implicitWidth: varText.implicitWidth + 14
                        implicitHeight: 22
                        radius: 6
                        color: varMouse.containsMouse ? Theme.withAlpha(Theme.accent, 0.3) : Theme.withAlpha(Theme.accent, 0.14)
                        Text {
                            id: varText
                            anchors.centerIn: parent
                            text: `{${parent.modelData}}`
                            color: Theme.text
                            font.family: "monospace"
                            font.pixelSize: 11
                        }
                        MouseArea {
                            id: varMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            // Insert at the cursor (or the end) and save.
                            onClicked: {
                                const pos = body.activeFocus ? body.cursorPosition : body.length;
                                body.insert(pos, `{${parent.modelData}}`);
                                Snippets.update(card.snip.id, {
                                    text: body.text
                                });
                            }
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true
                }

                Text {
                    Layout.maximumWidth: 260
                    text: "→ " + Snippets.render(card.snip.text ?? "", "‹clipboard›").replace(/\s+/g, " ")
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }
            }
        }
    }
}
