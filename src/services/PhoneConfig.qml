pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Settings of the iPhone module (Settings → Phone), in their own file —
// <state>/overrides/phone.json — like ClipboardConfig. What the phone and
// tetherd themselves remember (pairing, retention, call control) stays in
// tetherd's ~/.config/tether/bluetooth.json; Phone.qml asks for those over
// the socket.
Singleton {
    id: root

    readonly property string stateDir: Settings.stateDir
    readonly property string file: `${stateDir}/overrides/phone.json`

    // Banners and history for the iPhone's app notifications (tetherd raises
    // them as freedesktop notifications; off: Loft drops them).
    property alias notifications: cfg.notifications
    // Island banners for new messages, with Reply.
    property alias messages: cfg.messages
    // Message text in banners (off: "New message" only, like iOS's preview setting).
    property alias previews: cfg.previews
    // The incoming-call live activity and the call timer in the island.
    property alias calls: cfg.calls
    // tetherd's socket; "" = $XDG_RUNTIME_DIR/tetherd.sock. LOFT_TETHER_SOCKET wins.
    property alias socketPath: cfg.socketPath

    FileView {
        id: view
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onAdapterUpdated: writeAdapter()
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound)
                mkdir.running = true;
        }

        JsonAdapter {
            id: cfg
            property bool notifications: true
            property bool messages: true
            property bool previews: true
            property bool calls: true
            property string socketPath: ""
        }
    }

    Component.onCompleted: view.path = file

    Process {
        id: mkdir
        command: ["mkdir", "-p", `${root.stateDir}/overrides`]
        onExited: {
            view.writeAdapter();
            view.path = "";
            view.path = root.file;
        }
    }
}
