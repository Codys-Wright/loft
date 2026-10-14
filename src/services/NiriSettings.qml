pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// niri settings for the Settings app, through the `loft-niri` backend
// (crates/loft-niri). Runtime changes are stored in
// $LOFT_STATE_DIR/overrides/niri.json and rendered into overrides/niri.kdl,
// which the session includes; the user's own KDL is never edited (PLAN §4.1).
//
//   outputs   live outputs (modes, scale, transform, position, VRR, identity)
//   keys      every managed setting: { value, source: override|config|default,
//             config, default, file, line, kind, min, max, options }
//   binds     every keybind in the config tree, with source and shadowing
//
// Setters send one JSON batch to `loft-niri apply`, which records, renders,
// validates with `niri validate`, swaps the fragment in and reloads niri.
Singleton {
    id: root

    property var outputs: []
    property var keys: ({})
    // identity → recorded output override
    property var outputOverrides: ({})
    property string configPath: ""
    property var bindsData: ({ binds: [], files: [], conflicts: [], errors: [] })

    property string error: ""
    readonly property bool busy: runner.running || queue.length > 0
    property var queue: []

    // Identify: every screen flashes its name (IdentifyOverlay).
    property bool identifying: false

    readonly property bool hasOverrides: Object.values(keys).some(k => k.source === "override") || Object.keys(outputOverrides).length > 0

    function value(key) {
        return keys[key]?.value;
    }

    function overridden(key) {
        return keys[key]?.source === "override";
    }

    function anyOverridden(prefix) {
        return Object.keys(keys).some(k => k.startsWith(prefix) && keys[k].source === "override");
    }

    function outputByName(name) {
        return outputs.find(o => o.name === name) ?? null;
    }

    function refresh() {
        outputsProc.running = true;
        showProc.running = true;
    }

    function refreshBinds() {
        bindsProc.running = true;
    }

    // ── Setters ─────────────────────────────────────────────────────────
    // A batch: { set: {key: value}, unset: [key], outputs: {identity: change},
    //            reset_outputs: [identity], live, record, render }
    function apply(batch, done) {
        queue = queue.concat([{ batch: batch, done: done ?? null }]);
        if (!runner.running)
            next();
    }

    function set(key, v) {
        const s = {};
        s[key] = v;
        apply({ set: s });
    }

    function unset(keyOrSection) {
        apply({ unset: [keyOrSection] });
    }

    function unsetAll(list) {
        apply({ unset: list });
    }

    // Live only (pending confirmation), or recorded + rendered.
    function setOutputs(changes, live, record, done) {
        apply({ outputs: changes, live: live, record: record, render: record }, done);
    }

    function resetOutput(identity) {
        apply({ reset_outputs: [identity] });
    }

    function identify() {
        identifying = true;
        identifyTimer.restart();
    }

    function next() {
        if (queue.length === 0)
            return;
        const [job, ...rest] = queue;
        queue = rest;
        runner.job = job;
        runner.command = ["loft-niri", "--json", "apply", JSON.stringify(job.batch)];
        runner.running = true;
    }

    Timer {
        id: identifyTimer
        interval: 2500
        onTriggered: root.identifying = false
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
                root.error = r.ok ? "" : (r.error ?? "loft-niri failed");
                const done = runner.job?.done;
                if (done)
                    done(r);
            }
        }
        onExited: code => {
            if (code !== 0 && root.error === "")
                root.error = `loft-niri exited with ${code}`;
            root.refresh();
            root.next();
        }
    }

    Process {
        id: outputsProc
        command: ["loft-niri", "--json", "outputs"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(text);
                    if (Array.isArray(r))
                        root.outputs = r;
                } catch (e) {
                    console.warn(`NiriSettings: bad outputs: ${e}`);
                }
            }
        }
    }

    Process {
        id: showProc
        command: ["loft-niri", "--json", "show"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(text);
                    if (r.ok === false) {
                        root.error = r.error;
                        return;
                    }
                    root.keys = r.keys ?? {};
                    root.outputOverrides = r.outputs ?? {};
                    root.configPath = r.config ?? "";
                } catch (e) {
                    console.warn(`NiriSettings: bad show: ${e}`);
                }
            }
        }
    }

    Process {
        id: bindsProc
        command: ["loft-niri", "--json", "binds"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const r = JSON.parse(text);
                    if (r.ok === false) {
                        root.error = r.error;
                        return;
                    }
                    root.bindsData = r;
                } catch (e) {
                    console.warn(`NiriSettings: bad binds: ${e}`);
                }
            }
        }
    }

    // niri reports no output events (26.04): refresh when the config is
    // reloaded, the set of outputs with workspaces changes, or screens change.
    Connections {
        target: Niri
        function onConfigLoaded() {
            root.refresh();
            root.refreshBinds();
        }
        function onOutputsChanged() {
            root.refresh();
        }
    }

    Connections {
        target: Quickshell
        function onScreensChanged() {
            root.refresh();
        }
    }
}
