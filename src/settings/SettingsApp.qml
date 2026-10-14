import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.components
import qs.services

// Studio Settings: a floating glass window (like macOS System Settings) that
// edits the runtime overrides (Settings → overrides/shell.json). Everything
// applies live; `studio save` will promote it into Nix defaults.
// Open with Cmd+, (Mod+Comma), the Control Center, or IPC settings toggle.
Scope {
    id: root

    readonly property bool open: Panels.settingsOpen
    property string section: "appearance"

    readonly property var sections: [
        { id: "appearance", icon: "󰏘", label: "Appearance" },
        { id: "wallpaper", icon: "󰸉", label: "Wallpaper" },
        { id: "dock", icon: "󱂬", label: "Dock" },
        { id: "island", icon: "󰟜", label: "Dynamic Island" },
        { id: "about", icon: "󰋼", label: "About" }
    ]

    IpcHandler {
        target: "settings"

        function toggle(): void {
            Panels.settingsOpen = !Panels.settingsOpen;
        }
    }

    // ── Row building blocks ─────────────────────────────────────────────
    // Label (+ hint) on the left, the control (children) right-aligned.
    component Row_: Item {
        id: row
        property string label
        property string hint
        default property alias control: slot.data

        Layout.fillWidth: true
        implicitHeight: Math.max(labels.implicitHeight, slot.implicitHeight)

        ColumnLayout {
            id: labels
            anchors {
                left: parent.left
                right: slot.left
                rightMargin: 16
                verticalCenter: parent.verticalCenter
            }
            spacing: 1

            Text {
                Layout.fillWidth: true
                text: row.label
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            Text {
                Layout.fillWidth: true
                visible: text !== ""
                text: row.hint
                color: Theme.subtext
                font.family: Theme.fontUi
                font.pixelSize: 11
                elide: Text.ElideMiddle
            }
        }

        RowLayout {
            id: slot
            anchors {
                right: parent.right
                verticalCenter: parent.verticalCenter
            }
        }
    }

    component Switch_: Rectangle {
        id: sw
        property bool checked
        signal toggled(bool on)
        implicitWidth: 44
        implicitHeight: 26
        radius: 13
        color: checked ? Theme.accent : Theme.withAlpha(Theme.text, 0.2)

        Rectangle {
            width: 22
            height: 22
            radius: 11
            y: 2
            x: sw.checked ? sw.width - width - 2 : 2
            color: "white"
            Behavior on x {
                NumberAnimation {
                    duration: 150
                }
            }
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: sw.toggled(!sw.checked)
        }
    }

    component Slider_: Item {
        id: sl
        property real from: 0
        property real to: 1
        property real value: 0
        property real step: 0
        property string suffix: ""
        property int decimals: 0
        signal moved(real v)
        implicitWidth: 240
        implicitHeight: 26

        readonly property real t: (value - from) / (to - from)

        Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 56
            height: 6
            radius: 3
            color: Theme.withAlpha(Theme.text, 0.15)

            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, sl.t))
                height: parent.height
                radius: 3
                color: Theme.accent
            }

            Rectangle {
                x: parent.width * Math.max(0, Math.min(1, sl.t)) - width / 2
                anchors.verticalCenter: parent.verticalCenter
                width: 18
                height: 18
                radius: 9
                color: "white"
                border.width: 1
                border.color: Theme.withAlpha("#000000", 0.15)
            }

            MouseArea {
                anchors.fill: parent
                anchors.margins: -8
                cursorShape: Qt.PointingHandCursor
                function set(x) {
                    let v = sl.from + Math.max(0, Math.min(1, x / track.width)) * (sl.to - sl.from);
                    if (sl.step > 0)
                        v = Math.round(v / sl.step) * sl.step;
                    sl.moved(v);
                }
                onPressed: mouse => set(mouse.x - 8)
                onPositionChanged: mouse => pressed && set(mouse.x - 8)
            }
        }

        Text {
            anchors {
                right: parent.right
                verticalCenter: parent.verticalCenter
            }
            text: sl.value.toFixed(sl.decimals) + sl.suffix
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 12
            font.features: { "tnum": 1 }
        }
    }

    component Card: GlassSurface {
        default property alias content: col.data
        Layout.fillWidth: true
        implicitHeight: col.implicitHeight + 28
        radius: 18
        showHighlight: false
        strength: 0.9

        ColumnLayout {
            id: col
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                margins: 14
            }
            spacing: 14
        }
    }

    // ── Window ──────────────────────────────────────────────────────────
    FloatingWindow {
        id: window
        visible: root.open
        title: "Studio Settings"
        implicitWidth: 820
        implicitHeight: 560
        color: "transparent"
        // Closing the window (niri's close-window, Escape) clears the state.
        onVisibleChanged: if (!visible)
            Panels.settingsOpen = false

        BackgroundEffect.blurRegion: Theme.blur ? blur : null
        Region {
            id: blur
            item: frame
            radius: frame.radius
        }

        GlassSurface {
            id: frame
            anchors.fill: parent
            radius: 24
            strength: 1.7

            focus: root.open
            Keys.onEscapePressed: Panels.settingsOpen = false

            RowLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 12

                // Sidebar
                ColumnLayout {
                    Layout.preferredWidth: 200
                    Layout.maximumWidth: 200
                    Layout.fillHeight: true
                    spacing: 4

                    Text {
                        Layout.leftMargin: 10
                        Layout.topMargin: 6
                        Layout.bottomMargin: 8
                        text: "Settings"
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 18
                        font.weight: Font.DemiBold
                    }

                    Repeater {
                        model: root.sections
                        delegate: Rectangle {
                            id: item
                            required property var modelData
                            readonly property bool current: root.section === modelData.id
                            Layout.fillWidth: true
                            Layout.preferredHeight: 36
                            radius: 10
                            color: current ? Theme.accent : mouse.containsMouse ? Theme.withAlpha(Theme.text, 0.08) : "transparent"

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                spacing: 10

                                Icon {
                                    text: item.modelData.icon
                                    size: 15
                                    color: item.current ? Theme.bg : Theme.text
                                }
                                Text {
                                    Layout.fillWidth: true
                                    text: item.modelData.label
                                    color: item.current ? Theme.bg : Theme.text
                                    font.family: Theme.fontUi
                                    font.pixelSize: 13
                                }
                            }

                            MouseArea {
                                id: mouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.section = item.modelData.id
                            }
                        }
                    }

                    Item {
                        Layout.fillHeight: true
                    }
                }

                // Content
                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.preferredWidth: 560
                    contentHeight: pages.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    ColumnLayout {
                        id: pages
                        width: parent.width
                        spacing: 12

                        Text {
                            Layout.topMargin: 6
                            text: root.sections.find(s => s.id === root.section)?.label ?? ""
                            color: Theme.text
                            font.family: Theme.fontUi
                            font.pixelSize: 22
                            font.weight: Font.DemiBold
                        }

                        // Appearance
                        Card {
                            visible: root.section === "appearance"

                            Row_ {
                                label: "Theme"
                                hint: "Switch with `studio theme apply <name>` — the theme picker is coming"
                                Text {
                                    text: Theme.name
                                    color: Theme.accent
                                    font.family: Theme.fontUi
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                }
                            }

                            Row_ {
                                label: "Background blur"
                                hint: Settings.appearance.blur < 0 ? "Following the theme" : "Overridden"
                                Switch_ {
                                    checked: Theme.blur
                                    onToggled: on => Settings.appearance.blur = on ? 1 : 0
                                }
                            }

                            Row_ {
                                label: "Glass opacity"
                                hint: Settings.appearance.glassOpacity < 0 ? "Following the theme" : "Overridden"
                                Slider_ {
                                    from: 0.1
                                    to: 0.95
                                    step: 0.01
                                    decimals: 2
                                    value: Theme.glassOpacity
                                    onMoved: v => Settings.appearance.glassOpacity = v
                                }
                            }

                            Text {
                                visible: Settings.appearance.blur >= 0 || Settings.appearance.glassOpacity >= 0
                                text: "Reset to theme"
                                color: Theme.accent
                                font.family: Theme.fontUi
                                font.pixelSize: 12
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        Settings.appearance.blur = -1;
                                        Settings.appearance.glassOpacity = -1;
                                    }
                                }
                            }
                        }

                        // Wallpaper
                        Card {
                            visible: root.section === "wallpaper"

                            Row_ {
                                label: "Current"
                                hint: Settings.wallpaper.path || "The theme's wallpaper"
                                Text {
                                    text: "Choose…"
                                    color: Theme.accent
                                    font.family: Theme.fontUi
                                    font.pixelSize: 13
                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -6
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: Panels.wallpaperPickerOpen = true
                                    }
                                }
                            }

                            Row_ {
                                label: "Folder"
                                hint: Settings.wallpaper.directory
                            }
                        }

                        // Dock
                        Card {
                            visible: root.section === "dock"

                            Row_ {
                                label: "Icon size"
                                Slider_ {
                                    from: 32
                                    to: 80
                                    step: 1
                                    suffix: " px"
                                    value: Settings.dock.iconSize
                                    onMoved: v => Settings.dock.iconSize = v
                                }
                            }

                            Row_ {
                                label: "Magnification"
                                Slider_ {
                                    from: 1
                                    to: 2
                                    step: 0.05
                                    decimals: 2
                                    suffix: "×"
                                    value: Settings.dock.magnification
                                    onMoved: v => Settings.dock.magnification = v
                                }
                            }

                            Row_ {
                                label: "Pinned apps"
                                hint: "× to unpin"
                            }

                            Flow {
                                Layout.fillWidth: true
                                spacing: 8

                                Repeater {
                                    model: Settings.dock.pinned
                                    delegate: Rectangle {
                                        id: pin
                                        required property string modelData
                                        required property int index
                                        width: pinRow.implicitWidth + 20
                                        height: 34
                                        radius: 17
                                        color: Theme.withAlpha(Theme.text, 0.08)

                                        RowLayout {
                                            id: pinRow
                                            anchors.centerIn: parent
                                            spacing: 8

                                            Image {
                                                Layout.preferredWidth: 20
                                                Layout.preferredHeight: 20
                                                source: Apps.icon(pin.modelData)
                                                sourceSize: Qt.size(40, 40)
                                            }
                                            Text {
                                                text: Apps.name(pin.modelData)
                                                color: Theme.text
                                                font.family: Theme.fontUi
                                                font.pixelSize: 12
                                            }
                                            Icon {
                                                text: "󰅖"
                                                size: 12
                                                color: Theme.subtext
                                                MouseArea {
                                                    anchors.fill: parent
                                                    anchors.margins: -6
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        const l = Array.from(Settings.dock.pinned);
                                                        l.splice(pin.index, 1);
                                                        Settings.dock.pinned = l;
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Island
                        Card {
                            visible: root.section === "island"

                            Row_ {
                                label: "Overheat alert"
                                hint: "Border pulses red above this temperature"
                                Slider_ {
                                    from: 60
                                    to: 105
                                    step: 1
                                    suffix: " °C"
                                    value: Settings.island.maxTemp
                                    onMoved: v => Settings.island.maxTemp = v
                                }
                            }

                            Row_ {
                                label: "Load alert"
                                hint: "CPU or memory use that turns the border amber"
                                Slider_ {
                                    from: 0.5
                                    to: 1
                                    step: 0.01
                                    decimals: 2
                                    value: Settings.island.maxLoad
                                    onMoved: v => Settings.island.maxLoad = v
                                }
                            }

                            Row_ {
                                label: "Focus session"
                                Slider_ {
                                    from: 5
                                    to: 90
                                    step: 5
                                    suffix: " min"
                                    value: Settings.island.focusMinutes
                                    onMoved: v => Settings.island.focusMinutes = v
                                }
                            }
                        }

                        // About
                        Card {
                            visible: root.section === "about"

                            Row_ {
                                label: "studio-linux"
                                hint: "niri + Quickshell · github.com/Codys-Wright/studio-linux"
                            }
                            Row_ {
                                label: "Settings file"
                                hint: Settings.file
                            }
                            Row_ {
                                label: "Design"
                                hint: "Liquid Glass components ported from javiiervm/dotfiles"
                            }
                        }
                    }
                }
            }
        }
    }
}
