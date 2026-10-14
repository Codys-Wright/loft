import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.components
import qs.services

// Messages: the iPhone's SMS / iMessage conversations through tetherd
// (Phone.qml), a glass panel on the focused screen like macOS's Messages
// window: conversations on the left, the thread and a reply box on the
// right. Opens from Spotlight ("Messages"), the Control Center's iPhone tile,
// a message banner's Reply and the island; Esc or a click outside closes it.
// Enter sends, Ctrl+N starts a new message.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property bool onThisScreen: (Niri.focusedWorkspace?.output ?? modelData.name) === modelData.name
    readonly property bool open: Phone.panelOpen && onThisScreen

    visible: open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:messages"
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
        item: Theme.blur && root.open ? panel : null
        radius: panel.radius
    }

    readonly property color blue: "#0a84ff"
    readonly property color green: "#34c759"

    property string query: ""
    readonly property var rows: {
        const q = query.trim().toLowerCase();
        return Phone.threads.filter(t => q === "" || Phone.threadTitle(t).toLowerCase().includes(q) || String(t.address ?? "").toLowerCase().includes(q) || String(t.preview ?? "").toLowerCase().includes(q));
    }
    readonly property var current: Phone.thread(Phone.currentThread)
    readonly property var messages: Phone.messagesFor(Phone.currentThread)
    readonly property bool canReply: Phone.connected && (Phone.composing ? to.text.trim() !== "" : current !== null && current.repliable !== false)

    function close() {
        Phone.panelOpen = false;
    }

    function sendNow() {
        const body = reply.text;
        if (body.trim() === "" || !root.canReply)
            return;
        const key = Phone.send(Phone.composing ? to.text : Phone.currentThread, body);
        if (key === "")
            return;
        reply.text = "";
        if (Phone.composing)
            Phone.openThread(key);
    }

    function focusReply() {
        if (Phone.composing)
            to.forceActiveFocus();
        else
            reply.forceActiveFocus();
    }

    onOpenChanged: if (open) {
        query = "";
        search.text = "";
        Qt.callLater(focusReply);
    }
    Connections {
        target: Phone
        function onFocusReplyChanged() {
            Qt.callLater(root.focusReply);
        }
        function onComposingChanged() {
            Qt.callLater(root.focusReply);
        }
    }

    // A first letter in a disc, or a person glyph.
    component Avatar: Rectangle {
        id: av
        property string name
        property real size: 38
        implicitWidth: size
        implicitHeight: size
        radius: size / 2
        gradient: Gradient {
            GradientStop {
                position: 0
                color: "#a5abb8"
            }
            GradientStop {
                position: 1
                color: "#858a96"
            }
        }
        readonly property string initial: /^[A-Za-z]/.test(name) ? name[0].toUpperCase() : ""
        Text {
            anchors.centerIn: parent
            visible: av.initial !== ""
            text: av.initial
            color: "white"
            font.family: Theme.fontUi
            font.pixelSize: av.size * 0.42
            font.weight: Font.DemiBold
        }
        Icon {
            anchors.centerIn: parent
            visible: av.initial === ""
            text: "󰀉"
            size: av.size * 0.6
            color: "white"
        }
    }

    component RoundButton: Rectangle {
        id: rb
        property string glyph
        property color tint: Theme.text
        property bool filled: false
        signal clicked
        implicitWidth: 30
        implicitHeight: 30
        radius: 15
        color: filled ? (rbMouse.containsMouse ? Qt.lighter(tint, 1.1) : tint) : rbMouse.containsMouse ? Theme.withAlpha(Theme.text, 0.12) : "transparent"
        opacity: enabled ? 1 : 0.4
        Icon {
            anchors.centerIn: parent
            text: rb.glyph
            size: 16
            color: rb.filled ? "white" : rb.tint
        }
        MouseArea {
            id: rbMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: rb.clicked()
        }
    }

    // Click outside the panel closes it.
    MouseArea {
        anchors.fill: parent
        onClicked: root.close()
    }

    GlassSurface {
        id: panel
        width: Math.min(900, parent.width - 80)
        height: Math.min(600, parent.height - 140)
        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.round(parent.height * 0.45 - height / 2)
        radius: Theme.panelRadius + 8
        strength: 1.6

        MouseArea {
            anchors.fill: parent
        }

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) {
                root.close();
                event.accepted = true;
            } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_N) {
                Phone.compose();
                event.accepted = true;
            }
        }

        RowLayout {
            anchors.fill: parent
            spacing: 0

            // ── Conversations ───────────────────────────────────────────
            ColumnLayout {
                Layout.preferredWidth: 290
                Layout.maximumWidth: 290
                Layout.fillWidth: false
                Layout.fillHeight: true
                Layout.margins: 12
                Layout.rightMargin: 8
                spacing: 10

                RowLayout {
                    Layout.fillWidth: true
                    Layout.leftMargin: 4
                    Layout.topMargin: 2
                    spacing: 8
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Text {
                            text: "Messages"
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 17
                            font.weight: Font.Bold
                        }
                        RowLayout {
                            spacing: 5
                            Rectangle {
                                implicitWidth: 7
                                implicitHeight: 7
                                radius: 3.5
                                color: Phone.connected ? root.green : Phone.link === "offline" ? Theme.urgent : Theme.warn
                            }
                            Text {
                                Layout.fillWidth: true
                                text: Phone.connected ? Phone.deviceName : Phone.statusLine
                                color: Theme.subtext
                                font.family: Theme.fontUi
                                font.pixelSize: 11
                                elide: Text.ElideRight
                            }
                        }
                    }
                    RoundButton {
                        glyph: "󰏫"
                        tint: Theme.accent
                        enabled: Phone.connected
                        onClicked: Phone.compose()
                    }
                }

                // Search
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 30
                    radius: 9
                    color: Theme.withAlpha(Theme.text, 0.07)
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 9
                        anchors.rightMargin: 9
                        spacing: 6
                        Icon {
                            text: "󰍉"
                            size: 14
                            color: Theme.subtext
                        }
                        TextInput {
                            id: search
                            Layout.fillWidth: true
                            color: Theme.text
                            selectionColor: Theme.withAlpha(Theme.accent, 0.5)
                            font.family: Theme.fontUi
                            font.pixelSize: 13
                            clip: true
                            onTextEdited: root.query = text
                            Keys.onEscapePressed: root.close()
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: search.text === ""
                                text: "Search"
                                color: Theme.withAlpha(Theme.subtext, 0.7)
                                font: search.font
                            }
                        }
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    Text {
                        anchors.centerIn: parent
                        width: parent.width - 20
                        visible: root.rows.length === 0
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        text: root.query !== "" ? "No matches" : Phone.up ? "No conversations yet.\nMessages show up here as they arrive." : "Not connected"
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                    }

                    ListView {
                        anchors.fill: parent
                        clip: true
                        model: root.rows
                        spacing: 2
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Rectangle {
                            id: row
                            required property var modelData
                            readonly property bool selected: !Phone.composing && Phone.currentThread === modelData.thread
                            readonly property bool unread: (modelData.unread ?? 0) > 0
                            width: ListView.view.width
                            height: 58
                            radius: 12
                            color: selected ? root.blue : rowMouse.containsMouse ? Theme.withAlpha(Theme.text, 0.07) : "transparent"

                            MouseArea {
                                id: rowMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    Phone.openThread(row.modelData.thread);
                                    reply.forceActiveFocus();
                                }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 4
                                anchors.rightMargin: 10
                                spacing: 8

                                // Unread dot
                                Rectangle {
                                    implicitWidth: 8
                                    implicitHeight: 8
                                    radius: 4
                                    color: row.unread && !row.selected ? root.blue : "transparent"
                                }
                                Avatar {
                                    name: Phone.threadTitle(row.modelData)
                                }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 1
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Text {
                                            Layout.fillWidth: true
                                            text: Phone.threadTitle(row.modelData)
                                            color: row.selected ? "white" : Theme.text
                                            font.family: Theme.fontUi
                                            font.pixelSize: 13
                                            font.weight: Font.DemiBold
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            text: Phone.shortTime(row.modelData.timestamp)
                                            color: row.selected ? Qt.rgba(1, 1, 1, 0.8) : Theme.subtext
                                            font.family: Theme.fontUi
                                            font.pixelSize: 11
                                        }
                                    }
                                    Text {
                                        Layout.fillWidth: true
                                        text: row.modelData.preview ?? ""
                                        color: row.selected ? Qt.rgba(1, 1, 1, 0.85) : Theme.subtext
                                        font.family: Theme.fontUi
                                        font.pixelSize: 12
                                        wrapMode: Text.Wrap
                                        maximumLineCount: 2
                                        elide: Text.ElideRight
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                color: Theme.glassBorder
            }

            // ── The conversation ────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // Header: who (or To: when composing)
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 62
                    Layout.leftMargin: 18
                    Layout.rightMargin: 12
                    spacing: 10

                    Text {
                        visible: Phone.composing
                        text: "To:"
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 14
                    }
                    TextInput {
                        id: to
                        visible: Phone.composing
                        Layout.fillWidth: true
                        color: Theme.text
                        selectionColor: Theme.withAlpha(Theme.accent, 0.5)
                        font.family: Theme.fontUi
                        font.pixelSize: 14
                        clip: true
                        Keys.onReturnPressed: reply.forceActiveFocus()
                        Keys.onEscapePressed: root.close()
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: to.text === ""
                            text: "Phone number or Apple ID email"
                            color: Theme.withAlpha(Theme.subtext, 0.7)
                            font: to.font
                        }
                    }

                    Avatar {
                        visible: !Phone.composing && root.current !== null
                        size: 34
                        name: Phone.threadTitle(root.current)
                    }
                    ColumnLayout {
                        visible: !Phone.composing
                        Layout.fillWidth: true
                        spacing: 0
                        Text {
                            Layout.fillWidth: true
                            text: root.current ? Phone.threadTitle(root.current) : ""
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 14
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: {
                                const c = root.current;
                                if (!c)
                                    return "";
                                const addr = String(c.address || c.thread || "").replace(/^(tel|email):/, "");
                                return addr !== Phone.threadTitle(c) ? addr : "";
                            }
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            elide: Text.ElideRight
                        }
                    }
                    RoundButton {
                        visible: !Phone.composing && root.current !== null && Phone.callControl && /^tel:/.test(root.current?.thread ?? "")
                        glyph: "󰏲"
                        tint: root.green
                        enabled: Phone.connected && Phone.activeCall === null
                        onClicked: Phone.dial(root.current.thread)
                    }
                    RoundButton {
                        glyph: "󰅖"
                        tint: Theme.subtext
                        onClicked: root.close()
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: Theme.glassBorder
                }

                // Bubbles
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    ColumnLayout {
                        anchors.centerIn: parent
                        width: parent.width - 60
                        visible: !Phone.connected || (!Phone.composing && root.current === null)
                        spacing: 8
                        Icon {
                            Layout.alignment: Qt.AlignHCenter
                            text: Phone.connected ? "󰍩" : "󰥐"
                            size: 44
                            color: Theme.withAlpha(Theme.subtext, 0.6)
                        }
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            text: Phone.connected ? "Pick a conversation" : Phone.link === "offline" ? "Not connected" : Phone.statusLine
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 15
                            font.weight: Font.DemiBold
                        }
                        Text {
                            Layout.fillWidth: true
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                            text: Phone.connected ? "Or start a new one with ⌃N." : Phone.link === "offline" ? "tetherd isn't running. Settings → Phone has the setup and pairing steps." : (Phone.detail || "Bring the iPhone close and unlock it.")
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 12
                        }
                    }

                    ListView {
                        id: bubbles
                        anchors.fill: parent
                        anchors.margins: 14
                        visible: Phone.connected && !Phone.composing && root.current !== null
                        clip: true
                        spacing: 4
                        model: root.messages
                        boundsBehavior: Flickable.StopAtBounds
                        onCountChanged: Qt.callLater(positionViewAtEnd)
                        onVisibleChanged: if (visible)
                            Qt.callLater(positionViewAtEnd)

                        header: Text {
                            width: bubbles.width
                            height: 30
                            horizontalAlignment: Text.AlignHCenter
                            text: "iMessage / SMS through your iPhone · history starts when it connected"
                            color: Theme.withAlpha(Theme.subtext, 0.8)
                            font.family: Theme.fontUi
                            font.pixelSize: 10
                        }

                        delegate: Item {
                            id: msg
                            required property var modelData
                            required property int index
                            readonly property bool mine: modelData.outgoing === true
                            readonly property var prev: index > 0 ? root.messages[index - 1] : null
                            // A time stamp when 15 minutes passed since the last one.
                            readonly property bool stamp: !prev || (modelData.timestamp - prev.timestamp) > 900
                            width: bubbles.width
                            height: bubble.height + (stamp ? 22 : 0)

                            Text {
                                visible: msg.stamp
                                width: parent.width
                                height: 22
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                text: Phone.shortTime(msg.modelData.timestamp)
                                color: Theme.subtext
                                font.family: Theme.fontUi
                                font.pixelSize: 10
                                font.weight: Font.Medium
                            }

                            Rectangle {
                                id: bubble
                                y: msg.stamp ? 22 : 0
                                anchors.right: msg.mine ? parent.right : undefined
                                anchors.left: msg.mine ? undefined : parent.left
                                width: Math.min(body.implicitWidth, msg.width * 0.68) + 26
                                height: body.implicitHeight + 14
                                radius: 17
                                color: msg.mine ? root.blue : Theme.withAlpha(Theme.text, 0.12)

                                Text {
                                    id: body
                                    x: 13
                                    y: 7
                                    width: Math.min(implicitWidth, msg.width * 0.68)
                                    text: msg.modelData.body ?? ""
                                    color: msg.mine ? "white" : Theme.text
                                    font.family: Theme.fontUi
                                    font.pixelSize: 13
                                    wrapMode: Text.Wrap
                                    textFormat: Text.PlainText
                                }
                            }
                        }
                    }
                }

                // Reply box
                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: 12
                    Layout.topMargin: 4
                    visible: Phone.connected && (Phone.composing || root.current !== null)
                    spacing: 8

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: Math.max(34, reply.contentHeight + 16)
                        radius: 17
                        color: "transparent"
                        border.width: 1
                        border.color: reply.activeFocus ? Theme.withAlpha(root.blue, 0.8) : Theme.glassBorder

                        TextEdit {
                            id: reply
                            anchors {
                                left: parent.left
                                right: parent.right
                                verticalCenter: parent.verticalCenter
                                leftMargin: 14
                                rightMargin: 14
                            }
                            color: Theme.text
                            selectionColor: Theme.withAlpha(Theme.accent, 0.5)
                            font.family: Theme.fontUi
                            font.pixelSize: 13
                            wrapMode: TextEdit.Wrap
                            textFormat: TextEdit.PlainText
                            Keys.onPressed: event => {
                                if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
                                    root.sendNow();
                                    event.accepted = true;
                                } else if (event.key === Qt.Key_Escape) {
                                    root.close();
                                    event.accepted = true;
                                } else if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_N) {
                                    Phone.compose();
                                    event.accepted = true;
                                }
                            }
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: reply.text === ""
                                text: root.current?.repliable === false ? (root.current.reply_reason || "Can't reply to this group") : "iMessage"
                                color: Theme.withAlpha(Theme.subtext, 0.7)
                                font: reply.font
                            }
                        }
                    }
                    RoundButton {
                        glyph: "󰒊"
                        tint: root.blue
                        filled: true
                        enabled: root.canReply && reply.text.trim() !== ""
                        onClicked: root.sendNow()
                    }
                }
            }
        }
    }
}
