pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

// The notification daemon (org.freedesktop.Notifications) and the banner
// queue the island shows. Do Not Disturb keeps notifications in the history
// without bannering them.
//
// When niri runs nested inside another desktop, that desktop already owns
// the bus name and this server stays inactive; `qs ipc call notifications
// test` injects a sample banner to work on the UI anyway.
Singleton {
    id: root

    // Banners waiting to be shown; `current` is on screen.
    property var queue: []
    readonly property var current: queue.length > 0 ? queue[0] : null
    readonly property var history: server.trackedNotifications.values

    function next() {
        queue = queue.slice(1);
    }

    function activate(n) {
        // The "default" action, if the app offered one, else nothing.
        const action = (n.actions ?? []).find(a => a.identifier === "default") ?? null;
        if (action)
            action.invoke();
        else if (n.dismiss)
            n.dismiss();
        next();
    }

    function show(n) {
        // Critical notifications break through Do Not Disturb.
        if (Panels.doNotDisturb && n.urgency !== NotificationUrgency.Critical)
            return;
        queue = queue.concat([n]);
    }

    NotificationServer {
        id: server
        keepOnReload: true
        actionsSupported: true
        bodySupported: true
        bodyMarkupSupported: false
        imageSupported: true
        persistenceSupported: true

        onNotification: n => {
            n.tracked = true;
            root.show(n);
        }
    }

    IpcHandler {
        target: "notifications"

        function test(): void {
            root.show({
                appName: "studio",
                appIcon: "preferences-desktop-theme",
                summary: "Theme applied",
                body: "tokyonight — palette, glass and wallpaper updated across the desktop.",
                image: "",
                actions: []
            });
        }

        function clear(): void {
            root.queue = [];
        }
    }
}
