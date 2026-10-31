import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.components
import qs.services

// ⌘Tab app switcher (javiiervm's AltTabOverlay, on niri). niri binds
// ⌘Tab / ⌘⇧Tab to `switcher next|prev` (niri/shell-binds.kdl.in); the first
// call takes the keyboard, so letting go of ⌘ commits (focuses the selected
// app's most recent window) and Escape cancels. Like niri's own switcher the
// panel shows only after `showDelay`: a quick tap goes back to the previous
// app without flashing it. ⌥Tab and ⌘` are niri's window switcher.
//
// `switcher windows` (⌃↓, macOS App Exposé) opens it on the focused app's
// windows instead, one entry per window, and leaves it open (no modifier to
// let go of): ←→ / hover pick, Return / click focuses, Escape closes.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    property bool open: false
    // The panel appears once ⌘ has been held this long (niri's open-delay-ms).
    readonly property int showDelay: 120
    property int selected: 0
    // One entry per app, most recently focused first: { appId, windows[] }.
    // In the windows mode, one entry per window of the focused app.
    property var apps: []
    // The windows mode (App Exposé): stays open until a pick or Escape.
    property bool windowsMode: false

    readonly property bool onThisScreen: (Niri.focusedWorkspace?.output ?? modelData.name) === modelData.name

    visible: open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:switcher"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: Math.max(240, row.implicitWidth + 40)
    implicitHeight: 170
    color: "transparent"

    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur && open && panel.opacity > 0 ? panel : null
        radius: panel.radius
    }

    function stamp(w) {
        return w.focus_timestamp ? w.focus_timestamp.secs * 1e9 + w.focus_timestamp.nanos : 0;
    }

    function snapshot() {
        const byApp = {};
        for (const w of Niri.windows.slice().sort((a, b) => stamp(b) - stamp(a))) {
            const id = w.app_id || "unknown";
            if (!byApp[id])
                byApp[id] = { appId: id, windows: [] };
            byApp[id].windows.push(w);
        }
        return Object.values(byApp);
    }

    // App Exposé: the focused app's windows, most recent first (the focused
    // one selected). A second ⌃↓ closes it, like macOS.
    function showWindows() {
        if (!onThisScreen)
            return;
        if (open) {
            open = false;
            return;
        }
        const appId = Niri.focusedWindow?.app_id;
        if (!appId)
            return;
        apps = Niri.windows.filter(w => w.app_id === appId).sort((a, b) => stamp(b) - stamp(a)).map(w => ({
                    appId: appId,
                    windows: [w]
                }));
        selected = 0;
        windowsMode = true;
        open = true;
        showTimer.stop();
        panel.opacity = 1;
    }

    function step(delta) {
        if (!onThisScreen)
            return;
        if (!open) {
            apps = snapshot();
            if (apps.length === 0)
                return;
            // Like macOS: the first press selects the previous app.
            selected = apps.length > 1 ? (delta > 0 ? 1 : apps.length - 1) : 0;
            open = true;
            showTimer.restart();
            return;
        }
        selected = (selected + delta + apps.length) % apps.length;
        // Stepping again means ⌘ is held: show the panel now.
        showTimer.stop();
        panel.opacity = 1;
    }

    function commit() {
        if (open && apps[selected])
            Niri.focusWindow(apps[selected].windows[0].id);
        open = false;
    }

    onOpenChanged: if (!open) {
        windowsMode = false;
        showTimer.stop();
        panel.opacity = 0;
    }

    Timer {
        id: showTimer
        interval: root.showDelay
        onTriggered: panel.opacity = 1
    }

    // IPC (SwitcherIpc, one handler for all screens).
    Connections {
        target: SwitcherIpc
        function onCommand(cmd) {
            if (cmd === "next")
                root.step(1);
            else if (cmd === "prev")
                root.step(-1);
            else if (cmd === "commit")
                root.commit();
            else if (cmd === "cancel")
                root.open = false;
            else if (cmd === "windows")
                root.showWindows();
        }
    }

    GlassSurface {
        id: panel
        anchors.fill: parent
        radius: 30
        strength: 1.6
        opacity: 0

        focus: root.open
        Keys.onReleased: event => {
            // ⌘ let go → commit. ⌘ is Super, the Level3 key (AltGr /
            // Mode_switch) with lv3:lwin_switch, or Alt when niri is nested.
            // Not in the windows mode: ⌃↓ arrives with a Mod that xremap
            // lets go of at once.
            if (!root.windowsMode && [Qt.Key_Alt, Qt.Key_AltGr, Qt.Key_Mode_switch, Qt.Key_Super_L, Qt.Key_Super_R, Qt.Key_Meta].includes(event.key))
                root.commit();
        }
        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape)
                root.open = false;
            else if (event.key === Qt.Key_Return)
                root.commit();
            else if (event.key === Qt.Key_Right || event.key === Qt.Key_Tab)
                root.step(1);
            else if (event.key === Qt.Key_Left || event.key === Qt.Key_Backtab)
                root.step(-1);
        }

        ColumnLayout {
            anchors.centerIn: parent
            spacing: 12

            RowLayout {
                id: row
                Layout.alignment: Qt.AlignHCenter
                spacing: 14

                Repeater {
                    model: root.apps

                    delegate: Rectangle {
                        id: cell
                        required property var modelData
                        required property int index
                        readonly property bool current: index === root.selected

                        Layout.preferredWidth: 96
                        Layout.preferredHeight: 96
                        radius: 22
                        color: current ? Theme.withAlpha(Theme.text, 0.18) : "transparent"
                        border.width: current ? 1 : 0
                        border.color: Theme.glassBorder

                        AppIcon {
                            anchors.centerIn: parent
                            width: 72
                            height: 72
                            appId: cell.modelData.appId
                        }

                        // Window count badge for apps with several windows.
                        Rectangle {
                            visible: cell.modelData.windows.length > 1
                            anchors {
                                right: parent.right
                                top: parent.top
                                margins: 4
                            }
                            width: 20
                            height: 20
                            radius: 10
                            color: Theme.accent

                            Text {
                                anchors.centerIn: parent
                                text: cell.modelData.windows.length
                                color: Theme.bg
                                font.family: Theme.fontUi
                                font.pixelSize: 11
                                font.weight: Font.Bold
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: root.selected = cell.index
                            onClicked: root.commit()
                        }
                    }
                }
            }

            Text {
                Layout.alignment: Qt.AlignHCenter
                Layout.maximumWidth: root.implicitWidth - 60
                readonly property var app: root.apps[root.selected]
                text: app ? `${Apps.name(app.appId)}  —  ${app.windows[0].title ?? ""}` : ""
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 14
                font.weight: Font.Medium
                elide: Text.ElideRight
            }
        }
    }
}
