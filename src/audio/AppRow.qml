import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// One app in the mixer: icon (click = mute), name and what it plays, a
// volume track up to 150 %, pin and output buttons. The output button
// unfolds the outputs list to send just this app elsewhere.
ColumnLayout {
    id: root

    required property var app
    property bool meters: false

    readonly property bool active: app.streams.length > 0
    readonly property bool muted: Sound.appMuted(app)
    readonly property real volume: Sound.appVolume(app)
    readonly property bool pinned: Sound.isPinned(app.key)
    readonly property var output: Sound.appOutput(app)
    readonly property string target: Sound.appTarget(app)
    property bool picking: false

    spacing: 6
    opacity: active ? 1 : 0.55

    RowLayout {
        Layout.fillWidth: true
        spacing: 10

        Item {
            Layout.preferredWidth: 30
            Layout.preferredHeight: 30

            Image {
                anchors.fill: parent
                source: root.app.icon
                sourceSize: Qt.size(60, 60)
                smooth: true
                opacity: root.muted ? 0.4 : 1
            }

            // Muted badge.
            Rectangle {
                visible: root.muted
                anchors {
                    right: parent.right
                    bottom: parent.bottom
                    margins: -3
                }
                width: 16
                height: 16
                radius: 8
                color: Theme.urgent

                Icon {
                    anchors.centerIn: parent
                    text: "󰝟"
                    size: 10
                    color: Theme.bg
                }
            }

            MouseArea {
                anchors.fill: parent
                enabled: root.active
                cursorShape: Qt.PointingHandCursor
                onClicked: Sound.setAppMuted(root.app, !root.muted)
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Text {
                Layout.fillWidth: true
                text: root.app.name
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            Text {
                Layout.fillWidth: true
                text: {
                    if (!root.active)
                        return "Not playing";
                    const media = root.app.streams.map(s => s.properties["media.name"] ?? "").filter(m => m && m !== root.app.name);
                    // Say where it plays when that isn't the default output.
                    const where = root.output && root.output.id !== Sound.defaultSink?.id ? `→ ${Sound.label(root.output)}` : "";
                    const what = media.length > 1 ? `${media.length} streams` : media[0] ?? "";
                    return [what, where].filter(t => t).join(" · ");
                }
                visible: text !== ""
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                elide: Text.ElideRight
            }
        }

        // Pin (favorites stay on top, also when silent).
        Icon {
            text: root.pinned ? "󰐃" : "󰤱"
            size: 14
            color: root.pinned ? Theme.accent : Theme.subtext
            MouseArea {
                anchors.fill: parent
                anchors.margins: -6
                cursorShape: Qt.PointingHandCursor
                onClicked: Sound.togglePin(root.app.key)
            }
        }

        // Output for this app.
        Rectangle {
            visible: root.active && Features.on("mixer")
            Layout.preferredWidth: outRow.implicitWidth + 14
            Layout.preferredHeight: 24
            radius: 12
            color: root.picking || root.target ? Theme.withAlpha(Theme.accent, 0.25) : outHover.containsMouse ? Theme.withAlpha(Theme.text, 0.14) : Theme.withAlpha(Theme.text, 0.08)

            Row {
                id: outRow
                anchors.centerIn: parent
                spacing: 3
                Icon {
                    text: Sound.outputIcon(root.output)
                    size: 12
                    anchors.verticalCenter: parent.verticalCenter
                }
                Icon {
                    text: root.picking ? "󰅃" : "󰅀"
                    size: 10
                    color: Theme.subtext
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            MouseArea {
                id: outHover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.picking = !root.picking
            }
        }
    }

    RowLayout {
        visible: root.active
        Layout.fillWidth: true
        spacing: 10

        VolumeSlider {
            Layout.fillWidth: true
            to: Sound.maxAppVolume
            value: root.volume
            dimmed: root.muted
            onMoved: v => Sound.setAppVolume(root.app, v)
        }

        Text {
            Layout.preferredWidth: 38
            horizontalAlignment: Text.AlignRight
            text: `${Math.round(root.volume * 100)}%`
            color: root.volume > 1.001 ? Theme.warn : Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            font.features: {
                "tnum": 1
            }
        }
    }

    LevelMeter {
        visible: root.active && root.meters
        Layout.fillWidth: true
        Layout.rightMargin: 48
        Layout.preferredHeight: 3
        node: root.app.streams[0] ?? null
    }

    DeviceList {
        visible: root.picking && root.active
        Layout.fillWidth: true
        nodes: Sound.sinks
        currentId: root.output?.id ?? -1
        followDefault: true
        followingDefault: root.target === ""
        defaultLabel: `Default output (${Sound.label(Sound.defaultSink)})`
        onPicked: node => {
            Sound.moveApp(root.app, node);
            root.picking = false;
        }
    }
}
