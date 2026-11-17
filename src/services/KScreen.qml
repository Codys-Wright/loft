pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Outputs under KWin, for Settings → Displays (docs/KWIN.md §4.11), through
// `loft-kwin displays` (crates/loft-kwin/src/displays.rs): KScreen's outputs
// in loft-niri's `outputs` shape, and changes applied with kscreen-doctor.
// KScreen applies and persists them itself; nothing is recorded by Loft.
// Consumers go through Displays (Displays.outputs / setOutputs), never here.
Singleton {
    id: root

    readonly property bool wanted: Compositor.backend === "kwin"

    // loft-niri-shaped records, identities filled in from the bridge.
    property var outputs: []
    property string error: ""
    readonly property bool busy: lister.running || runner.running || queue.length > 0
    property var queue: []
    property bool again: false

    // connector → { identity, model }, kept for outputs that are off now
    // (KWin's screens only list the ones that are on).
    property var known: ({})

    function learn() {
        const k = Object.assign({}, known);
        for (const d of KWin.displays)
            k[d.name] = { identity: d.identity, model: d.model };
        known = k;
    }

    function withIdentity(o) {
        const k = known[o.name];
        if (!k)
            return o;
        return Object.assign({}, o, {
            identity: k.identity || o.name,
            model: k.model || "",
            description: k.model || o.name
        });
    }

    function refresh() {
        if (!wanted)
            return;
        if (lister.running)
            again = true;
        else
            lister.running = true;
    }

    // changes: { "<identity or connector>": { mode, scale, transform,
    // position, off, vrr, hdr, primary } }, as NiriSettings.setOutputs.
    // `live` applies them; `record` alone (keeping a confirmed change) has
    // nothing to do: KScreen already saved it.
    function setOutputs(changes, live, record, done) {
        if (!live) {
            if (done)
                done({ ok: true });
            return;
        }
        const byName = {};
        for (const key in changes) {
            const o = outputs.find(o => o.name === key || o.identity === key);
            if (!o) {
                const r = { ok: false, error: `no display ${key}` };
                error = r.error;
                if (done)
                    done(r);
                return;
            }
            byName[o.name] = changes[key];
        }
        queue = queue.concat([{ changes: byName, done: done }]);
        if (!runner.running)
            next();
    }

    function next() {
        if (queue.length === 0)
            return;
        const [job, ...rest] = queue;
        queue = rest;
        runner.job = job;
        runner.command = [KWin.bin, "displays", "set", JSON.stringify(job.changes)];
        runner.running = true;
    }

    Process {
        id: lister
        command: [KWin.bin, "displays"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(text);
                    if (!r.ok) {
                        root.error = r.error ?? "loft-kwin displays failed";
                        return;
                    }
                    root.learn();
                    root.outputs = (r.outputs ?? []).map(o => root.withIdentity(o));
                } catch (e) {
                    console.warn(`KScreen: bad outputs: ${e}`);
                }
            }
        }
        onExited: if (root.again) {
            root.again = false;
            running = true;
        }
    }

    Process {
        id: runner
        property var job: null
        stdout: StdioCollector {
            onStreamFinished: {
                let r = null;
                try {
                    r = JSON.parse(text);
                } catch (e) {
                    r = { ok: false, error: text.trim() || `${e}` };
                }
                root.error = r.ok ? "" : (r.error ?? "kscreen-doctor failed");
                const done = runner.job?.done;
                if (done)
                    done(r);
            }
        }
        onExited: {
            root.refresh();
            root.next();
        }
    }

    Component.onCompleted: refresh()

    // KScreen has no change signal we can listen to without its D-Bus
    // backend (6.8's kscreen-doctor runs it in-process): re-read when KWin's
    // screens are added, removed, moved, resized or rescaled (the bridge
    // pushes those), and when the Displays page opens.
    Connections {
        target: KWin
        enabled: root.wanted
        function onOutputsChanged() {
            root.refresh();
        }
        function onDisplayLayoutChanged() {
            root.refresh();
        }
        function onDisplaysChanged() {
            const before = JSON.stringify(root.known);
            root.learn();
            if (JSON.stringify(root.known) !== before)
                root.outputs = root.outputs.map(o => root.withIdentity(o));
        }
    }

    Connections {
        target: Quickshell
        enabled: root.wanted
        function onScreensChanged() {
            root.refresh();
        }
    }
}
