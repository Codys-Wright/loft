import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services
import "glyphs.js" as G

// Clipboard history (Mod+Shift+V): a glass panel on the focused screen with
// search, filters, pinned items first, text and image previews.
// Enter pastes into the app that was focused (Ctrl+Enter only copies),
// Ctrl+P pins, Shift+Delete deletes, Ctrl+L copies a cleaned link.
// Data and actions: services/Clipboard.qml.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property bool onThisScreen: (Niri.focusedWorkspace?.output ?? modelData.name) === modelData.name
    readonly property bool open: Clipboard.panelOpen && onThisScreen

    visible: open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "studio:clipboard"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    BackgroundEffect.blurRegion: Theme.blur && open ? blur : null
    Region {
        id: blur
        item: panel
        radius: panel.radius
    }

    property string query: ""
    property string filter: "all"
    property int current: 0

    readonly property var filters: [
        { value: "all", label: "All" },
        { value: "text", label: "Text" },
        { value: "image", label: "Images" },
        { value: "link", label: "Links" },
        { value: "pinned", label: "Pinned" }
    ]

    function isLink(text) {
        return /^\s*https?:\/\/\S+\s*$/i.test(text ?? "");
    }

    // One list: pins, then history. { key, pinned, pin|entry, text, image, link }
    readonly property var rows: {
        const q = query.trim().toLowerCase();
        const keep = r => (q === "" || r.text.toLowerCase().includes(q)) && (filter === "all" || filter === "pinned" ? true : filter === "image" ? r.image : filter === "link" ? r.link : !r.image && !r.link);
        const pins = Clipboard.pins.map(p => ({
                    key: "p" + p.id,
                    pinned: true,
                    pin: p,
                    text: p.kind === "image" ? (p.label ?? "Image") : p.text,
                    image: p.kind === "image",
                    link: p.kind === "text" && isLink(p.text)
                }));
        const history = filter === "pinned" ? [] : Clipboard.entries.map(e => ({
                    key: "h" + e.id,
                    pinned: false,
                    entry: e,
                    text: e.text,
                    image: e.image,
                    link: !e.image && isLink(e.text)
                }));
        return pins.concat(history).filter(keep);
    }
    readonly property var row: rows[Math.min(current, rows.length - 1)] ?? null

    // Keep the selection on the same item when the list changes under it
    // (a pin, a delete, a new copy arriving).
    property string selectedKey: ""
    onRowsChanged: {
        const i = rows.findIndex(r => r.key === selectedKey);
        current = i >= 0 ? i : Math.max(0, Math.min(current, rows.length - 1));
    }
    onRowChanged: {
        selectedKey = row?.key ?? "";
        if (row?.entry) {
            if (row.image)
                Clipboard.decodeImage(row.entry);
            else
                Clipboard.loadDetail(row.entry);
        }
    }

    onOpenChanged: {
        if (open) {
            query = "";
            current = 0;
            selectedKey = row?.key ?? "";
            search.text = "";
            search.forceActiveFocus();
        }
    }

    function close() {
        Clipboard.panelOpen = false;
    }

    function activate(r, pasteIt) {
        if (!r)
            return;
        const paste = pasteIt && ClipboardConfig.paste.onSelect;
        if (r.pinned) {
            if (paste)
                Clipboard.pastePin(r.pin);
            else
                Clipboard.copyPin(r.pin, () => close());
        } else {
            if (paste)
                Clipboard.paste(r.entry);
            else
                Clipboard.copy(r.entry, () => close());
        }
    }

    function togglePin(r) {
        if (!r)
            return;
        if (r.pinned)
            Clipboard.unpin(r.pin);
        else
            Clipboard.pin(r.entry);
    }

    function remove(r) {
        if (!r)
            return;
        if (r.pinned)
            Clipboard.unpin(r.pin);
        else
            Clipboard.remove(r.entry);
    }

    function fullText(r) {
        if (!r || r.image)
            return "";
        if (r.pinned)
            return r.pin.text;
        return Clipboard.detail?.id === r.entry.id ? Clipboard.detail.text : r.entry.text;
    }

    function imageSource(r) {
        if (!r?.image)
            return "";
        const p = r.pinned ? r.pin.path : Clipboard.images[r.entry.id] ?? "";
        return p ? "file://" + p : "";
    }

    // A pill action in the preview pane.
    component Action: Rectangle {
        id: act
        property string icon
        property string label
        property bool danger: false
        signal triggered
        width: actRow.implicitWidth + 16
        height: 26
        radius: 13
        color: actMouse.containsMouse ? Theme.withAlpha(danger ? Theme.urgent : Theme.text, 0.16) : Theme.withAlpha(Theme.text, 0.08)
        Row {
            id: actRow
            anchors.centerIn: parent
            spacing: 5
            Icon {
                text: act.icon
                size: 12
                color: act.danger && actMouse.containsMouse ? Theme.urgent : Theme.text
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                text: act.label
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 11
                anchors.verticalCenter: parent.verticalCenter
            }
        }
        MouseArea {
            id: actMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: act.triggered()
        }
    }

    // Click outside the panel closes it.
    MouseArea {
        anchors.fill: parent
        onClicked: root.close()
    }

    GlassSurface {
        id: panel
        width: Math.min(820, parent.width - 80)
        height: Math.min(520, parent.height - 160)
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(parent.height * 0.42 - height / 2)
        radius: 26
        strength: 1.6

        // Swallow clicks so they don't reach the close area.
        MouseArea {
            anchors.fill: parent
        }

        ColumnLayout {
            anchors {
                fill: parent
                margins: 14
            }
            spacing: 10

            // Search
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 6
                spacing: 10

                Icon {
                    text: G.search
                    size: 20
                    color: Theme.subtext
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
                        text: "Search clipboard history"
                        color: Theme.withAlpha(Theme.subtext, 0.7)
                        font: search.font
                    }

                    Keys.onPressed: event => {
                        const ctrl = event.modifiers & Qt.ControlModifier;
                        const shift = event.modifiers & Qt.ShiftModifier;
                        if (event.key === Qt.Key_Escape) {
                            root.close();
                        } else if (event.key === Qt.Key_Down || (ctrl && event.key === Qt.Key_N)) {
                            root.current = Math.min(root.rows.length - 1, root.current + 1);
                        } else if (event.key === Qt.Key_Up || (ctrl && event.key === Qt.Key_K)) {
                            root.current = Math.max(0, root.current - 1);
                        } else if (event.key === Qt.Key_PageDown) {
                            root.current = Math.min(root.rows.length - 1, root.current + 8);
                        } else if (event.key === Qt.Key_PageUp) {
                            root.current = Math.max(0, root.current - 8);
                        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            root.activate(root.row, !ctrl);
                        } else if (ctrl && event.key === Qt.Key_P) {
                            root.togglePin(root.row);
                        } else if (ctrl && event.key === Qt.Key_L && root.row && !root.row.pinned) {
                            Clipboard.cleanEntry(root.row.entry);
                        } else if (shift && event.key === Qt.Key_Delete) {
                            root.remove(root.row);
                        } else if (event.key === Qt.Key_Tab) {
                            const i = root.filters.findIndex(f => f.value === root.filter);
                            root.filter = root.filters[(i + (shift ? root.filters.length - 1 : 1)) % root.filters.length].value;
                            root.current = 0;
                        } else {
                            return;
                        }
                        event.accepted = true;
                    }
                }

                // Filters
                Row {
                    spacing: 2
                    Repeater {
                        model: root.filters
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool selected: root.filter === modelData.value
                            width: chip.implicitWidth + 18
                            height: 26
                            radius: 13
                            color: selected ? Theme.accent : chipMouse.containsMouse ? Theme.withAlpha(Theme.text, 0.1) : "transparent"

                            Text {
                                id: chip
                                anchors.centerIn: parent
                                text: modelData.label
                                color: parent.selected ? Theme.bg : Theme.subtext
                                font.family: Theme.fontUi
                                font.pixelSize: 12
                                font.weight: parent.selected ? Font.DemiBold : Font.Normal
                            }
                            MouseArea {
                                id: chipMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.filter = modelData.value;
                                    root.current = 0;
                                    search.forceActiveFocus();
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 1
                color: Theme.glassBorder
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 12

                // List
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    Text {
                        anchors.centerIn: parent
                        visible: root.rows.length === 0
                        horizontalAlignment: Text.AlignHCenter
                        text: Clipboard.loading ? "Loading…" : root.query !== "" ? "No matches" : "Nothing copied yet"
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                    }

                    ListView {
                        id: list
                        anchors.fill: parent
                        clip: true
                        model: root.rows
                        currentIndex: root.current
                        highlightMoveDuration: 0
                        boundsBehavior: Flickable.StopAtBounds
                        spacing: 2

                        delegate: Item {
                            id: rowItem
                            required property var modelData
                            required property int index
                            readonly property bool selected: index === root.current
                            readonly property bool header: index === 0 || root.rows[index - 1].pinned !== modelData.pinned
                            width: ListView.view.width
                            height: 44 + (header ? 24 : 0)

                            Text {
                                visible: rowItem.header
                                x: 10
                                height: 24
                                verticalAlignment: Text.AlignVCenter
                                text: rowItem.modelData.pinned ? "PINNED" : "HISTORY"
                                color: Theme.subtext
                                font.family: Theme.fontUi
                                font.pixelSize: 10
                                font.weight: Font.DemiBold
                                font.letterSpacing: 1
                            }

                            Rectangle {
                                id: bg
                                anchors {
                                    left: parent.left
                                    right: parent.right
                                    bottom: parent.bottom
                                }
                                height: 44
                                radius: 12
                                color: rowItem.selected ? Theme.withAlpha(Theme.accent, 0.28) : rowMouse.containsMouse ? Theme.withAlpha(Theme.text, 0.07) : "transparent"

                                MouseArea {
                                    id: rowMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.current = rowItem.index;
                                        root.activate(rowItem.modelData, true);
                                    }
                                    onPositionChanged: root.current = rowItem.index
                                }

                                RowLayout {
                                    anchors {
                                        fill: parent
                                        leftMargin: 8
                                        rightMargin: 8
                                    }
                                    spacing: 10

                                    // Kind icon or image thumbnail
                                    Rectangle {
                                        Layout.preferredWidth: 30
                                        Layout.preferredHeight: 30
                                        radius: 8
                                        color: Theme.withAlpha(Theme.text, 0.08)
                                        clip: true

                                        Icon {
                                            anchors.centerIn: parent
                                            visible: thumb.status !== Image.Ready
                                            text: rowItem.modelData.image ? G.image : rowItem.modelData.link ? G.link : G.text
                                            size: 15
                                            color: rowItem.modelData.link ? Theme.accent : Theme.subtext
                                        }

                                        Image {
                                            id: thumb
                                            anchors.fill: parent
                                            source: root.imageSource(rowItem.modelData)
                                            sourceSize: Qt.size(60, 60)
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                            Component.onCompleted: if (rowItem.modelData.image && !rowItem.modelData.pinned)
                                                Clipboard.decodeImage(rowItem.modelData.entry)
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: rowItem.modelData.text.replace(/\s+/g, " ").trim()
                                        color: Theme.text
                                        font.family: Theme.fontUi
                                        font.pixelSize: 13
                                        elide: Text.ElideRight
                                        maximumLineCount: 1
                                    }

                                    Icon {
                                        visible: rowItem.modelData.pinned || rowMouse.containsMouse || pinMouse.containsMouse
                                        text: rowItem.modelData.pinned ? G.pin : G.pinOff
                                        size: 15
                                        color: rowItem.modelData.pinned ? Theme.accent : Theme.subtext
                                        MouseArea {
                                            id: pinMouse
                                            anchors.fill: parent
                                            anchors.margins: -5
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.togglePin(rowItem.modelData)
                                        }
                                    }

                                    Icon {
                                        visible: rowMouse.containsMouse || delMouse.containsMouse
                                        text: G.trash
                                        size: 15
                                        color: delMouse.containsMouse ? Theme.urgent : Theme.subtext
                                        MouseArea {
                                            id: delMouse
                                            anchors.fill: parent
                                            anchors.margins: -5
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.remove(rowItem.modelData)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Preview
                Rectangle {
                    Layout.preferredWidth: 300
                    Layout.fillHeight: true
                    radius: 16
                    color: Theme.withAlpha(Theme.text, 0.05)
                    border.width: 1
                    border.color: Theme.withAlpha(Theme.text, 0.06)
                    visible: root.row !== null

                    ColumnLayout {
                        anchors {
                            fill: parent
                            margins: 12
                        }
                        spacing: 10

                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true

                            Image {
                                anchors.fill: parent
                                visible: root.row?.image ?? false
                                source: root.imageSource(root.row)
                                sourceSize: Qt.size(600, 600)
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                            }

                            Flickable {
                                anchors.fill: parent
                                visible: !(root.row?.image ?? true)
                                contentHeight: body.implicitHeight
                                boundsBehavior: Flickable.StopAtBounds
                                clip: true

                                Text {
                                    id: body
                                    width: parent.width
                                    text: root.fullText(root.row).slice(0, 20000)
                                    color: Theme.text
                                    font.family: Theme.fontUi
                                    font.pixelSize: 12
                                    wrapMode: Text.WrapAnywhere
                                    textFormat: Text.PlainText
                                }
                            }
                        }

                        Text {
                            Layout.fillWidth: true
                            text: {
                                const r = root.row;
                                if (!r)
                                    return "";
                                if (r.image)
                                    return r.pinned ? "Pinned image" : r.text;
                                const t = root.fullText(r);
                                const lines = t.replace(/\n+$/, "").split("\n").length;
                                return `${r.link ? "Link" : "Text"} · ${t.length} characters${lines > 1 ? ` · ${lines} lines` : ""}`;
                            }
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }

                        Flow {
                            Layout.fillWidth: true
                            spacing: 6

                            Action {
                                icon: G.paste
                                label: "Paste"
                                onTriggered: root.activate(root.row, true)
                            }
                            Action {
                                icon: G.copy
                                label: "Copy"
                                onTriggered: root.activate(root.row, false)
                            }
                            Action {
                                icon: root.row?.pinned ? G.pinOff : G.pin
                                label: root.row?.pinned ? "Unpin" : "Pin"
                                onTriggered: root.togglePin(root.row)
                            }
                            Action {
                                visible: !!root.row && !root.row.pinned && root.row.link && Clipboard.isTrackedUrl(root.fullText(root.row))
                                icon: G.broom
                                label: "Clean link"
                                onTriggered: Clipboard.cleanEntry(root.row.entry)
                            }
                            Action {
                                icon: G.trash
                                label: "Delete"
                                danger: true
                                onTriggered: root.remove(root.row)
                            }
                        }
                    }
                }
            }

            // Footer
            RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 6
                Layout.rightMargin: 6
                spacing: 12

                Text {
                    Layout.fillWidth: true
                    text: Clipboard.toast !== "" ? Clipboard.toast : "↵ paste   ⌃↵ copy   ⌃P pin   ⌃L clean link   ⇧⌦ delete   ⇥ filter"
                    color: Clipboard.toast !== "" ? Theme.accent : Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    elide: Text.ElideRight
                }

                Text {
                    text: `${Clipboard.entries.length} items`
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                }

                Text {
                    id: clearLink
                    property bool armed: false
                    text: armed ? "Click again to clear" : "Clear history"
                    color: armed || clearMouse.containsMouse ? Theme.urgent : Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    MouseArea {
                        id: clearMouse
                        anchors.fill: parent
                        anchors.margins: -4
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (clearLink.armed)
                                Clipboard.wipe();
                            clearLink.armed = !clearLink.armed;
                        }
                    }
                    Timer {
                        running: clearLink.armed
                        interval: 3000
                        onTriggered: clearLink.armed = false
                    }
                }
            }
        }
    }

    Timer {
        running: Clipboard.toast !== ""
        interval: 2200
        onTriggered: Clipboard.toast = ""
    }
}
