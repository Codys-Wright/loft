import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Island page: AI coding agents. Per tool (Claude Code, Codex): sessions
// running now (project folder names, a dot while one is working), tokens and
// estimated API-equivalent cost today, the 5-hour window (Claude: vs your
// busiest earlier window; Codex: its own rate-limit percentages), this week.
// Aggregate counts only (AiUsage / `loft island ai`).
Item {
    id: root

    readonly property var tools: [
        { key: "claude", name: "Claude Code", color: Theme.accent2, d: AiUsage.claude },
        { key: "codex", name: "Codex", color: Theme.accent, d: AiUsage.codex }
    ].filter(t => t.d?.available && (t.d.week.n > 0 || t.d.sessions.length > 0 || t.d.limits))

    component Bar: Item {
        id: bar
        property real value: 0
        property color color: Theme.accent
        // A real limit: amber from 70 %, red from 90 %.
        property bool limit: true
        implicitHeight: 6
        Rectangle {
            anchors.fill: parent
            radius: 3
            color: Theme.withAlpha(Theme.text, 0.12)
        }
        Rectangle {
            width: Math.max(6, parent.width * Math.min(1, Math.max(0, bar.value)))
            height: parent.height
            radius: 3
            color: !bar.limit ? bar.color : bar.value >= 0.9 ? Theme.urgent : bar.value >= 0.7 ? Theme.warn : bar.color
        }
    }

    component Small: Text {
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 11
        font.features: { "tnum": 1 }
        elide: Text.ElideRight
    }

    Text {
        anchors.centerIn: parent
        anchors.verticalCenterOffset: -8
        visible: root.tools.length === 0
        width: parent.width - 60
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: !Settings.island.ai ? "AI usage is off (Settings → Dynamic Island)." : AiUsage.data === null ? "Reading Claude Code and Codex usage…" : "No Claude Code or Codex activity this week."
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 12
    }

    RowLayout {
        anchors {
            fill: parent
            margins: 18
            bottomMargin: 26
        }
        spacing: 22
        visible: root.tools.length > 0

        Repeater {
            model: root.tools

            delegate: ColumnLayout {
                id: col
                required property var modelData
                required property int index
                readonly property var d: modelData.d
                readonly property var block: d.block
                readonly property var limits: d.limits ?? null
                Layout.fillWidth: true
                Layout.preferredWidth: 1
                Layout.alignment: Qt.AlignTop
                spacing: 3

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    Rectangle {
                        Layout.preferredWidth: 8
                        Layout.preferredHeight: 8
                        radius: 4
                        color: col.modelData.color
                    }
                    Text {
                        Layout.fillWidth: true
                        text: col.modelData.name
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                    Small {
                        text: col.d.sessions.length === 0 ? "idle" : col.d.sessions.length === 1 ? "1 running" : `${col.d.sessions.length} running`
                        color: col.d.sessions.some(s => s.busy) ? Theme.ok : Theme.subtext
                    }
                }

                RowLayout {
                    spacing: 6
                    Text {
                        text: AiUsage.tokens(col.d.today.total)
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 24
                        font.weight: Font.Light
                        font.features: { "tnum": 1 }
                    }
                    ColumnLayout {
                        spacing: -2
                        Small {
                            text: "tokens today"
                        }
                        Small {
                            text: `≈ ${AiUsage.cost(col.d.today.cost)}`
                        }
                    }
                }

                // The 5-hour window: Codex reports its limit; for Claude it's
                // measured against the busiest earlier window this week.
                Bar {
                    Layout.fillWidth: true
                    Layout.topMargin: 2
                    color: col.modelData.color
                    visible: col.limits?.primary !== undefined || col.block !== null
                    limit: col.limits?.primary !== undefined
                    value: col.limits?.primary ? col.limits.primary.usedPercent / 100 : (col.block?.ofBusiest ?? 1)
                }
                Small {
                    Layout.fillWidth: true
                    visible: col.limits?.primary !== undefined || col.block !== null
                    text: col.limits?.primary ? `${Math.round(col.limits.primary.usedPercent)}% of ${col.limits.primary.windowMinutes >= 1440 ? "weekly" : Math.round(col.limits.primary.windowMinutes / 60) + "-h"} limit · resets in ${AiUsage.until(col.limits.primary.resetsAt)}` : col.block ? `5-h window ${AiUsage.tokens(col.block.total)} · resets in ${AiUsage.until(col.block.end)}` : ""
                }
                Small {
                    Layout.fillWidth: true
                    visible: !col.limits?.primary && col.block !== null
                    text: !col.block ? "" : !col.block.ofBusiest || col.block.ofBusiest > 1 ? "Your busiest window this week" : `${Math.round(col.block.ofBusiest * 100)}% of your busiest this week`
                }
                Small {
                    Layout.fillWidth: true
                    visible: col.limits?.secondary !== undefined
                    text: col.limits?.secondary ? `Weekly limit ${Math.round(col.limits.secondary.usedPercent)}% · resets in ${AiUsage.until(col.limits.secondary.resetsAt)}` : ""
                }
                Small {
                    Layout.fillWidth: true
                    text: `This week ${AiUsage.tokens(col.d.week.total)} · ≈ ${AiUsage.cost(col.d.week.cost)}`
                }

                // Running sessions: project folder names.
                Flow {
                    Layout.fillWidth: true
                    Layout.topMargin: 3
                    Layout.maximumHeight: 22
                    clip: true
                    spacing: 4
                    Repeater {
                        model: col.d.sessions.slice(0, 4)
                        delegate: Rectangle {
                            required property var modelData
                            width: sRow.implicitWidth + 14
                            height: 20
                            radius: 10
                            color: Theme.withAlpha(Theme.text, 0.1)
                            Row {
                                id: sRow
                                anchors.centerIn: parent
                                spacing: 5
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 6
                                    height: 6
                                    radius: 3
                                    color: modelData.busy ? Theme.ok : Theme.withAlpha(Theme.text, 0.35)
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: modelData.project
                                    color: Theme.text
                                    font.family: Theme.fontUi
                                    font.pixelSize: 10
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
