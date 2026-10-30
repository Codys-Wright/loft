pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// Settings → Keyboard Remaps: Loft's keyboard layer (cli/loft/keys.py), the
// macOS-style remaps xremap runs (loft-keys.service). Read with
// `loft keys show --json`:
//
//   groups      [{ id, name, description, section, application, remap, on,
//                 source (loft|nix|runtime), onSource }] in render order
//   classes     { id: { name, apps } }: terminals, browsers, … (an app joins
//                 one with its rule's `like`)
//   apps        { appId: { like, off, remap, source } }: per-app rules
//   remap       remaps in every app
//   leaveAlone  the shell's Apps to leave alone (no remaps there)
//   xremap      { config, following }: whether an xremap reads Loft's config
//
// Every write is a `loft keys …` command, one at a time: it checks the whole
// config before saving (an unknown key is refused, `error` says why) and
// rewrites xremap's config, which xremap reloads by itself.
Singleton {
    id: root

    property var data: ({ groups: [], classes: {}, apps: {}, remap: {}, leaveAlone: [], xremap: {} })
    property bool loaded: false
    property string error: ""
    // What the last error is about: an app id, "*" (Every App), "" (a group).
    property string errorScope: ""
    property bool busy: queue.length > 0 || proc.running

    readonly property var groups: data.groups ?? []
    readonly property var classes: data.classes ?? {}
    readonly property var appRules: data.apps ?? {}
    readonly property var everywhere: data.remap ?? {}
    readonly property bool following: data.xremap?.following === true

    // Settings → Keyboard Remaps opens on this app (KeybindsPage, IPC).
    property string focusApp: ""

    function refresh() {
        run(["show", "--json"]);
    }

    // ── Reading ──────────────────────────────────────────────────────────
    function rule(app) {
        return appRules[app] ?? { like: [], off: [], remap: {} };
    }

    function leftAlone(app) {
        return (data.leaveAlone ?? []).includes(app);
    }

    function matches(app, names) {
        for (const n of names ?? []) {
            if (n.length > 1 && n.startsWith("/") && n.endsWith("/")) {
                try {
                    if (new RegExp(n.slice(1, -1)).test(app))
                        return true;
                } catch (e) {}
            } else if (n === app) {
                return true;
            }
        }
        return false;
    }

    // An application list with "@class" expanded.
    function expand(names) {
        const out = [];
        for (const n of (typeof names === "string" ? [names] : names ?? [])) {
            const list = n.startsWith("@") ? (classes[n.slice(1)]?.apps ?? []) : [n];
            for (const a of list)
                if (!out.includes(a))
                    out.push(a);
        }
        return out;
    }

    // The classes `app` is in, and whether that is its own `like` or Loft's list.
    function classesOf(app) {
        const like = rule(app).like ?? [];
        return Object.keys(classes).filter(c => matches(app, classes[c].apps)).map(c => ({ id: c, own: like.includes(c) }));
    }

    // Whether a group is meant for this kind of app (its application list).
    function groupFor(g, app) {
        const a = g.application ?? {};
        if (a.only !== undefined)
            return matches(app, expand(a.only));
        return !matches(app, expand(a.not));
    }

    // [{ group, applies, why }] for every group meant for the app.
    function groupsFor(app) {
        const off = rule(app).off ?? [];
        const left = leftAlone(app);
        return groups.filter(g => groupFor(g, app)).map(g => {
            const on = g.on !== false;
            return {
                group: g,
                applies: on && !left && !off.includes(g.id),
                why: !on ? "Off everywhere" : left ? "Left alone" : off.includes(g.id) ? "Off in this app" : ""
            };
        });
    }

    // Apps worth listing: a rule, left alone, or a window open now.
    function knownApps() {
        const ids = new Set(Object.keys(appRules));
        for (const a of data.leaveAlone ?? [])
            ids.add(a);
        for (const w of Niri.windows)
            if (w.app_id && Apps.own[w.app_id] === undefined)
                ids.add(w.app_id);
        return [...ids];
    }

    function summary(app) {
        const out = [];
        if (leftAlone(app))
            out.push("Left alone");
        for (const c of classesOf(app))
            out.push(classes[c.id].name + (c.own ? "" : " (built-in)"));
        const r = rule(app);
        const n = Object.keys(r.remap ?? {}).length;
        if (n)
            out.push(`${n} remap${n > 1 ? "s" : ""}`);
        if ((r.off ?? []).length)
            out.push(`${r.off.length} group${r.off.length > 1 ? "s" : ""} off`);
        return out;
    }

    // ── Key names → Mac symbols ──────────────────────────────────────────
    readonly property var keyNames: ({
            left: "←",
            right: "→",
            up: "↑",
            down: "↓",
            backspace: "⌫",
            delete: "⌦",
            enter: "↩",
            esc: "⎋",
            tab: "⇥",
            space: "Space",
            capslock: "⇪",
            leftbrace: "[",
            rightbrace: "]",
            grave: "`",
            minus: "-",
            equal: "=",
            comma: ",",
            dot: ".",
            slash: "/",
            backslash: "\\",
            semicolon: ";",
            apostrophe: "'",
            home: "↖",
            end: "↘",
            pageup: "⇞",
            pagedown: "⇟"
        })

    function modSymbol(m) {
        const side = /_r$/i.test(m) ? "Right " : "";
        const base = m.replace(/_[lr]$/i, "").toLowerCase();
        const sym = { shift: "⇧", ctrl: "⌃", control: "⌃", c: "⌃", alt: "⌥", m: "⌥", super: "⌘", win: "⌘", windows: "⌘", meta: "⌘" }[base];
        return sym ? side + sym : null;
    }

    // "Super_L-Shift-t" → "⌘⇧T"; a modifier alone ("Alt_R") → "Right ⌥".
    function pretty(combo) {
        if (typeof combo !== "string")
            return "";
        const parts = combo.split("-");
        const key = parts.pop();
        let out = parts.map(p => modSymbol(p) ?? p).join("");
        // A modifier as the key itself ("Alt_R", "Shift_L"); not "c" / "m",
        // which are just letters there.
        const asMod = /_[lr]$/i.test(key) || /^(shift|ctrl|control|alt|super|win|windows|meta)$/i.test(key) ? modSymbol(key) : null;
        const k = key.toLowerCase();
        out += asMod ?? keyNames[k] ?? (k.length === 1 ? k.toUpperCase() : key);
        return out;
    }

    // A remap's target: a combination, a sequence, or tap / hold.
    function prettyAction(v) {
        if (v === null || v === undefined)
            return "nothing";
        if (typeof v === "string")
            return pretty(v);
        if (Array.isArray(v))
            return v.length ? v.map(prettyAction).join(" then ") : "nothing";
        if (v.tap !== undefined || v.hold !== undefined)
            return `tap ${prettyAction(v.tap)} · hold ${v.hold === "Alt_R" ? "window-manager key" : prettyAction(v.hold)}`;
        if (v.launch)
            return `run ${[].concat(v.launch).join(" ")}`;
        return JSON.stringify(v);
    }

    // ── Writing ──────────────────────────────────────────────────────────
    function setGroup(id, state) {
        run(["group", id, state]);
    }

    // args: extra `loft keys app` options, e.g. ["--like", "terminals"].
    function editApp(app, args) {
        run(["app", app].concat(args));
    }

    function setLeaveAlone(app, on) {
        editApp(app, [on ? "--leave-alone" : "--no-leave-alone"]);
    }

    function setClass(app, cls, on) {
        editApp(app, [on ? "--like" : "--unlike", cls]);
    }

    function setGroupInApp(app, id, on) {
        editApp(app, [on ? "--on" : "--off", id]);
    }

    // to: "Ctrl-k" or "a,b" (a sequence).
    function addRemap(app, from, to) {
        if (app)
            editApp(app, ["--remap", `${from}=${to}`]);
        else
            run(["remap", `${from}=${to}`]);
    }

    function removeRemap(app, from) {
        if (app)
            editApp(app, ["--unmap", from]);
        else
            run(["remap", "--unmap", from]);
    }

    function resetApp(app) {
        editApp(app, ["--reset", "--no-leave-alone"]);
    }

    function openSettings(app) {
        focusApp = "";
        focusApp = app ?? "";
        Panels.settingsSection = "keyremaps";
        Panels.settingsOpen = true;
    }

    // ── Plumbing: one `loft keys` at a time, then a fresh `show` ─────────
    property var queue: []

    function run(args) {
        const isShow = args[0] === "show";
        if (isShow && queue.some(q => q[0] === "show"))
            return;
        if (!isShow) {
            error = "";
            errorScope = args[0] === "app" ? args[1] : args[0] === "remap" ? "*" : "";
        }
        queue = queue.concat([args]);
        next();
    }

    function next() {
        if (proc.running || queue.length === 0)
            return;
        const args = queue[0];
        queue = queue.slice(1);
        proc.isShow = args[0] === "show";
        // One stream (stderr merged, the exit code last), parsed when it ends.
        proc.command = ["sh", "-c", 'loft keys "$@" 2>&1; echo "@rc=$?"', "sh"].concat(args);
        proc.running = true;
    }

    function finished(text, isShow) {
        const m = /@rc=(\d+)\s*$/.exec(text);
        const code = m ? Number(m[1]) : 1;
        const body = m ? text.slice(0, m.index).trim() : text.trim();
        const last = body.split("\n").pop().replace(/^loft keys: /, "");
        if (isShow) {
            try {
                root.data = JSON.parse(body);
                root.loaded = true;
            } catch (e) {
                root.error = last || `loft keys show: ${e}`;
            }
        } else {
            if (code !== 0)
                root.error = last || `loft keys failed (${code})`;
            if (!root.queue.some(q => q[0] === "show"))
                root.queue = root.queue.concat([["show", "--json"]]);
        }
    }

    Process {
        id: proc
        property bool isShow: false
        stdout: StdioCollector {
            onStreamFinished: root.finished(text, proc.isShow)
        }
        onExited: root.next()
    }

    // The shell's leave-alone list lives in Shortcuts; follow its changes.
    Connections {
        target: Shortcuts
        function onLeaveAloneChanged() {
            if (root.loaded)
                root.refresh();
        }
    }

    IpcHandler {
        target: "keyremaps"

        function open(appId: string): void {
            root.openSettings(appId);
        }
        // The focused window's app.
        function openFocused(): void {
            const w = Niri.windows.find(x => x.is_focused);
            root.openSettings(w?.app_id ?? "");
        }
    }
}
