import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.components
import qs.services

// The left of the bar, macOS style: the studio mark (overview), the
// focused app's name in bold (its app menu), then its global menus
// (File Edit View …). Owns this screen's MenuOverlay.
RowLayout {
    id: root

    // The bar window and its screen.
    required property var window
    required property string screenName

    // Width the whole row may take; global titles past it collapse into
    // a "»" menu.
    property real maxWidth: Infinity

    spacing: 2

    readonly property var win: MenuState.window
    readonly property int fit: MenuState.fitOn(screenName)
    readonly property bool overflowing: fit < AppMenu.titles.length

    // x of title `index` in window (= screen) coordinates, for the dropdown.
    function titleX(index) {
        const item = index === 0 ? appTitle : MenuState.isOverflow(screenName, index) ? more : globals.itemAt(index - 1);
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

    Icon {
        id: mark
        Layout.rightMargin: 6
        text: "󰽰"
        size: 18
        color: Theme.accent

        MouseArea {
            anchors.fill: parent
            anchors.margins: -6
            cursorShape: Qt.PointingHandCursor
            onClicked: Niri.toggleOverview()
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
        onCountChanged: Qt.callLater(root.measure)
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

        implicitWidth: label.implicitWidth + 18
        implicitHeight: 26

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: title.lit ? Theme.withAlpha(Theme.text, 0.16) : hover.containsMouse && title.interactive ? Theme.withAlpha(Theme.text, 0.08) : "transparent"
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
            color: Theme.text
            opacity: title.enabled ? 1 : 0.45
            font.family: Theme.fontUi
            font.pixelSize: title.bold ? 14 : 13
            font.weight: title.bold ? Font.DemiBold : Font.Medium
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
        titles: root
    }
}
