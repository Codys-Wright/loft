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

    function clearHistory() {
        for (const n of history.slice())
            n.dismiss();
    }

    function next() {
        queue = queue.slice(1);
    }

    // ── From the iPhone ─────────────────────────────────────────────────
    // tetherd (Phone.qml) raises the phone's app notifications itself, as
    // libnotify app "Tether" with desktop-entry=tether-gtk and KDE's
    // x-kde-origin-name=iPhone / x-kde-display-appname=<iPhone app> hints;
    // Loft's own message banners carry `phone: true`.
    function hint(n, key) {
        try {
            return n?.hints ? (n.hints[key] ?? "") : "";
        } catch (e) {
            return "";
        }
    }
    function isPhone(n) {
        if (!n)
            return false;
        return n.phone === true || n.desktopEntry === "tether-gtk" || hint(n, "x-kde-origin-name") === "iPhone";
    }
    // The iPhone app's name ("Instagram"), not "Tether".
    function phoneApp(n) {
        return hint(n, "x-kde-display-appname") || (n?.phone ? n.appName : "") || "iPhone";
    }
    // The app line of a banner / history row: "Instagram · iPhone".
    function appLabel(n) {
        if (!n)
            return "";
        return isPhone(n) ? `${phoneApp(n)} · iPhone` : (n.appName ?? "");
    }

    function activate(n) {
        // tetherd's Messages popup: open the conversation in Loft rather
        // than tether's own reply dialog.
        if (isPhone(n) && !n.phone && Features.on("phone") && phoneApp(n) === "Messages" && Phone.up) {
            Phone.openByName(n.summary ?? "");
            n.dismiss();
            next();
            return;
        }
        // The "default" action, if the app offered one, else nothing.
        const action = (n.actions ?? []).find(a => a.identifier === "default") ?? null;
        if (action)
            action.invoke();
        else if (n.dismiss)
            n.dismiss();
        next();
    }

    function show(n) {
        // Critical notifications break through Do Not Disturb, and so do
        // the apps a space's Focus allows (Spaces.dndAllow, SPACES §5).
        if (Panels.doNotDisturb && n.urgency !== NotificationUrgency.Critical && !Spaces.dndAllow.some(a => a.toLowerCase() === String(n.appName ?? "").toLowerCase()))
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
            if (root.isPhone(n) && Features.on("phone")) {
                // Settings → Phone → Notifications off: the phone's are dropped.
                if (!PhoneConfig.notifications) {
                    n.dismiss();
                    return;
                }
                n.tracked = true;
                // A new message already has Loft's banner (with Reply) from
                // the socket: keep tetherd's copy in the history only.
                if (root.phoneApp(n) === "Messages" && Phone.up && PhoneConfig.messages)
                    return;
                root.show(n);
                return;
            }
            n.tracked = true;
            root.show(n);
        }
    }

    IpcHandler {
        target: "notifications"

        function test(): void {
            root.show({
                appName: "loft",
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

        // Banners waiting (tests).
        function pending(): int {
            return root.queue.length;
        }
    }
}
