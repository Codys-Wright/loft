import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Island page: today's date and the next events (today, then tomorrow), each
// with its time and — for video meetings — a Join button.
Item {
    id: root

    // Rows: section labels + events, at most four lines.
    readonly property var rows: {
        const out = [];
        const today = Agenda.today;
        for (const e of today)
            out.push({ kind: "event", e: e });
        if (out.length < 3 && Agenda.tomorrow.length) {
            out.push({ kind: "label", text: "Tomorrow" });
            for (const e of Agenda.tomorrow)
                out.push({ kind: "event", e: e });
        }
        return out.slice(0, 4);
    }

    RowLayout {
        anchors {
            fill: parent
            margins: 18
            bottomMargin: 26
        }
        spacing: 18

        ColumnLayout {
            Layout.preferredWidth: 96
            Layout.alignment: Qt.AlignTop
            spacing: 0

            Text {
                text: Qt.formatDateTime(new Date(Agenda.now), "dddd").toUpperCase()
                color: Theme.urgent
                font.family: Theme.fontUi
                font.pixelSize: 11
                font.weight: Font.DemiBold
                font.letterSpacing: 0.5
            }

            Text {
                text: Qt.formatDateTime(new Date(Agenda.now), "d")
                color: Theme.islandText
                font.family: Theme.fontUi
                font.pixelSize: 44
                font.weight: Font.Light
            }

            Text {
                text: {
                    const n = Agenda.today.length;
                    return !Agenda.enabled ? "No calendars" : n === 0 ? "Nothing left today" : n === 1 ? "1 event" : `${n} events`;
                }
                color: Theme.islandSubtext
                font.family: Theme.fontUi
                font.pixelSize: 11
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 6

            Text {
                visible: !Agenda.enabled || root.rows.length === 0
                Layout.fillWidth: true
                Layout.topMargin: 4
                text: Agenda.enabled ? "No events today or tomorrow." : "Add a calendar in Settings → Dynamic Island: khal, Evolution or an ICS link."
                wrapMode: Text.Wrap
                color: Theme.islandSubtext
                font.family: Theme.fontUi
                font.pixelSize: 12
            }

            Repeater {
                model: root.rows

                delegate: Loader {
                    id: row
                    required property var modelData
                    Layout.fillWidth: true
                    sourceComponent: modelData.kind === "label" ? label : event

                    Component {
                        id: label
                        Text {
                            text: row.modelData.text
                            color: Theme.islandSubtext
                            font.family: Theme.fontUi
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                        }
                    }

                    Component {
                        id: event
                        RowLayout {
                            id: ev
                            readonly property var e: row.modelData.e
                            readonly property bool current: e.start <= Agenda.now && e.end > Agenda.now
                            readonly property bool imminent: !e.allDay && e.start - Agenda.now < 10 * 60000 && e.end > Agenda.now
                            spacing: 10

                            Rectangle {
                                Layout.preferredWidth: 3
                                Layout.preferredHeight: 30
                                radius: 1.5
                                color: ev.current ? Theme.ok : Theme.accent
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 0

                                Text {
                                    Layout.fillWidth: true
                                    text: ev.e.title
                                    color: Theme.islandText
                                    font.family: Theme.fontUi
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                    elide: Text.ElideRight
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: [ev.e.allDay ? "All day" : Agenda.timeRange(ev.e), ev.e.location].filter(s => s).join("  ·  ")
                                    color: Theme.islandSubtext
                                    font.family: Theme.fontUi
                                    font.pixelSize: 11
                                    font.features: { "tnum": 1 }
                                    elide: Text.ElideRight
                                }
                            }

                            Text {
                                visible: !ev.e.allDay && !ev.e.joinUrl && ev.e.start > Agenda.now && ev.e.start - Agenda.now < 3600000
                                text: Agenda.when(ev.e)
                                color: Theme.islandSubtext
                                font.family: Theme.fontUi
                                font.pixelSize: 11
                            }

                            // Join a video meeting (Meet, Zoom, Teams, …).
                            Rectangle {
                                visible: ev.e.joinUrl !== ""
                                implicitWidth: joinRow.implicitWidth + 18
                                implicitHeight: 24
                                radius: 12
                                color: ev.imminent ? Theme.withAlpha(Theme.ok, joinMouse.containsMouse ? 1 : 0.85) : Theme.withAlpha(Theme.islandText, joinMouse.containsMouse ? 0.2 : 0.1)

                                Row {
                                    id: joinRow
                                    anchors.centerIn: parent
                                    spacing: 5
                                    Icon {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "󰕧"
                                        size: 12
                                        color: ev.imminent ? Theme.readableOn(Theme.ok, Theme.islandBg) : Theme.islandText
                                    }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: "Join"
                                        color: ev.imminent ? Theme.readableOn(Theme.ok, Theme.islandBg) : Theme.islandText
                                        font.family: Theme.fontUi
                                        font.pixelSize: 11
                                        font.weight: Font.DemiBold
                                    }
                                }

                                MouseArea {
                                    id: joinMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: Agenda.join(ev.e)
                                }
                            }
                        }
                    }
                }
            }

            Item {
                Layout.fillHeight: true
            }
        }
    }
}
