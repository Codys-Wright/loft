import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services
import "glyphs.js" as G

// Snippet picker (Mod+Shift+Period): search by trigger, name or text; Enter
// types the expansion into the app that was focused. Snippets are edited in
// Settings → Snippets. Data and expansion: services/Snippets.qml.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property bool onThisScreen: (Niri.focusedWorkspace?.output ?? modelData.name) === modelData.name
    readonly property bool open: Snippets.pickerOpen && onThisScreen

    visible: open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:snippets"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur && open ? panel : null
        radius: panel.radius
    }

    property string query: ""
    property int current: 0
    readonly property var rows: Snippets.search(query)
    readonly property var row: rows[Math.min(current, rows.length - 1)] ?? null

    onRowsChanged: if (current >= rows.length)
        current = Math.max(0, rows.length - 1)

    onOpenChanged: {
        if (open) {
            query = "";
            current = 0;
            search.text = "";
            search.forceActiveFocus();
        }
    }

    function close() {
        Snippets.pickerOpen = false;
    }

    function edit() {
        close();
        Panels.settingsSection = "snippets";
        Panels.settingsOpen = true;
    }

    MouseArea {
        anchors.fill: parent
        onClicked: root.close()
    }

    GlassSurface {
        id: panel
        width: Math.min(620, parent.width - 80)
        height: Math.min(420, parent.height - 160)
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(parent.height * 0.4 - height / 2)
        radius: Theme.panelRadius + 8
        strength: 1.6

        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            anchors {
                fill: parent
                margins: 14
            }
            spacing: 10

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 6
                spacing: 10

                Icon {
                    text: G.snippet
                    size: 20
                    color: Theme.accent
                }

                TextInput {
                    id: search
                    Layout.fillWidth: true
                    color: Theme.text
                    selectionColor: Theme.withAlpha(Theme.accent, 0.5)
                    font.family: Theme.fontUi
                    font.pixelSize: 20
                    clip: true
                    onTextEdited: {
                        root.query = text;
                        root.current = 0;
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: search.text === ""
                        text: "Type a trigger or search snippets"
                        color: Theme.withAlpha(Theme.subtext, 0.7)
                        font: search.font
                    }

                    Keys.onPressed: event => {
                        const ctrl = event.modifiers & Qt.ControlModifier;
                        if (event.key === Qt.Key_Escape)
                            root.close();
                        else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_N))
                            root.current = Math.min(root.rows.length - 1, root.current + 1);
                        else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K))
                            root.current = Math.max(0, root.current - 1);
                        else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.row)
                            Snippets.expand(root.row);
                        else if (ctrl && event.key === Qt.Key_E)
                            root.edit();
                        else
                            return;
                        event.accepted = true;
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.glassBorder
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                Text {
                    anchors.centerIn: parent
                    visible: root.rows.length === 0
                    horizontalAlignment: Text.AlignHCenter
                    text: Snippets.items.length === 0 ? "No snippets yet — add some in Settings → Snippets" : "No matches"
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 13
                }

                ListView {
                    anchors.fill: parent
                    clip: true
                    model: root.rows
                    currentIndex: root.current
                    highlightMoveDuration: 0
                    boundsBehavior: Flickable.StopAtBounds
                    spacing: 2

                    delegate: Rectangle {
                        id: item
                        required property var modelData
                        required property int index
                        readonly property bool selected: index === root.current
                        width: ListView.view.width
                        height: 54
                        radius: 12
                        color: selected ? Theme.withAlpha(Theme.accent, 0.28) : mouse.containsMouse ? Theme.withAlpha(Theme.text, 0.07) : "transparent"

                        MouseArea {
                            id: mouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onPositionChanged: root.current = item.index
                            onClicked: Snippets.expand(item.modelData)
                        }

                        RowLayout {
                            anchors {
                                fill: parent
                                leftMargin: 12
                                rightMargin: 12
                            }
                            spacing: 12

                            Rectangle {
                                opacity: (item.modelData.trigger ?? "") !== "" ? 1 : 0
                                Layout.preferredWidth: Math.max(76, trig.implicitWidth + 14)
                                Layout.preferredHeight: 22
                                radius: 6
                                color: Theme.withAlpha(Theme.accent, item.selected ? 0.35 : 0.18)
                                Text {
                                    id: trig
                                    anchors.centerIn: parent
                                    text: item.modelData.trigger ?? ""
                                    color: Theme.text
                                    font.family: "monospace"
                                    font.pixelSize: 12
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                Text {
                                    Layout.fillWidth: true
                                    text: item.modelData.name || "Untitled"
                                    color: Theme.text
                                    font.family: Theme.fontUi
                                    font.pixelSize: 13
                                    font.weight: Font.Medium
                                    elide: Text.ElideRight
                                }
                                Text {
                                    Layout.fillWidth: true
                                    // Variables shown as-is: {clipboard} is filled at expansion.
                                    text: (item.modelData.text ?? "").replace(/\s+/g, " ").trim() || "(empty)"
                                    color: Theme.subtext
                                    font.family: Theme.fontUi
                                    font.pixelSize: 11
                                    elide: Text.ElideRight
                                }
                            }
                        }
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 6
                Layout.rightMargin: 6

                Text {
                    Layout.fillWidth: true
                    text: "↵ type into the focused app   ⌃E edit snippets"
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                }

                Text {
                    text: "Edit snippets…"
                    color: Theme.accent
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.edit()
                    }
                }
            }
        }
    }
}
