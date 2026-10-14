import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.components
import qs.services

// Cmd+Tab app switcher (javiiervm's AltTabOverlay, on niri). niri binds
// Mod+Tab / Mod+Shift+Tab to `switcher next|prev`; the first call opens it
// with keyboard focus, so releasing the modifier commits (focuses the
// selected app's most recent window) and Escape cancels.
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    property bool open: false
    property int selected: 0
    // One entry per app, most recently focused first: { appId, windows[] }.
    property var apps: []

    readonly property bool onThisScreen: (Niri.focusedWorkspace?.output ?? modelData.name) === modelData.name

    visible: open
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:switcher"
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    implicitWidth: Math.max(240, row.implicitWidth + 40)
    implicitHeight: 170
    color: "transparent"

    BackgroundEffect.blurRegion: Theme.blur && open ? blur : null
    Region {
        id: blur
        item: panel
        radius: panel.radius
    }

    function snapshot() {
        const stamp = w => w.focus_timestamp ? w.focus_timestamp.secs * 1e9 + w.focus_timestamp.nanos : 0;
        const byApp = {};
        for (const w of Niri.windows.slice().sort((a, b) => stamp(b) - stamp(a))) {
            const id = w.app_id || "unknown";
            if (!byApp[id])
                byApp[id] = { appId: id, windows: [] };
            byApp[id].windows.push(w);
        }
        return Object.values(byApp);
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
            return;
        }
        selected = (selected + delta + apps.length) % apps.length;
    }

    function commit() {
        if (open && apps[selected])
            Niri.focusWindow(apps[selected].windows[0].id);
        open = false;
    }

    IpcHandler {
        target: "switcher"

        function next(): void {
            root.step(1);
        }

        function prev(): void {
            root.step(-1);
        }

        function commit(): void {
            root.commit();
        }

        function cancel(): void {
            root.open = false;
        }
    }

    GlassSurface {
        id: panel
        anchors.fill: parent
        radius: 30
        strength: 1.6

        focus: root.open
        Keys.onReleased: event => {
            // Modifier released → commit (Alt when nested, Super otherwise).
            if (event.key === Qt.Key_Alt || event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R || event.key === Qt.Key_Meta)
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

                        Image {
                            anchors.centerIn: parent
                            width: 72
                            height: 72
                            source: Apps.icon(cell.modelData.appId)
                            sourceSize: Qt.size(128, 128)
                            fillMode: Image.PreserveAspectFit
                            mipmap: true
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
