import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services
import "glyphs.js" as G

// Scratchpad (Mod+Shift+N): tabbed Markdown notes in a floating glass
// window, autosaved as you type. Ctrl+N new tab, Ctrl+W close tab,
// Ctrl+Tab next tab, Ctrl+E preview, Ctrl+S export to the export folder
// (Settings → Clipboard & Files), Escape hides. niri floats it by title
// (niri/base.kdl). Data: services/Scratchpad.qml.
FloatingWindow {
    id: window

    visible: Scratchpad.open
    title: "Loft Scratchpad"
    implicitWidth: 680
    implicitHeight: 540
    color: "transparent"
    onVisibleChanged: {
        if (!visible) {
            Scratchpad.open = false;
            Scratchpad.flush();
        } else {
            editor.forceActiveFocus();
        }
    }

    property bool preview: false

    BackgroundEffect.blurRegion: Theme.blur ? blur : null
    Region {
        id: blur
        item: frame
        radius: frame.radius
    }

    // Keep the editor and the current note in sync without feedback loops.
    property bool syncing: false
    function load() {
        const t = Scratchpad.note?.text ?? "";
        if (editor.text === t)
            return;
        syncing = true;
        editor.text = t;
        syncing = false;
    }
    Connections {
        target: Scratchpad
        function onNoteChanged() {
            if (!editor.activeFocus || Scratchpad.note?.text !== editor.text)
                window.load();
        }
    }
    Component.onCompleted: load()

    Shortcut {
        sequence: "Ctrl+N"
        onActivated: Scratchpad.newNote()
    }
    Shortcut {
        sequence: "Ctrl+W"
        onActivated: Scratchpad.closeNote(Scratchpad.current)
    }
    Shortcut {
        sequence: "Ctrl+Tab"
        onActivated: Scratchpad.select((Scratchpad.current + 1) % Scratchpad.notes.length)
    }
    Shortcut {
        sequence: "Ctrl+Shift+Tab"
        onActivated: Scratchpad.select((Scratchpad.current - 1 + Scratchpad.notes.length) % Scratchpad.notes.length)
    }
    Shortcut {
        sequence: "Ctrl+E"
        onActivated: window.preview = !window.preview
    }
    Shortcut {
        sequence: "Ctrl+S"
        onActivated: Scratchpad.exportNote(null)
    }
    Shortcut {
        sequence: "Escape"
        onActivated: Scratchpad.open = false
    }

    component ToolButton: Rectangle {
        id: tb
        property string icon
        property string label
        property bool active: false
        signal clicked
        implicitWidth: tbRow.implicitWidth + 16
        implicitHeight: 28
        radius: 14
        color: active ? Theme.accent : tbMouse.containsMouse ? Theme.withAlpha(Theme.text, 0.14) : Theme.withAlpha(Theme.text, 0.07)
        Row {
            id: tbRow
            anchors.centerIn: parent
            spacing: 5
            Icon {
                text: tb.icon
                size: 13
                color: tb.active ? Theme.bg : Theme.text
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                visible: tb.label !== ""
                text: tb.label
                color: tb.active ? Theme.bg : Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 11
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        MouseArea {
            id: tbMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tb.clicked()
        }
    }

    // Active = niri's focused window is this one (the glass dims, the
    // traffic lights turn grey otherwise).
    readonly property bool focusedHere: !Niri.available || (Niri.focusedWindow?.title === window.title)

    GlassSurface {
        id: frame
        anchors.fill: parent
        radius: window.fullscreen ? 0 : Theme.windowRadius
        strength: 1.8
        active: window.focusedHere

        ColumnLayout {
            anchors {
                fill: parent
                margins: 12
            }
            spacing: 10

            // Tabs + tools
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                TrafficLights {
                    Layout.leftMargin: 6
                    Layout.rightMargin: 6
                    active: window.focusedHere
                    onClose: Scratchpad.open = false
                    onHide: Scratchpad.open = false
                    onFullscreen: window.fullscreen = !window.fullscreen
                }

                Flickable {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 30
                    contentWidth: tabs.implicitWidth
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Row {
                        id: tabs
                        spacing: 4

                        Repeater {
                            model: Scratchpad.notes
                            delegate: Rectangle {
                                id: tab
                                required property var modelData
                                required property int index
                                readonly property bool current: index === Scratchpad.current
                                width: Math.min(180, tabRow.implicitWidth + 22)
                                height: 30
                                radius: 10
                                color: current ? Theme.withAlpha(Theme.text, 0.14) : tabMouse.containsMouse ? Theme.withAlpha(Theme.text, 0.07) : "transparent"

                                MouseArea {
                                    id: tabMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: mouse => mouse.button === Qt.MiddleButton ? Scratchpad.closeNote(tab.index) : Scratchpad.select(tab.index)
                                }

                                Row {
                                    id: tabRow
                                    anchors.centerIn: parent
                                    spacing: 6
                                    Text {
                                        width: Math.min(implicitWidth, 130)
                                        text: Scratchpad.titleOf(tab.modelData)
                                        color: tab.current ? Theme.text : Theme.subtext
                                        font.family: Theme.fontUi
                                        font.pixelSize: 12
                                        font.weight: tab.current ? Font.DemiBold : Font.Normal
                                        elide: Text.ElideRight
                                        anchors.verticalCenter: parent.verticalCenter
                                    }
                                    Icon {
                                        visible: Scratchpad.notes.length > 1 && (tab.current || tabMouse.containsMouse || closeMouse.containsMouse)
                                        text: G.close
                                        size: 11
                                        color: closeMouse.containsMouse ? Theme.urgent : Theme.subtext
                                        anchors.verticalCenter: parent.verticalCenter
                                        MouseArea {
                                            id: closeMouse
                                            anchors.fill: parent
                                            anchors.margins: -4
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: Scratchpad.closeNote(tab.index)
                                        }
                                    }
                                }
                            }
                        }

                        Rectangle {
                            width: 30
                            height: 30
                            radius: 10
                            color: plusMouse.containsMouse ? Theme.withAlpha(Theme.text, 0.1) : "transparent"
                            Icon {
                                anchors.centerIn: parent
                                text: G.plus
                                size: 15
                                color: Theme.subtext
                            }
                            MouseArea {
                                id: plusMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Scratchpad.newNote()
                            }
                        }
                    }
                }

                ToolButton {
                    icon: window.preview ? G.pencil : G.eye
                    label: window.preview ? "Edit" : "Preview"
                    active: window.preview
                    onClicked: window.preview = !window.preview
                }
                ToolButton {
                    icon: G.copy
                    onClicked: {
                        Clipboard.copyText(Scratchpad.note?.text ?? "");
                        Scratchpad.toast = "Copied as Markdown";
                    }
                }
                ToolButton {
                    icon: G.exportIcon
                    label: "Export"
                    onClicked: Scratchpad.exportNote(null)
                }
            }

            // Page
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: 16
                color: Theme.withAlpha(Theme.bg, 0.25)
                border.width: 1
                border.color: Theme.withAlpha(Theme.text, 0.06)

                Flickable {
                    id: editFlick
                    anchors.fill: parent
                    anchors.margins: 16
                    visible: !window.preview
                    contentHeight: editor.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    // Keep the cursor in view while typing.
                    function ensureVisible(r) {
                        if (contentY >= r.y)
                            contentY = r.y;
                        else if (contentY + height <= r.y + r.height)
                            contentY = r.y + r.height - height;
                    }

                    TextEdit {
                        id: editor
                        width: editFlick.width
                        height: Math.max(implicitHeight, editFlick.height)
                        color: Theme.text
                        selectionColor: Theme.withAlpha(Theme.accent, 0.45)
                        selectedTextColor: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 14
                        wrapMode: TextEdit.Wrap
                        selectByMouse: true
                        persistentSelection: true
                        textFormat: TextEdit.PlainText
                        tabStopDistance: 28
                        onTextChanged: if (!window.syncing)
                            Scratchpad.setText(text)
                        onCursorRectangleChanged: editFlick.ensureVisible(cursorRectangle)

                        Text {
                            visible: editor.text === ""
                            text: "# Title\n\nJot something down — Markdown works, Ctrl+E previews."
                            color: Theme.withAlpha(Theme.subtext, 0.6)
                            font: editor.font
                        }
                    }
                }

                Flickable {
                    id: previewFlick
                    anchors.fill: parent
                    anchors.margins: 16
                    visible: window.preview
                    contentHeight: rendered.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Text {
                        id: rendered
                        width: previewFlick.width
                        text: Scratchpad.note?.text ?? ""
                        textFormat: Text.MarkdownText
                        color: Theme.text
                        linkColor: Theme.accent
                        font.family: Theme.fontUi
                        font.pixelSize: 14
                        wrapMode: Text.Wrap
                        onLinkActivated: link => Qt.openUrlExternally(link)
                    }
                }
            }

            // Status
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 6
                Layout.rightMargin: 6

                Text {
                    Layout.fillWidth: true
                    text: Scratchpad.toast !== "" ? Scratchpad.toast : "Saved automatically · ⌃N new · ⌃W close · ⌃E preview · ⌃S export"
                    color: Scratchpad.toast !== "" ? Theme.accent : Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    elide: Text.ElideMiddle
                }
                Text {
                    readonly property string t: Scratchpad.note?.text ?? ""
                    text: {
                        const words = t.trim() === "" ? 0 : t.trim().split(/\s+/).length;
                        return `${words} words · ${t.length} characters`;
                    }
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                }
            }
        }
    }

    Timer {
        running: Scratchpad.toast !== ""
        interval: 2500
        onTriggered: Scratchpad.toast = ""
    }
}
