import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Island page: the Scratchpad's current note at a glance (its title and last
// lines), a field that adds a line to it (Enter), the notes' tabs as ‹ ›,
// and a button for the full window (Scratchpad.qml, Mod+Shift+N).
// While the field has the keyboard the island stays open (`typing`).
Item {
    id: root

    // The island takes the keyboard (OnDemand) for this page and stays
    // expanded while the field is being typed in.
    readonly property bool typing: field.activeFocus
    readonly property var note: Scratchpad.note
    readonly property var lines: (note?.text ?? "").split("\n").filter(l => l.trim() !== "")

    function release() {
        field.focus = false;
    }

    ColumnLayout {
        anchors {
            fill: parent
            leftMargin: 22
            rightMargin: 22
            topMargin: 16
            bottomMargin: 24
        }
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Icon {
                text: "\u{F09EE}"
                size: 15
                color: Theme.warn
            }
            Text {
                Layout.fillWidth: true
                text: root.note ? Scratchpad.titleOf(root.note) : "Scratchpad"
                color: Theme.islandText
                font.family: Theme.fontUi
                font.pixelSize: 14
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            // ‹ 2 of 3 › between the notes.
            Icon {
                visible: Scratchpad.notes.length > 1
                text: "\u{F0141}"
                color: Theme.islandSubtext
                size: 14
                opacity: Scratchpad.current > 0 ? 1 : 0.3
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Scratchpad.select(Scratchpad.current - 1)
                }
            }
            Text {
                visible: Scratchpad.notes.length > 1
                text: `${Scratchpad.current + 1} of ${Scratchpad.notes.length}`
                color: Theme.islandSubtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                font.features: { "tnum": 1 }
            }
            Icon {
                visible: Scratchpad.notes.length > 1
                text: "\u{F0142}"
                color: Theme.islandSubtext
                size: 14
                opacity: Scratchpad.current < Scratchpad.notes.length - 1 ? 1 : 0.3
                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Scratchpad.select(Scratchpad.current + 1)
                }
            }
            IslandButton {
                size: 30
                icon: "\u{F03CC}"
                onClicked: {
                    root.release();
                    Scratchpad.open = Scratchpad.enabled;
                }
            }
        }

        // The note's last lines (where a quick add lands).
        Text {
            Layout.fillWidth: true
            Layout.fillHeight: true
            text: root.lines.length === 0 ? "Empty note. Type below to start it." : root.lines.slice(-4).join("\n")
            color: root.lines.length === 0 ? Theme.islandSubtext : Theme.islandText
            opacity: root.lines.length === 0 ? 0.8 : 0.92
            font.family: Theme.fontUi
            font.pixelSize: 12
            lineHeight: 1.15
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            maximumLineCount: 4
            verticalAlignment: Text.AlignBottom
            clip: true
        }

        // Quick add.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 32
            radius: 16
            color: Theme.withAlpha(Theme.islandText, field.activeFocus ? 0.16 : 0.1)
            border.width: field.activeFocus ? 1 : 0
            border.color: Theme.withAlpha(Theme.accent, 0.8)

            TextInput {
                id: field
                anchors {
                    left: parent.left
                    right: addHint.left
                    verticalCenter: parent.verticalCenter
                    leftMargin: 14
                    rightMargin: 8
                }
                color: Theme.islandText
                selectionColor: Theme.accent
                font.family: Theme.fontUi
                font.pixelSize: 12
                clip: true
                Keys.onReturnPressed: add()
                Keys.onEnterPressed: add()
                Keys.onEscapePressed: {
                    text = "";
                    root.release();
                }
                function add() {
                    if (text.trim() === "")
                        return;
                    Scratchpad.addLine(text);
                    text = "";
                }

                Text {
                    visible: field.text === ""
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Add a line…"
                    color: Theme.islandSubtext
                    font: field.font
                }
            }
            Text {
                id: addHint
                anchors {
                    right: parent.right
                    rightMargin: 12
                    verticalCenter: parent.verticalCenter
                }
                text: "⏎"
                visible: field.text !== ""
                color: Theme.islandSubtext
                font.family: Theme.fontUi
                font.pixelSize: 12
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.IBeamCursor
                // Hand the click to the field (and the island the keyboard).
                onPressed: mouse => {
                    field.forceActiveFocus();
                    mouse.accepted = false;
                }
            }
        }
    }
}
