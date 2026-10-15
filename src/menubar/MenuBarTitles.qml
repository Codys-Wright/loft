import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services

// The left of the bar, macOS style: the NixOS mark (the system menu, like
// the Apple menu; middle-click, or with the menu off a click: overview), the
// focused app's name in bold (its app menu), then its global menus
// (File Edit View …). Owns this screen's MenuOverlay.
RowLayout {
    id: root

    // The bar window and its screen.
    required property var window
    required property string screenName
    property int barHeight: 30

    // Width the whole row may take; global titles past it collapse into
    // a "»" menu.
    property real maxWidth: Infinity

    spacing: 2

    // This output's bar text color (light/dark from the wallpaper, Theme).
    readonly property color fg: Theme.barTextFor(screenName)

    readonly property var win: MenuState.window
    readonly property int fit: MenuState.fitOn(screenName)
    readonly property bool overflowing: fit < AppMenu.titles.length
    // Bumped after the titles are laid out anew, so dropdowns re-anchor.
    property int stamp: 0
    onImplicitWidthChanged: relayout.restart()

    Timer {
        id: relayout
        interval: 16
        onTriggered: root.stamp++
    }

    // x of title `index` in window (= screen) coordinates, for the dropdown.
    function titleX(index) {
        const item = index === MenuState.systemTitle ? mark : index === 0 ? appTitle : MenuState.isOverflow(screenName, index) ? more : globals.itemAt(index - 1);
        return item ? item.mapToItem(null, 0, 0).x : 0;
    }

    // How many global titles fit (delegates exist once the model settles).
    function measure() {
        let used = mark.implicitWidth + mark.Layout.rightMargin + appTitle.implicitWidth + spacing * 2;
        const room = maxWidth - used;
        let total = 0;
        for (let i = 0; i < globals.count; i++)
            total += (globals.itemAt(i)?.implicitWidth ?? 0) + spacing;
        if (total <= room) {
            MenuState.setFit(screenName, globals.count);
            return;
        }
        let n = 0;
        let w = more.implicitWidth + spacing;
        for (; n < globals.count; n++) {
            w += (globals.itemAt(n)?.implicitWidth ?? 0) + spacing;
            if (w > room)
                break;
        }
        MenuState.setFit(screenName, n);
    }
    onMaxWidthChanged: Qt.callLater(measure)

    // The OS mark, like the Apple menu: the NixOS logo (nf-linux-nixos).
    Item {
        id: mark
        readonly property bool lit: MenuState.open && MenuState.mode === "menu" && MenuState.screen === root.screenName && MenuState.current === MenuState.systemTitle

        Layout.rightMargin: 2
        implicitWidth: logo.implicitWidth + 16
        implicitHeight: 22

        Rectangle {
            anchors.fill: parent
            radius: 6
            color: mark.lit ? Theme.withAlpha(root.fg, 0.18) : markHover.containsMouse && MenuState.systemMenuOn ? Theme.withAlpha(root.fg, 0.1) : "transparent"
            Behavior on color {
                ColorAnimation {
                    duration: 120
                }
            }
        }

        Icon {
            id: logo
            anchors.centerIn: parent
            text: "\uf313"
            size: 16
            color: root.fg
        }

        MouseArea {
            id: markHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            cursorShape: Qt.PointingHandCursor
            onClicked: mouse => {
                if (mouse.button === Qt.MiddleButton || !MenuState.systemMenuOn) {
                    MenuState.close();
                    Niri.toggleOverview();
                } else
                    MenuState.toggleTitle(root.screenName, MenuState.systemTitle);
            }
            onContainsMouseChanged: if (containsMouse && MenuState.systemMenuOn)
                MenuState.hoverTitle(root.screenName, MenuState.systemTitle)
        }
    }

    Title {
        id: appTitle
        titleIndex: 0
        text: root.win ? Apps.name(root.win.app_id) : "Desktop"
        bold: true
        interactive: MenuState.appMenuOn
    }

    Repeater {
        id: globals
        model: AppMenu.titles

        delegate: Title {
            required property var modelData
            required property int index
            // Title indices: 0 is the app menu.
            titleIndex: index + 1
            text: modelData.label
            enabled: modelData.enabled !== false
            visible: index < root.fit
            onImplicitWidthChanged: Qt.callLater(root.measure)
        }
        onCountChanged: {
            Qt.callLater(root.measure);
            relayout.restart();
        }
    }

    Title {
        id: more
        visible: root.overflowing
        titleIndex: 1 + root.fit
        text: "»"
    }

    component Title: Item {
        id: title
        property int titleIndex: 0
        property string text
        property bool bold: false
        property bool interactive: true
        readonly property bool lit: MenuState.open && MenuState.mode === "menu" && MenuState.screen === root.screenName && MenuState.current === titleIndex

        implicitWidth: label.implicitWidth + 16
        implicitHeight: 22

        Rectangle {
            anchors.fill: parent
            radius: 6
            color: title.lit ? Theme.withAlpha(root.fg, 0.18) : hover.containsMouse && title.interactive ? Theme.withAlpha(root.fg, 0.1) : "transparent"
            Behavior on color {
                ColorAnimation {
                    duration: 120
                }
            }
        }

        Text {
            id: label
            anchors.centerIn: parent
            text: title.text
            color: root.fg
            opacity: title.enabled ? 1 : 0.45
            font.family: Theme.fontUi
            font.pixelSize: 13
            font.weight: title.bold ? Font.Bold : Font.Normal
        }

        MouseArea {
            id: hover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: title.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: {
                if (title.interactive)
                    MenuState.toggleTitle(root.screenName, title.titleIndex);
                else
                    Niri.toggleOverview();
            }
            onContainsMouseChanged: if (containsMouse && title.interactive)
                MenuState.hoverTitle(root.screenName, title.titleIndex)
        }
    }

    MenuOverlay {
        screen: root.window.screen
        screenName: root.screenName
        barHeight: root.barHeight
        titles: root
    }
}
