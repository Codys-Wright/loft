import QtQuick
import QtQuick.Layouts
import Quickshell.Networking
import Quickshell.Services.Pipewire
import qs.audio
import qs.components
import qs.controls
import qs.services

// One Control Center module on the grid: a glass tile of `size` cells
// showing the control `controlId` — Connectivity (Wi-Fi / Bluetooth /
// Nearby rows), a slider row (Sound, Display), Now Playing, the calendar,
// or a small toggle/action. Panel controls expand in place (expand(id)).
// In edit mode it shows remove (−) and resize badges and can be dragged.
GlassSurface {
    id: mod

    required property string controlId
    required property string size
    property bool editing: false
    property bool dragging: false

    // id of the panel to expand ("wifi", "bluetooth", "sound", …).
    signal expand(string panel)
    signal removeRequested
    signal resizeRequested

    readonly property var control: Controls.control(controlId)
    readonly property bool resizable: (control?.sizes ?? []).length > 1
    readonly property bool wide: size === "2x1" || size === "4x1" || size === "2x2"

    radius: Theme.panelRadius
    showHighlight: false
    strength: 1.15
    scale: dragging ? 1.05 : 1
    z: dragging ? 10 : 0
    Behavior on scale {
        NumberAnimation {
            duration: 140
        }
    }

    Loader {
        id: content
        anchors.fill: parent
        anchors.margins: mod.controlId === "clock" ? 0 : 10
        enabled: !mod.editing
        sourceComponent: {
            switch (mod.controlId) {
            case "connectivity":
                return connectivity;
            case "sound":
            case "display":
                return slider;
            case "nowPlaying":
                return nowPlaying;
            case "clock":
                return calendar;
            }
            return small;
        }
    }

    // ── Edit badges ──────────────────────────────────────────────────────
    Rectangle {
        visible: mod.editing
        x: -6
        y: -6
        width: 20
        height: 20
        radius: 10
        color: Theme.overlay
        border.width: 1
        border.color: Theme.glassBorder
        Text {
            anchors.centerIn: parent
            text: "−"
            color: Theme.text
            font.pixelSize: 15
            font.weight: Font.Bold
        }
        MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.PointingHandCursor
            onClicked: mod.removeRequested()
        }
    }
    Rectangle {
        visible: mod.editing && mod.resizable
        anchors {
            right: parent.right
            bottom: parent.bottom
            rightMargin: -6
            bottomMargin: -6
        }
        width: 20
        height: 20
        radius: 10
        color: Theme.overlay
        border.width: 1
        border.color: Theme.glassBorder
        Icon {
            anchors.centerIn: parent
            text: "󰩨"
            size: 11
        }
        MouseArea {
            anchors.fill: parent
            anchors.margins: -4
            cursorShape: Qt.PointingHandCursor
            onClicked: mod.resizeRequested()
        }
    }

    // ── Focusable: a keyboard target (Nav.ccFocus) with a focus ring ─────
    component Focusable: Item {
        id: f
        property string ccId: ""
        property string ccLabel: ""
        property bool ccExpandable: false
        property var toggleFn: null
        property var expandFn: null
        readonly property bool ccFocusable: !mod.editing && visible
        function ccToggle() {
            if (toggleFn)
                toggleFn();
            else if (expandFn)
                expandFn();
        }
        function ccExpand() {
            if (expandFn)
                expandFn();
        }
        Rectangle {
            anchors.fill: parent
            anchors.margins: -3
            radius: 12
            color: "transparent"
            border.width: 2
            border.color: Theme.accent
            visible: Nav.ccFocus === f
        }
    }

    // A round toggle button (Wi-Fi, Bluetooth, small controls).
    component Disc: Rectangle {
        id: disc
        property string glyph
        property bool on: false
        property real d: 36
        signal clicked
        implicitWidth: d
        implicitHeight: d
        radius: d / 2
        color: on ? Theme.accent : Theme.withAlpha(Theme.text, discMouse.containsMouse ? 0.22 : 0.14)
        Behavior on color {
            ColorAnimation {
                duration: 150
            }
        }
        Icon {
            anchors.centerIn: parent
            text: disc.glyph
            size: disc.d * 0.45
            color: disc.on ? Theme.bg : Theme.text
        }
        MouseArea {
            id: discMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: disc.clicked()
        }
    }

    // ── Connectivity: Wi-Fi, Bluetooth, Nearby share ────────────────────
    Component {
        id: connectivity
        ColumnLayout {
            spacing: 4
            Repeater {
                model: [
                    { id: "wifi", panel: "wifi", show: Features.on("wifiControl") },
                    { id: "bluetooth", panel: "bluetooth", show: Features.on("bluetoothControl") },
                    { id: "nearby", panel: "", show: Nearby.available }
                ].filter(x => x.show)
                delegate: Focusable {
                    id: line
                    required property var modelData
                    readonly property bool isNearby: modelData.id === "nearby"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    ccId: modelData.id
                    ccLabel: isNearby ? Nearby.label : Controls.control(modelData.id).label
                    ccExpandable: !isNearby
                    toggleFn: () => isNearby ? Nearby.open() : ControlActions.trigger(modelData.id)
                    expandFn: isNearby ? null : () => mod.expand(modelData.panel)

                    RowLayout {
                        anchors.fill: parent
                        spacing: 10
                        Disc {
                            glyph: line.isNearby ? "󰘊" : Controls.iconOf(line.modelData.id)
                            on: line.isNearby ? false : line.modelData.id === "wifi" ? Networking.wifiEnabled : (Controls.btAdapter?.enabled ?? false)
                            onClicked: line.ccToggle()
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text {
                                Layout.fillWidth: true
                                text: line.ccLabel
                                color: Theme.text
                                font.family: Theme.fontUi
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                elide: Text.ElideRight
                            }
                            Text {
                                Layout.fillWidth: true
                                text: line.isNearby ? "Open" : Controls.status(line.modelData.id)
                                color: Theme.subtext
                                font.family: Theme.fontUi
                                font.pixelSize: 11
                                elide: Text.ElideRight
                            }
                        }
                    }
                    MouseArea {
                        // The label expands (macOS); the disc toggles.
                        x: 46
                        width: parent.width - 46
                        height: parent.height
                        cursorShape: Qt.PointingHandCursor
                        onClicked: line.isNearby ? Nearby.open() : line.ccExpand()
                    }
                }
            }
        }
    }

    // ── Sound / Display: a slider row ────────────────────────────────────
    Component {
        id: slider
        Focusable {
            id: sl
            readonly property bool isSound: mod.controlId === "sound"
            readonly property PwNode sink: Pipewire.defaultAudioSink
            readonly property bool ready: sink?.ready ?? false
            ccId: mod.controlId
            ccLabel: isSound ? "Sound" : "Display"
            ccExpandable: true
            toggleFn: () => {
                if (isSound && ready)
                    sink.audio.muted = !sink.audio.muted;
                else
                    mod.expand(mod.controlId);
            }
            expandFn: () => mod.expand(mod.controlId)
            Component.onCompleted: if (!isSound)
                Brightness.refresh()

            PwObjectTracker {
                objects: sl.isSound && sl.sink ? [sl.sink] : []
            }

            ColumnLayout {
                anchors.fill: parent
                spacing: 6
                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        Layout.fillWidth: true
                        text: sl.isSound ? (sl.ready ? Sound.label(sl.sink) : "Sound") : "Display"
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: sl.ccExpand()
                        }
                    }
                    Icon {
                        text: "󰅂"
                        size: 13
                        color: Theme.subtext
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            onClicked: sl.ccExpand()
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Icon {
                        text: sl.isSound ? (!sl.ready || sl.sink.audio.muted ? "󰝟" : "󰕾") : "󰃠"
                        size: 15
                        color: Theme.text
                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -4
                            cursorShape: Qt.PointingHandCursor
                            onClicked: if (sl.isSound && sl.ready)
                                sl.sink.audio.muted = !sl.sink.audio.muted
                        }
                    }
                    VolumeSlider {
                        Layout.fillWidth: true
                        enabled: sl.isSound ? sl.ready : Brightness.available
                        opacity: enabled ? 1 : 0.4
                        value: sl.isSound ? (sl.ready ? sl.sink.audio.volume : 0) : Brightness.value
                        dimmed: sl.isSound && (!sl.ready || sl.sink.audio.muted)
                        onMoved: v => {
                            if (sl.isSound) {
                                if (sl.ready)
                                    sl.sink.audio.volume = v;
                            } else
                                Brightness.setAll(v);
                        }
                    }
                }
            }
        }
    }

    // ── Now Playing ──────────────────────────────────────────────────────
    Component {
        id: nowPlaying
        Focusable {
            id: np
            readonly property var player: Controls.player
            ccId: "nowPlaying"
            ccLabel: "Now Playing"
            ccExpandable: true
            toggleFn: () => {
                if (player?.canTogglePlaying)
                    player.togglePlaying();
            }
            expandFn: () => mod.expand("nowPlaying")

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: np.ccExpand()
            }
            NowPlayingCard {
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                }
                player: np.player
                compact: true
                stacked: mod.size === "2x2"
                artSize: mod.size === "2x2" ? 56 : 40
            }
        }
    }

    // ── Calendar (2×2, optional) ─────────────────────────────────────────
    Component {
        id: calendar
        Calendar {
            color: "transparent"
            showBorder: false
        }
    }

    // ── A small control: toggle, action or panel ─────────────────────────
    Component {
        id: small
        Focusable {
            id: sc
            readonly property bool isPanel: mod.control?.kind === "panel"
            readonly property bool on: mod.control?.kind !== "action" && Controls.active(mod.controlId)
            ccId: mod.controlId
            ccLabel: mod.control?.label ?? mod.controlId
            ccExpandable: isPanel
            toggleFn: () => {
                if (mod.controlId === "focus" || mod.controlId === "caffeine")
                    ControlActions.trigger(mod.controlId);
                else if (isPanel && !["wifi", "bluetooth"].includes(mod.controlId))
                    mod.expand(mod.controlId);
                else
                    ControlActions.trigger(mod.controlId);
            }
            expandFn: isPanel ? () => mod.expand(mod.controlId) : null

            // 1×1: the disc centered with the name under it.
            ColumnLayout {
                visible: !mod.wide
                anchors.centerIn: parent
                spacing: 3
                Disc {
                    Layout.alignment: Qt.AlignHCenter
                    glyph: Controls.iconOf(mod.controlId)
                    on: sc.on
                    onClicked: sc.ccToggle()
                }
                // Long names wrap to a second line (macOS), never "Screen Reco…".
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.maximumWidth: mod.width - 8
                    text: sc.ccLabel
                    color: Theme.subtext
                    font.family: Theme.fontUi
                    font.pixelSize: 9
                    // Always two lines tall, so the discs of a row line up.
                    Layout.preferredHeight: Math.ceil(font.pixelSize * 2.2)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignTop
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    lineHeight: 0.9
                    elide: Text.ElideRight
                }
            }

            // 2×1: disc + name + status; the label expands panels.
            RowLayout {
                visible: mod.wide
                anchors.fill: parent
                spacing: 10
                Disc {
                    glyph: Controls.iconOf(mod.controlId)
                    on: sc.on
                    onClicked: sc.ccToggle()
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                        Layout.fillWidth: true
                        text: sc.ccLabel
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: text !== ""
                        text: Controls.status(mod.controlId)
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                }
            }
            MouseArea {
                visible: mod.wide && sc.isPanel
                x: 46
                width: parent.width - 46
                height: parent.height
                cursorShape: Qt.PointingHandCursor
                onClicked: sc.ccExpand()
            }
        }
    }
}
