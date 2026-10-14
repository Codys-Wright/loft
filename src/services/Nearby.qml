pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// "Nearby share" for the Control Center's Connectivity module (macOS's
// AirDrop button): LocalSend or KDE Connect, whichever is installed. With
// neither, the button hides.
Singleton {
    id: root

    property string command: ""
    readonly property bool available: command !== ""
    readonly property string label: command.includes("kdeconnect") ? "KDE Connect" : "LocalSend"

    function open() {
        if (available) {
            Panels.controlCenterOpen = false;
            Quickshell.execDetached([command]);
        }
    }

    Process {
        running: true
        command: ["sh", "-c", "for c in localsend_app localsend kdeconnect-app; do command -v $c && exit 0; done; exit 0"]
        stdout: StdioCollector {
            onStreamFinished: root.command = text.trim().split("\n")[0] ?? ""
        }
    }
}
