pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The app switcher's IPC (`qs ipc call switcher next|prev|commit|cancel`),
// registered once for all screens (a handler per Switcher left all but the
// first unregistered). Each Switcher acts only on its own screen.
Singleton {
    id: root

    signal command(string cmd)

    IpcHandler {
        target: "switcher"

        function next(): void {
            root.command("next");
        }
        function prev(): void {
            root.command("prev");
        }
        function commit(): void {
            root.command("commit");
        }
        function cancel(): void {
            root.command("cancel");
        }
    }
}
