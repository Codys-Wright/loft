pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// The theme + wallpaper library (~/Documents/Themes, $STUDIO_LIBRARY):
// `studio library sort --json` regenerates its Colors / Tones / Themes views
// and prints the index the Wallpaper page browses — every image with its
// topic or pack, color families, tone and a cached thumbnail, plus the
// images that go with each installed theme (cli/studio/library.py).
// Loaded on demand (the Wallpaper page asks when it opens); sorting an
// unchanged library only checks its links.
Singleton {
    id: root

    property var data: null
    property bool loading: false
    property string error: ""

    readonly property bool exists: data?.exists ?? false
    readonly property string rootDir: data?.root ?? ""
    readonly property var images: data?.images ?? []
    readonly property var topics: data?.topics ?? []
    readonly property var packs: data?.packs ?? []
    readonly property var colors: data?.colors ?? []
    readonly property var tones: data?.tones ?? []
    readonly property var themes: data?.themes ?? []

    // path → image record
    readonly property var byPath: {
        const m = {};
        for (const r of images)
            m[r.path] = r;
        return m;
    }

    // Chip colors for the color families.
    readonly property var familyColors: ({
            Red: "#d9463b",
            Orange: "#e8893a",
            Yellow: "#e6c84a",
            Green: "#4f9d50",
            Teal: "#2f9c9a",
            Blue: "#3b78c9",
            Purple: "#8a5cc7",
            Pink: "#e07aa8",
            Brown: "#8b5e3c",
            Monochrome: "#9a9a9a"
        })

    // Images of a topic ("" + pack: that pack's images).
    function ofTopic(topic) {
        return images.filter(r => r.source === "topic" && r.topic === topic);
    }

    function ofPack(pack) {
        return images.filter(r => r.source === "pack" && (pack === "" || r.pack === pack));
    }

    // Images of a color family (or "" = all), optionally of one tone.
    function ofColor(family, tone) {
        return images.filter(r => (family === "" || r.colors.indexOf(family) >= 0) && (tone === "" || r.tone === tone));
    }

    // A theme's images: own and curated first, then matches; records with score/origin.
    function ofTheme(name) {
        const t = themes.find(x => x.name === name);
        if (!t)
            return [];
        return t.images.filter(e => byPath[e.path]).map(e => Object.assign({}, byPath[e.path], {
                    score: e.score,
                    origin: e.origin
                }));
    }

    function refresh() {
        if (proc.running) {
            pending = true;
            return;
        }
        loading = true;
        proc.running = true;
    }
    property bool pending: false

    Process {
        id: proc
        command: ["studio", "library", "sort", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() === "")
                    return;
                try {
                    root.data = JSON.parse(text);
                    root.error = "";
                } catch (e) {
                    root.error = `bad output from studio library sort: ${e}`;
                }
            }
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim() !== "") {
                root.error = text.trim();
                console.warn(`Library: ${text.trim()}`);
            }
        }
        onExited: {
            root.loading = false;
            if (root.pending) {
                root.pending = false;
                root.refresh();
            }
        }
    }

    IpcHandler {
        target: "library"

        // Re-sort the library (after adding files in a file manager).
        function refresh(): void {
            root.refresh();
        }

        function summary(): string {
            if (!root.exists)
                return root.data ? "no library at " + root.rootDir : "not loaded";
            return `${root.images.length} images · ` + root.topics.map(t => `${t.name} ${t.count}`).concat(root.colors.map(c => `${c.name} ${c.count}`)).join(", ");
        }
    }
}
