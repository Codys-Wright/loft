import QtQuick
import QtQuick.Layouts
import qs.services

// The frame of the shell's own windows (Settings, System Monitor,
// Scratchpad …), Golden Gate style: one glass surface with the theme's
// window radius (niri clips every window to the same one), an optional
// edge-to-edge full-height sidebar (no inset, no shadow; SidebarItem rows
// with colored badges), a uniform toolbar (title + `toolbar` items on the
// right; drag it to move the window) and the traffic lights. The glass dims
// slightly while the window is in the background.
//
//   FloatingWindow {
//       id: window
//       color: "transparent"
//       BackgroundEffect.blurRegion: blur
//       Region { id: blur; item: Theme.blur ? chrome.surface : null; radius: chrome.radius }
//       WindowChrome {
//           id: chrome
//           hostWindow: window
//           title: "Page"
//           sidebar: [ SidebarItem { … } ]
//           toolbar: [ … ]
//           onCloseRequested: …
//           Item { … }            // content, below the toolbar
//       }
//   }
Item {
    id: root

    required property var hostWindow
    property string title
    // 0: no sidebar (the traffic lights move into the toolbar).
    property real sidebarWidth: 220
    readonly property bool hasSidebar: sidebarWidth > 0
    // A search field at the top of the sidebar; read `searchText`.
    property bool searchable: false
    readonly property string searchText: search.text
    property bool canHide: true
    property bool canFullscreen: true

    readonly property bool fullscreen: hostWindow?.fullscreen ?? false
    // Active = niri's focused window is this one.
    readonly property bool active: {
        if (!Niri.available)
            return true;
        const w = Niri.focusedWindow;
        return w !== null && w.title === (hostWindow?.title ?? "") && (w.app_id ?? "").indexOf("quickshell") >= 0;
    }
    readonly property alias surface: frame
    readonly property real radius: fullscreen ? 0 : Theme.windowRadius
    readonly property int toolbarHeight: 52

    default property alias content: contentSlot.data
    property alias sidebar: sidebarColumn.data
    property alias toolbar: toolbarSlot.data

    signal closeRequested
    // niri has no minimize; by default hiding closes (the owner keeps state).
    signal hideRequested

    function toggleFullscreen() {
        if (root.hostWindow)
            root.hostWindow.fullscreen = !root.hostWindow.fullscreen;
    }

    function startMove() {
        if (root.hostWindow && !root.fullscreen)
            root.hostWindow.startSystemMove();
    }

    anchors.fill: parent

    GlassSurface {
        id: frame
        anchors.fill: parent
        radius: root.radius
        strength: 1.7
        active: root.active

        // ── Sidebar: flush, full height ─────────────────────────────────
        Item {
            id: sidebarPane
            visible: root.hasSidebar
            width: root.sidebarWidth
            anchors {
                top: parent.top
                bottom: parent.bottom
                left: parent.left
            }

            Rectangle {
                anchors.fill: parent
                topLeftRadius: root.radius
                bottomLeftRadius: root.radius
                color: Theme.withAlpha(Theme.dark ? "#ffffff" : "#000000", 0.035)
            }

            Rectangle {
                anchors {
                    top: parent.top
                    bottom: parent.bottom
                    right: parent.right
                }
                width: 1
                color: Theme.withAlpha(Theme.text, 0.09)
            }

            MouseArea {
                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                }
                height: root.toolbarHeight
                onPressed: root.startMove()
            }

            TrafficLights {
                x: 18
                y: (root.toolbarHeight - height) / 2
                active: root.active
                canHide: root.canHide
                canFullscreen: root.canFullscreen
                onClose: root.closeRequested()
                onHide: root.hideRequested()
                onFullscreen: root.toggleFullscreen()
            }

            ColumnLayout {
                anchors {
                    fill: parent
                    topMargin: root.toolbarHeight
                    leftMargin: 10
                    rightMargin: 10
                    bottomMargin: 10
                }
                spacing: 8

                // Search
                Rectangle {
                    visible: root.searchable
                    Layout.fillWidth: true
                    Layout.preferredHeight: 28
                    radius: Theme.controlRadius
                    color: Theme.withAlpha(Theme.text, search.activeFocus ? 0.1 : 0.065)
                    border.width: search.activeFocus ? 1 : 0
                    border.color: Theme.withAlpha(Theme.accent, 0.7)

                    Text {
                        id: glass
                        anchors {
                            left: parent.left
                            leftMargin: 8
                            verticalCenter: parent.verticalCenter
                        }
                        text: "󰍉"
                        color: Theme.subtext
                        font.family: Theme.fontIcons
                        font.pixelSize: 13
                    }

                    TextInput {
                        id: search
                        anchors {
                            left: glass.right
                            leftMargin: 6
                            right: parent.right
                            rightMargin: 8
                            verticalCenter: parent.verticalCenter
                        }
                        color: Theme.text
                        selectionColor: Theme.withAlpha(Theme.accent, 0.4)
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                        clip: true
                        Keys.onEscapePressed: event => {
                            if (text !== "") {
                                text = "";
                                event.accepted = true;
                            } else {
                                event.accepted = false;
                            }
                        }

                        Text {
                            visible: search.text === ""
                            text: "Search"
                            color: Theme.subtext
                            font: search.font
                        }
                    }
                }

                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: sidebarColumn.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: sidebarColumn
                        width: parent.width
                        spacing: 2
                    }
                }
            }
        }

        // ── Toolbar + content ───────────────────────────────────────────
        Item {
            id: main
            anchors {
                left: root.hasSidebar ? sidebarPane.right : parent.left
                right: parent.right
                top: parent.top
                bottom: parent.bottom
            }

            Item {
                id: toolbarBar
                anchors {
                    left: parent.left
                    right: parent.right
                    top: parent.top
                }
                height: root.toolbarHeight

                MouseArea {
                    anchors.fill: parent
                    onPressed: root.startMove()
                }

                RowLayout {
                    anchors {
                        left: parent.left
                        right: parent.right
                        leftMargin: root.hasSidebar ? 22 : 18
                        rightMargin: 14
                        verticalCenter: parent.verticalCenter
                    }
                    spacing: 16

                    TrafficLights {
                        visible: !root.hasSidebar
                        active: root.active
                        canHide: root.canHide
                        canFullscreen: root.canFullscreen
                        onClose: root.closeRequested()
                        onHide: root.hideRequested()
                        onFullscreen: root.toggleFullscreen()
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.title
                        elide: Text.ElideRight
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 15
                        font.weight: Font.DemiBold
                    }

                    RowLayout {
                        id: toolbarSlot
                        spacing: 8
                    }
                }
            }

            Item {
                id: contentSlot
                anchors {
                    left: parent.left
                    right: parent.right
                    top: toolbarBar.bottom
                    bottom: parent.bottom
                }
            }
        }
    }
}
