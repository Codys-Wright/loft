import QtQuick
import QtQuick.Layouts
import qs.services

// Hosts one control's panel by id — the same component in a menu bar
// dropdown (MenuOverlay) and in an expanded Control Center module.
Item {
    id: host

    property string panel: ""
    property bool details: false
    property bool shown: true
    property bool inMenu: true
    property string screenName: ""
    // The window the host lives in (tray menus in the overflow anchor to it).
    property var window: null

    signal dismiss
    signal openSettings(string section)
    signal openControl(string id)

    readonly property var item: loader.item
    implicitWidth: 300
    implicitHeight: loader.item ? loader.item.implicitHeight : 0

    // Esc inside: let the panel back out of an inline entry first.
    function back() {
        return loader.item && typeof loader.item.back === "function" ? loader.item.back() : false;
    }

    readonly property var components: ({
            wifi: wifi,
            bluetooth: bluetooth,
            sound: sound,
            nowPlaying: nowPlaying,
            focus: focus,
            display: display,
            battery: battery,
            clock: clock,
            camera: privacy,
            inputSource: inputSource,
            caffeine: keepAwake,
            phone: phone,
            overflow: overflow
        })

    Loader {
        id: loader
        width: host.width
        sourceComponent: host.components[host.panel] ?? null
    }

    Connections {
        target: loader.item
        ignoreUnknownSignals: true
        function onDismiss() {
            host.dismiss();
        }
        function onOpenSettings(section) {
            host.openSettings(section);
        }
        function onOpenControl(id) {
            host.openControl(id);
        }
    }

    Component {
        id: wifi
        WifiPanel {
            details: host.details
            shown: host.shown
            inMenu: host.inMenu
        }
    }
    Component {
        id: bluetooth
        BluetoothPanel {
            details: host.details
            shown: host.shown
            inMenu: host.inMenu
        }
    }
    Component {
        id: sound
        SoundPanel {
            details: host.details
            shown: host.shown
            inMenu: host.inMenu
            screenName: host.screenName
        }
    }
    Component {
        id: nowPlaying
        NowPlayingPanel {
            details: host.details
            shown: host.shown
            inMenu: host.inMenu
        }
    }
    Component {
        id: focus
        FocusPanel {
            details: host.details
            shown: host.shown
            inMenu: host.inMenu
        }
    }
    Component {
        id: display
        DisplayPanel {
            details: host.details
            shown: host.shown
            inMenu: host.inMenu
        }
    }
    Component {
        id: battery
        BatteryPanel {
            details: host.details
            shown: host.shown
            inMenu: host.inMenu
        }
    }
    Component {
        id: clock
        ClockPanel {
            details: host.details
            shown: host.shown
            inMenu: host.inMenu
        }
    }
    Component {
        id: privacy
        PrivacyPanel {
            details: host.details
            shown: host.shown
            inMenu: host.inMenu
        }
    }
    Component {
        id: inputSource
        InputSourcePanel {
            details: host.details
            shown: host.shown
            inMenu: host.inMenu
        }
    }
    Component {
        id: keepAwake
        KeepAwakePanel {
            details: host.details
            shown: host.shown
            inMenu: host.inMenu
        }
    }
    Component {
        id: phone
        PhonePanel {
            details: host.details
            shown: host.shown
            inMenu: host.inMenu
        }
    }
    Component {
        id: overflow
        OverflowPanel {
            screenName: host.screenName
            window: host.window
        }
    }
}
