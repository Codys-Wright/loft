pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Spotlight's web side (the launcher's `bangs` elephant provider,
// launcher/elephant-bangs): Quicklinks, favorite !bangs and the default
// search engine, in <state>/spotlight.json. The launcher seeds the file from
// launcher/spotlight-defaults.json and its provider re-reads it on change, so
// edits here apply on the next keystroke. Edited in Settings → Spotlight.
//
// A quicklink is { id, keyword, name, bang | url, icon? }: `bang` borrows a
// DuckDuckGo bang's URL; `url` is your own, with %TERM% for the search term
// (without it, the quicklink just opens the page).
Singleton {
    id: root

    readonly property var data: store.value ?? ({})
    readonly property var quicklinks: data.quicklinks ?? []
    readonly property var favorites: data.favorites ?? []
    readonly property string defaultEngine: data.defaultEngine || "g"

    // The default engine menu; any other bang or quicklink keyword works too.
    readonly property var engines: [
        { value: "g", label: "Google" },
        { value: "ddg", label: "DuckDuckGo" },
        { value: "brave", label: "Brave Search" },
        { value: "kagi", label: "Kagi" },
        { value: "b", label: "Bing" },
        { value: "sp", label: "Startpage" },
        { value: "ecosia", label: "Ecosia" }
    ]

    JsonStore {
        id: store
        path: `${Settings.stateDir}/spotlight.json`
        fallback: ({})
    }

    // The launcher writes the file on its first start, maybe after ours.
    Timer {
        interval: 2000
        repeat: true
        running: store.ready && root.data.quicklinks === undefined
        onTriggered: store.reload()
    }

    function save(patch) {
        store.save(Object.assign({}, root.data, patch));
    }

    function setDefaultEngine(key) {
        save({ defaultEngine: key.trim().replace(/^!/, "") });
    }

    function setFavorites(list) {
        save({ favorites: list.map(f => f.trim().replace(/^!/, "")).filter(f => f !== "") });
    }

    function uid() {
        return "ql-" + Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36);
    }

    // A keyword nobody uses yet, based on `want`.
    function freeKeyword(want) {
        const base = (want || "link").toLowerCase().replace(/\s+/g, "");
        let kw = base;
        for (let n = 2; quicklinks.some(q => q.keyword === kw); n++)
            kw = base + n;
        return kw;
    }

    function addQuicklink(q) {
        const ql = Object.assign({ id: uid(), keyword: freeKeyword(q?.keyword), name: "" }, q ?? {});
        ql.keyword = freeKeyword(ql.keyword);
        // First, where Settings shows it without scrolling.
        save({ quicklinks: [ql].concat(quicklinks) });
        return ql;
    }

    function updateQuicklink(id, patch) {
        save({ quicklinks: quicklinks.map(q => q.id === id ? Object.assign({}, q, patch) : q) });
    }

    function removeQuicklink(id) {
        save({ quicklinks: quicklinks.filter(q => q.id !== id) });
    }

    function moveQuicklink(id, delta) {
        const list = quicklinks.slice();
        const i = list.findIndex(q => q.id === id);
        const j = i + delta;
        if (i < 0 || j < 0 || j >= list.length)
            return;
        const [q] = list.splice(i, 1);
        list.splice(j, 0, q);
        save({ quicklinks: list });
    }

    // Opens the quicklink the way Spotlight would (through elephant, so the
    // provider's own URL filling is what's tested): a search for "test", or
    // the page itself for a URL without %TERM%.
    function test(q) {
        const kw = q.keyword;
        if (q.url && !q.url.includes("%TERM%"))
            run(["elephant", "activate", `bangs;home:${kw};open;${kw};`]);
        else
            run(["elephant", "activate", `bangs;search:${kw};search;${kw} test;`]);
    }

    // Bang search for the quicklink picker: [{ key, name, detail }].
    property var bangResults: []
    property int searchSerial: 0

    function searchBangs(text) {
        // No spaces: "!youtube music" would be a search inside !youtube;
        // squeezed, it fuzzy-matches "YouTube Music".
        const q = text.trim().replace(/^!/, "").replace(/[\s;]+/g, "");
        const serial = ++searchSerial;
        run(["elephant", "query", "--json", `bangs;${q};40`], out => {
            if (serial !== root.searchSerial)
                return;
            const rows = [];
            for (const line of out.split("\n")) {
                if (!line.startsWith("{"))
                    continue;
                try {
                    const it = JSON.parse(line).item ?? {};
                    const [kind, key] = (it.identifier ?? "").split(":");
                    // Bangs only — quicklinks are already in the list.
                    if (!key || (it.subtext ?? "").includes("Quicklink") || !["scope", "home"].includes(kind))
                        continue;
                    rows.push({ key: key, name: it.text, detail: it.subtext });
                } catch (e) {}
            }
            root.bangResults = rows.slice(0, 6);
        });
    }

    function run(command, cb) {
        const job = jobComponent.createObject(root, { command: command, callback: cb ?? null });
        job.running = true;
    }

    Component {
        id: jobComponent

        Process {
            id: job
            property var callback: null

            stdout: StdioCollector {
                onStreamFinished: {
                    if (job.callback)
                        job.callback(text);
                    job.destroy();
                }
            }
        }
    }
}
