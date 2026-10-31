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

    // Banners waiting to be shown; `current` is on screen. `arrived`: when
    // each was queued (ms), same order.
    property var queue: []
    property var arrived: []
    readonly property var current: queue.length > 0 ? queue[0] : null
    readonly property var history: server.trackedNotifications.values

    // A backlog never takes minutes to get through: a banner that waited
    // longer than this is skipped (it stays in the history), and past
    // `maxWaiting` behind the one on screen the rest fold into one
    // "N more notifications" banner that opens the history.
    readonly property int staleMs: 15000
    readonly property int maxWaiting: 3

    function clearHistory() {
        for (const n of history.slice())
            n.dismiss();
    }

    // The banner on screen goes; `n`: only if it is still that one (each
    // display's island times the same banner).
    function next(n) {
        if (queue.length === 0 || (n !== undefined && queue[0] !== n))
            return;
        let q = queue.slice(1), at = arrived.slice(1);
        const now = Date.now();
        while (q.length > 0 && !q[0].digest && now - at[0] > staleMs) {
            q = q.slice(1);
            at = at.slice(1);
        }
        queue = q;
        arrived = at;
    }

    // Every waiting banner, the one on screen too (swipe up, IPC).
    function clearQueue() {
        queue = [];
        arrived = [];
    }

    // How long a banner stays (hovering holds it): 3 s; 1.5 s for passing
    // confirmations, transient ones and niri's "Screenshot captured" (niri
    // only notifies after encoding the PNG, a couple of seconds after the
    // shutter), and for every banner while more are waiting.
    function duration(n) {
        if (!n)
            return 3000;
        return queue.length > 1 || n.transient === true || n.appName === "niri" ? 1500 : 3000;
    }

    function enqueue(n) {
        const now = Date.now();
        const tail = queue.length > 1 ? queue[queue.length - 1] : null;
        if (tail?.digest) {
            queue = queue.slice(0, -1).concat([digest(tail.digest + 1, tail.apps.concat([appLabel(n)]))]);
            arrived = arrived.slice(0, -1).concat([now]);
        } else if (queue.length > maxWaiting) {
            // Fold everything behind the banner on screen into one.
            const rest = queue.slice(1).concat([n]);
            queue = [queue[0], digest(rest.length, rest.map(x => appLabel(x)))];
            arrived = [arrived[0], now];
        } else {
            queue = queue.concat([n]);
            arrived = arrived.concat([now]);
        }
    }

    function digest(count, apps) {
        const names = [...new Set(apps.filter(a => a))];
        return {
            digest: count,
            apps: apps,
            appName: "Notifications",
            appIcon: "preferences-system-notifications",
            glyph: "󰂚",
            summary: `${count} more notifications`,
            body: (names.slice(0, 3).join(", ") + (names.length > 3 ? ` and ${names.length - 3} more` : "")) + " · click for Notification Center",
            image: "",
            actions: []
        };
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
        // The folded backlog: open the history (the clock's panel).
        if (n?.digest) {
            MenuState.openExtra(Displays.activeName || Quickshell.screens[0]?.name, "clock", null, false);
            next(n);
            return;
        }
        // tetherd's Messages popup: open the conversation in Loft rather
        // than tether's own reply dialog.
        if (isPhone(n) && !n.phone && Features.on("phone") && phoneApp(n) === "Messages" && Phone.up) {
            Phone.openByName(n.summary ?? "");
            n.dismiss();
            next(n);
            return;
        }
        // The "default" action, if the app offered one, else nothing.
        const action = (n.actions ?? []).find(a => a.identifier === "default") ?? null;
        if (action)
            action.invoke();
        else if (n.dismiss)
            n.dismiss();
        next(n);
    }

    function show(n) {
        // Critical notifications break through Do Not Disturb, and so do
        // the apps a space's Focus allows (Spaces.dndAllow, SPACES §5).
        if (Panels.doNotDisturb && n.urgency !== NotificationUrgency.Critical && !Spaces.dndAllow.some(a => a.toLowerCase() === String(n.appName ?? "").toLowerCase()))
            return;
        enqueue(n);
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
            // keepOnReload hands every tracked notification over again
            // after a reload (Quickshell marks them lastGeneration): back
            // into the history, not the banner queue — else each reload
            // bannered the whole history, one after another for minutes.
            if (n.lastGeneration) {
                n.tracked = true;
                return;
            }
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
            root.clearQueue();
        }

        // Banners waiting (tests).
        function pending(): int {
            return root.queue.length;
        }
    }
}
