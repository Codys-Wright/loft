import QtQuick
import QtQuick.Layouts
import qs.components
import qs.palette
import qs.services

// Pick an action from the catalog (palette/Actions.qml): a search field and
// the matches grouped (Controls, Capture, …, Apps, Snippets). Inline, under
// an "Add…" button.
ColumnLayout {
    id: picker

    // Ids already used (shown dimmed with a check).
    property var exclude: []
    property string query: ""

    signal picked(string id)
    signal canceled

    spacing: 8

    readonly property var rows: {
        const q = query.trim();
        const out = [];
        const all = Actions.all().filter(e => Actions.available(e.id) && Actions.matches(e, q));
        for (const g of Actions.groups) {
            const items = all.filter(e => e.group === g);
            if (items.length === 0)
                continue;
            out.push({ header: g });
            for (const e of items.slice(0, q ? 60 : g === "Apps" ? 400 : 100))
                out.push(e);
        }
        return out;
    }

    // (Called as the picker is shown: focus once it is visible.)
    function focusSearch() {
        Qt.callLater(field.focusInput);
    }

    RowLayout {
        Layout.fillWidth: true
        spacing: 8

        SettingsTextField {
            id: field
            Layout.fillWidth: true
            placeholder: "Search actions, controls, apps…"
            onEdited: t => picker.query = t
        }
        SettingsButton {
            text: "Done"
            onClicked: picker.canceled()
        }
    }

    Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 260
        radius: 10
        color: Theme.withAlpha(Theme.text, 0.04)
        border.width: 1
        border.color: Theme.glassBorder
        clip: true

        ListView {
            id: view
            anchors.fill: parent
            anchors.margins: 4
            model: picker.rows
            boundsBehavior: Flickable.StopAtBounds
            reuseItems: true

            delegate: Item {
                id: r
                required property var modelData
                readonly property bool isHeader: modelData.header !== undefined
                readonly property bool used: !isHeader && picker.exclude.includes(modelData.id)
                width: ListView.view.width
                height: isHeader ? 24 : 32

                Text {
                    visible: r.isHeader
                    anchors {
                        left: parent.left
                        leftMargin: 8
                        bottom: parent.bottom
                        bottomMargin: 4
                    }
                    text: r.modelData.header ?? ""
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                }

                Rectangle {
                    visible: !r.isHeader
                    anchors.fill: parent
                    radius: 7
                    color: hit.containsMouse ? Theme.withAlpha(Theme.accent, 0.2) : "transparent"

                    RowLayout {
                        anchors {
                            fill: parent
                            leftMargin: 8
                            rightMargin: 8
                        }
                        spacing: 8
                        opacity: r.used ? 0.45 : 1

                        Item {
                            Layout.preferredWidth: 20
                            Layout.preferredHeight: 20
                            Rectangle {
                                anchors.fill: parent
                                radius: 6
                                visible: r.modelData.kind !== "app"
                                color: Theme.badgeColor(Actions.badge(r.modelData.group))
                                Icon {
                                    anchors.centerIn: parent
                                    text: r.isHeader ? "" : Actions.icon(r.modelData.id)
                                    size: 11
                                    color: "white"
                                }
                            }
                            AppIcon {
                                anchors.fill: parent
                                visible: r.modelData.kind === "app"
                                appId: r.modelData.appId ?? ""
                                pixelSize: 40
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: r.modelData.label ?? ""
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                        Text {
                            text: r.used ? "added" : (r.modelData.hint ?? "")
                            color: Theme.subtext
                            font.family: Theme.fontUi
                            font.pixelSize: 10
                            elide: Text.ElideRight
                            Layout.maximumWidth: 200
                        }
                    }

                    MouseArea {
                        id: hit
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: picker.picked(r.modelData.id)
                    }
                }
            }
        }
    }
}
