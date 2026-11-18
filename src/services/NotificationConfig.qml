pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Settings → Notifications: Do Not Disturb (by hand in Panels.doNotDisturb,
// here its schedule), how long banners stay, and per-app rules. Stored in
// $LOFT_STATE_DIR/overrides/notifications.json; services/Notifications.qml
// applies it.
//
// Apps are keyed by the app line of the banner (Notifications.appLabel:
// "Firefox", "Instagram · iPhone"). Every app that notifies is remembered
// in `seen` so the page can list it before a rule exists.
Singleton {
    id: root

    readonly property string stateDir: Settings.stateDir
    readonly property string file: `${stateDir}/overrides/notifications.json`

    readonly property alias schedule: cfg.schedule
    readonly property alias allowCritical: cfg.allowCritical
    readonly property alias bannerSeconds: cfg.bannerSeconds
    readonly property alias apps: cfg.apps
    readonly property alias seen: cfg.seen

    // ── Per app ──────────────────────────────────────────────────────────
    // { allow, banners }; a missing key = on.
    function rule(app) {
        const r = cfg.apps[app] ?? {};
        return {
            allow: r.allow !== false,
            banners: r.banners !== false
        };
    }

    function setRule(app, key, on) {
        const all = Object.assign({}, cfg.apps);
        const r = Object.assign({}, all[app] ?? {});
        r[key] = on;
        // Back to the default: drop it so the file stays small.
        if (r.allow !== false && r.banners !== false)
            delete all[app];
        else
            all[app] = r;
        cfg.apps = all;
    }

    // Remember an app that notified. Written at most once a day per app.
    function noteSeen(app, icon) {
        if (!app)
            return;
        const prev = cfg.seen[app];
        const now = Date.now();
        if (prev && now - (prev.last ?? 0) < 24 * 3600 * 1000 && (prev.icon ?? "") === (icon ?? ""))
            return;
        const all = Object.assign({}, cfg.seen);
        all[app] = {
            icon: icon ?? "",
            last: now
        };
        cfg.seen = all;
    }

    function forget(app) {
        const s = Object.assign({}, cfg.seen);
        delete s[app];
        cfg.seen = s;
        const a = Object.assign({}, cfg.apps);
        delete a[app];
        cfg.apps = a;
    }

    // ── Scheduled Do Not Disturb ─────────────────────────────────────────
    property date now: new Date()
    Timer {
        running: cfg.schedule.enabled
        interval: 30000
        repeat: true
        triggeredOnStart: true
        onTriggered: root.now = new Date()
    }

    function minutes(hhmm) {
        const m = String(hhmm ?? "").match(/^(\d{1,2}):(\d{2})$/);
        return m ? parseInt(m[1]) * 60 + parseInt(m[2]) : -1;
    }

    // Inside the scheduled hours now (from > to wraps past midnight).
    readonly property bool scheduledNow: {
        if (!cfg.schedule.enabled)
            return false;
        const from = minutes(cfg.schedule.from), to = minutes(cfg.schedule.to);
        if (from < 0 || to < 0 || from === to)
            return false;
        const m = now.getHours() * 60 + now.getMinutes();
        return from < to ? m >= from && m < to : m >= from || m < to;
    }

    // Turned off by hand during a scheduled window: off until it ends (ms).
    property alias skipUntil: persist.skipUntil
    PersistentProperties {
        id: persist
        reloadableId: "notificationSchedule"
        property real skipUntil: 0
    }
    readonly property bool scheduleSkipped: skipUntil > now.getTime()

    // Do Not Disturb by hand or by schedule.
    readonly property bool dndActive: Panels.doNotDisturb || (scheduledNow && !scheduleSkipped)
    readonly property bool dndScheduled: !Panels.doNotDisturb && scheduledNow && !scheduleSkipped

    // When the current scheduled window ends (ms).
    function windowEnd() {
        const to = minutes(cfg.schedule.to);
        const d = new Date();
        d.setHours(Math.floor(to / 60), to % 60, 0, 0);
        if (d.getTime() <= Date.now())
            d.setDate(d.getDate() + 1);
        return d.getTime();
    }

    // The Control Center, Focus, Spotlight and Settings switch: on is by
    // hand; off also ends a scheduled window early.
    function setDnd(on) {
        Panels.doNotDisturb = on;
        if (on)
            skipUntil = 0;
        else if (scheduledNow)
            skipUntil = windowEnd();
        now = new Date();
    }
    function toggleDnd() {
        setDnd(!dndActive);
    }

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

            property JsonObject schedule: JsonObject {
                property bool enabled: false
                // 24 h "HH:MM".
                property string from: "22:00"
                property string to: "07:00"
            }
            // Critical notifications (a low battery, a failing disk) show
            // through Do Not Disturb.
            property bool allowCritical: true
            // How long a banner stays; passing ones and a backlog go faster.
            property real bannerSeconds: 3
            // App → { allow, banners }.
            property var apps: ({})
            // App → { icon, last (ms) }.
            property var seen: ({})
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
