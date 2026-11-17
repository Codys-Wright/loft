pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Settings → Layout & Motion under KWin (docs/KWIN.md §4.21): KWin's
// animation speed and its effects, through `loft-kwin motion [set JSON]`.
// Only read under KWin; niri's motion settings are NiriSettings'.
//
//   speed     kdeglobals [KDE] AnimationDurationFactor (0 instant, 1 normal,
//             4 slow); KWin follows it at once
//   choices   KWin's exclusive groups (open/close, minimize, desktop
//             switching, …): [{id, label, hint, section, options: [{id,
//             label, on}], current, default}], current "none" when off
//   toggles   single effects: [{id, label, hint, section, on, default}]
//
// Effects go to kwinrc [Plugins] and are loaded / unloaded live over KWin's
// /Effects. fadingpopups isn't here: loft-kwin turns it off while Loft runs.
Singleton {
    id: root

    readonly property bool wanted: Compositor.backend === "kwin"
    property real speed: 1
    property var steps: [4, 2, 1.5, 1, 0.75, 0.5, 0]
    property var choices: []
    property var toggles: []
    property bool loaded: false
    property string error: ""
    property var queue: []

    // The page's rows, by id per section: {animations: [id], …}. Changed
    // only when the set of effects changes, so a Repeater over them keeps its
    // rows (and a click in progress) when a value changes.
    property var choiceIds: ({})
    property var toggleIds: ({})

    function choicesIn(section) {
        return choiceIds[section] ?? [];
    }

    function togglesIn(section) {
        return toggleIds[section] ?? [];
    }

    function choice(id) {
        return choices.find(c => c.id === id) ?? null;
    }

    function toggle(id) {
        return toggles.find(t => t.id === id) ?? null;
    }

    function idsBySection(list) {
        const out = {};
        for (const x of list)
            (out[x.section] = out[x.section] ?? []).push(x.id);
        return out;
    }

    function sameIds(a, b) {
        return JSON.stringify(a) === JSON.stringify(b);
    }

    // The nearest of KDE's steps to a factor (its slider snaps the same way).
    function stepIndex(f) {
        const i = steps.findIndex(s => s <= f);
        return i >= 0 ? i : steps.length - 1;
    }

    function setSpeed(f) {
        speed = f;
        apply({ speed: f });
    }

    function choose(group, effect) {
        choices = choices.map(c => c.id === group ? Object.assign({}, c, { current: effect }) : c);
        const ch = {};
        ch[group] = effect;
        apply({ choices: ch });
    }

    function setEffect(id, on) {
        toggles = toggles.map(t => t.id === id ? Object.assign({}, t, { on: on }) : t);
        const fx = {};
        fx[id] = on;
        apply({ effects: fx });
    }

    function apply(batch) {
        queue = queue.concat([batch]);
        if (!setter.running)
            next();
    }

    function next() {
        if (queue.length === 0)
            return;
        const [b, ...rest] = queue;
        queue = rest;
        setter.command = ["loft-kwin", "motion", "set", JSON.stringify(b)];
        setter.running = true;
    }

    function reload() {
        if (!wanted || setter.running || queue.length > 0)
            return;
        if (!reader.running)
            reader.running = true;
    }

    function take(text, errorOnly) {
        let r = null;
        try {
            r = JSON.parse(text);
        } catch (e) {
            r = { ok: false, error: text.trim() || `${e}` };
        }
        if (!r.ok) {
            root.error = r.error ?? "loft-kwin motion failed";
            return;
        }
        root.error = "";
        if (errorOnly)
            return;
        root.speed = r.speed ?? 1;
        root.steps = r.steps ?? root.steps;
        root.choices = r.choices ?? [];
        root.toggles = r.toggles ?? [];
        const ci = idsBySection(root.choices);
        const ti = idsBySection(root.toggles);
        if (!sameIds(ci, root.choiceIds))
            root.choiceIds = ci;
        if (!sameIds(ti, root.toggleIds))
            root.toggleIds = ti;
        root.loaded = true;
    }

    Component.onCompleted: reload()

    Process {
        id: reader
        command: ["loft-kwin", "motion"]
        stdout: StdioCollector {
            onStreamFinished: root.take(text)
        }
    }

    Process {
        id: setter
        stdout: StdioCollector {
            // The answer is the new state. With more changes queued, only its
            // error counts (its state would undo theirs on the page).
            onStreamFinished: root.take(text, root.queue.length > 0)
        }
        onExited: code => {
            if (code !== 0 && root.error === "")
                root.error = `loft-kwin motion exited with ${code}`;
            if (root.queue.length > 0)
                root.next();
        }
    }
}
