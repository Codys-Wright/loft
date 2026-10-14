import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Pipewire
import Quickshell.Services.SystemTray
import qs.audio
import qs.components
import qs.controls
import qs.menubar
import qs.services

// The bar's status area (macOS's menu extras), arranged by Controls:
// Settings → Menu Bar (show/hide, order, "only when active"), or
// Super-drag an item along the bar to move it / off the bar to remove it.
// Items that don't fit (leftmost first) move behind a » overflow, which
// also holds tray icons tucked away.
Item {
    id: root

    required property var window
    required property string screenName
    property real maxWidth: Infinity
    readonly property int spacing: 6

    implicitWidth: row.implicitWidth
    implicitHeight: 24

    readonly property var order: Controls.barOrder
    readonly property color fg: Theme.barTextFor(screenName)
    // Delegates before this index don't fit.
    property int firstFit: 0
    readonly property var pinnedTray: SystemTray.items.values.filter(i => !Controls.isTrayTucked(i))
    readonly property var tuckedTray: SystemTray.items.values.filter(i => Controls.isTrayTucked(i))

    function wanted(id) {
        if (id === "tray")
            return Controls.barShown(id) && pinnedTray.length > 0;
        return Controls.barShown(id);
    }

    // ── Fitting ──────────────────────────────────────────────────────────
    function measure() {
        let used = 0;
        let fit = 0;
        const reserve = more.implicitWidth + spacing;
        for (let i = items.count - 1; i >= 0; i--) {
            const d = items.itemAt(i);
            if (!d || !d.wanted)
                continue;
            used += d.implicitWidth + spacing;
            if (used > maxWidth - reserve) {
                fit = i + 1;
                break;
            }
        }
        firstFit = fit;
        const over = [];
        for (let i = 0; i < fit; i++) {
            const d = items.itemAt(i);
            if (d && d.wanted)
                over.push(d.controlId);
        }
        Controls.setOverflow(screenName, over);
        register();
    }

    function register() {
        const l = [];
        for (let i = 0; i < items.count; i++) {
            const d = items.itemAt(i);
            if (d && d.visible && d.item && Controls.control(d.controlId)?.kind === "panel")
                l.push({ id: d.controlId, item: d.item });
        }
        if (more.visible)
            l.unshift({ id: "overflow", item: more });
        MenuState.setExtraItems(screenName, l);
    }

    onMaxWidthChanged: relayout.restart()
    Timer {
        id: relayout
        interval: 30
        onTriggered: root.measure()
    }

    RowLayout {
    id: row
    anchors.fill: parent
    spacing: root.spacing

    // ── » overflow ───────────────────────────────────────────────────────
    Item {
        id: more
        readonly property bool lit: MenuState.open && MenuState.mode === "extra" && MenuState.extra === "overflow" && MenuState.screen === root.screenName
        visible: root.firstFit > 0 || root.tuckedTray.length > 0
        implicitWidth: 24
        implicitHeight: 22
        onVisibleChanged: relayout.restart()

        Rectangle {
            anchors.fill: parent
            radius: 6
            color: more.lit ? Theme.withAlpha(root.fg, 0.18) : moreMouse.containsMouse ? Theme.withAlpha(root.fg, 0.08) : "transparent"
        }
        Text {
            anchors.centerIn: parent
            text: "»"
            color: root.fg
            font.family: Theme.fontUi
            font.pixelSize: 15
            font.weight: Font.DemiBold
        }
        MouseArea {
            id: moreMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: MenuState.toggleExtra(root.screenName, "overflow", more, false)
            onContainsMouseChanged: if (containsMouse)
                MenuState.hoverExtra(root.screenName, "overflow", more)
        }
    }

    // ── The items ────────────────────────────────────────────────────────
    Repeater {
        id: items
        model: root.order

        delegate: Loader {
            id: slot
            required property string modelData
            required property int index
            readonly property string controlId: modelData
            readonly property bool wanted: root.wanted(modelData)
            readonly property bool dragging: drag.active && drag.id === modelData

            visible: wanted && index >= root.firstFit
            opacity: dragging ? 0.35 : 1
            Layout.alignment: Qt.AlignVCenter
            sourceComponent: {
                if (modelData.startsWith("readout."))
                    return readoutC;
                switch (modelData) {
                case "tray":
                    return trayC;
                case "micMute":
                    return micC;
                case "record":
                    return recordC;
                case "sound":
                    return soundC;
                case "wifi":
                    return wifiC;
                case "camera":
                    return cameraC;
                case "inputSource":
                    return inputC;
                case "clock":
                    return clockC;
                case "controlcenter":
                    return ccC;
                }
                return plainC;
            }
            onWantedChanged: relayout.restart()
            onImplicitWidthChanged: relayout.restart()
            onVisibleChanged: Qt.callLater(root.register)
        }
        onCountChanged: relayout.restart()
    }
    }

    // ── Item kinds ───────────────────────────────────────────────────────
    Component {
        id: plainC
        BarExtra {
            controlId: parent?.controlId ?? ""
            screenName: root.screenName
            dimmed: !Controls.active(controlId) && Controls.control(controlId)?.kind === "toggle"
        }
    }

    Component {
        id: readoutC
        Readouts {
            only: [(parent?.controlId ?? "").slice(8)]
            textColor: root.fg
            subColor: Theme.barSubtextFor(root.screenName)
        }
    }

    Component {
        id: trayC
        Tray {
            window: root.window
            items: root.pinnedTray
            fg: root.fg
        }
    }

    Component {
        id: micC
        MicIndicator {
            screenName: root.screenName
            always: !Controls.activeOnly("micMute")
        }
    }

    Component {
        id: recordC
        BarExtra {
            controlId: "record"
            screenName: root.screenName
            glyph: Recorder.active ? "" : "󰑋"
            label: Recorder.active ? `   ${FocusTimer.format(Recorder.elapsed)}` : ""
            // The stop square, as on macOS.
            Rectangle {
                visible: Recorder.active
                x: 7
                anchors.verticalCenter: parent.verticalCenter
                width: 9
                height: 9
                radius: 2
                color: Theme.urgent
            }
        }
    }

    Component {
        id: soundC
        BarExtra {
            id: snd
            controlId: "sound"
            screenName: root.screenName
            readonly property PwNode sink: Pipewire.defaultAudioSink
            readonly property bool ready: sink?.ready ?? false
            readonly property real volume: ready ? sink.audio.volume : 0
            readonly property bool muted: ready ? sink.audio.muted : true
            glyph: muted || volume <= 0 ? "󰝟" : Sound.isPersonal(sink) ? "󰋋" : volume >= 0.66 ? "󰕾" : volume >= 0.33 ? "󰖀" : "󰕿"
            dimmed: muted
            // Kept from the old volume item: scroll = volume, middle = mute,
            // right = mixer.
            onWheeled: wheel => {
                if (ready)
                    sink.audio.volume = Math.max(0, Math.min(1, sink.audio.volume + (wheel.angleDelta.y > 0 ? 0.05 : -0.05)));
            }
            onMiddleClicked: if (ready)
                sink.audio.muted = !sink.audio.muted
            onRightClicked: if (Features.on("mixer")) {
                MenuState.close();
                Sound.toggleMixer(root.screenName);
            }
            PwObjectTracker {
                objects: snd.sink ? [snd.sink] : []
            }
        }
    }

    Component {
        id: wifiC
        BarExtra {
            controlId: "wifi"
            screenName: root.screenName
            dimmed: !NetStatus.online
            // VPN badge.
            Rectangle {
                visible: NetStatus.vpnActive
                anchors {
                    right: parent.right
                    bottom: parent.bottom
                    rightMargin: 2
                    bottomMargin: 2
                }
                width: 9
                height: 9
                radius: 3
                color: Theme.withAlpha(root.fg, 0.9)
                Icon {
                    anchors.centerIn: parent
                    text: "󰌾"
                    size: 7
                    color: Theme.bg
                }
            }
        }
    }

    Component {
        id: cameraC
        BarExtra {
            controlId: "camera"
            screenName: root.screenName
            glyph: "󰄀"
            // The green "camera in use" dot.
            Rectangle {
                anchors {
                    right: parent.right
                    top: parent.top
                    rightMargin: 3
                    topMargin: 3
                }
                width: 6
                height: 6
                radius: 3
                color: Theme.ok
            }
        }
    }

    Component {
        id: inputC
        BarExtra {
            controlId: "inputSource"
            screenName: root.screenName
            readonly property string name: (Niri.keyboardLayouts.names ?? [])[Niri.keyboardLayouts.current_idx ?? 0] ?? ""
            // "English (US)" → "EN"; "German" → "DE"-ish: the first letters.
            label: {
                const m = name.match(/\(([A-Z]{2,3})\)/);
                return m ? m[1] : name.slice(0, 2).toUpperCase();
            }
        }
    }

    Component {
        id: clockC
        BarExtra {
            controlId: "clock"
            screenName: root.screenName
            readonly property bool showTime: Settings.menubar.clockTime === true
            label: Qt.formatDateTime(clock.date, showTime ? (Settings.menubar.clock24 ? "ddd MMM d  HH:mm" : "ddd MMM d  h:mm AP") : "ddd MMM d")
            SystemClock {
                id: clock
                precision: SystemClock.Minutes
            }
        }
    }

    Component {
        id: ccC
        BarExtra {
            controlId: "controlcenter"
            screenName: root.screenName
            glyph: "󰒓"
            Rectangle {
                anchors.fill: parent
                radius: 6
                z: -1
                color: Panels.controlCenterOpen && Panels.controlCenterScreen === root.screenName ? Theme.withAlpha(root.fg, 0.18) : "transparent"
            }
        }
    }

    // ── Super-drag: move along the bar, or off it to remove ──────────────
    // (z above the items; presses without Super fall through.)
    MouseArea {
        id: drag
        anchors.fill: parent
        z: 10
        property bool active: false
        property string id: ""
        property real px: 0
        property real py: 0
        readonly property bool removing: active && py > root.height + 24

        function slotAt(x) {
            for (let i = 0; i < items.count; i++) {
                const d = items.itemAt(i);
                if (d && d.visible && x >= d.x - 3 && x < d.x + d.width + 3)
                    return d;
            }
            return null;
        }

        onPressed: mouse => {
            if (!(mouse.modifiers & Qt.MetaModifier)) {
                mouse.accepted = false;
                return;
            }
            const d = slotAt(mouse.x);
            if (!d) {
                mouse.accepted = false;
                return;
            }
            MenuState.close();
            id = d.controlId;
            active = true;
            px = mouse.x;
            py = mouse.y;
        }
        onPositionChanged: mouse => {
            px = mouse.x;
            py = mouse.y;
        }
        onReleased: mouse => {
            if (!active)
                return;
            if (removing) {
                Controls.setOnBar(id, false);
            } else {
                // Before the first visible item whose centre is right of the drop.
                let before = "";
                for (let i = 0; i < items.count; i++) {
                    const d = items.itemAt(i);
                    if (d && d.visible && d.controlId !== id && d.x + d.width / 2 > mouse.x) {
                        before = d.controlId;
                        break;
                    }
                }
                Controls.moveBarItem(id, before);
            }
            active = false;
            id = "";
        }
    }

    // The dragged item's ghost + the drop marker.
    Item {
        z: 11
        visible: drag.active
        x: drag.px - 11
        y: drag.py - 11
        width: 22
        height: 22
        Rectangle {
            anchors.fill: parent
            radius: 6
            color: Theme.withAlpha(drag.removing ? Theme.urgent : Theme.accent, 0.35)
        }
        Icon {
            anchors.centerIn: parent
            text: drag.removing ? "󰅖" : Controls.iconOf(drag.id) || "󰍛"
            size: 14
            color: root.fg
        }
    }
}
