// Unit tests for src/services/appicons.js (app icon candidates, Apps.qml),
// run by `nix flake check` (app-icons):
// node tests/appicons.test.js src/services/appicons.js
//
// Regression: a niri window-rule naming ~25 app ids (Settings → Window Rules
// lists them all, each with an AppIcon) froze the shell. Quickshell emitted
// DesktopEntries valuesChanged in bursts (rescans + reordered rows), Apps.qml
// dropped its caches on each, and every AppIcon re-ran ~12 uncached theme
// lookups per app, each miss thousands of stat()s.
const fs = require("fs");
const assert = require("assert");

const src = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma library.*$/m, "");
const lib = new Function(`${src}; return { candidateNames, sources, signature };`)();

// A fake icon theme that counts lookups, cached like Apps.themed().
function theme(icons) {
    const t = { calls: 0, cache: {} };
    t.lookup = n => {
        t.calls++;
        return icons.includes(n) ? `image://icon/${n}` : "";
    };
    t.themed = n => {
        if (t.cache[n] === undefined)
            t.cache[n] = t.lookup(n);
        return t.cache[n];
    };
    return t;
}
const generic = ["application-x-executable", "applications-other", "application-default-icon", "exec", "system-run"];
const opts = (t, extra) => Object.assign({ themed: t.themed, pixmapDirs: ["/p1", "/p2"], genericIcons: generic }, extra ?? {});

// Names: deduplicated (a lowercase id is one name, not four).
{
    const n = lib.candidateNames("nm-connection-editor", null);
    assert.deepStrictEqual(n, ["nm-connection-editor"]);
    const d = lib.candidateNames("org.kde.dolphin", { id: "org.kde.dolphin", icon: "system-file-manager", startupClass: "" });
    assert.deepStrictEqual(d, ["system-file-manager", "org.kde.dolphin", "dolphin", "org-kde-dolphin", "dolphin.kde.org"]);
    assert.strictEqual(new Set(d).size, d.length);
    // Regex-derived ids from config rules are just ids.
    assert.deepStrictEqual(lib.candidateNames(".blueman-manager-wrapped", null), [".blueman-manager-wrapped", "blueman-manager-wrapped"]);
    assert.deepStrictEqual(lib.candidateNames("", null), []);
    assert.deepStrictEqual(lib.candidateNames(undefined, null), []);
}

// The app's names stop at the first themed hit; one generic icon.
{
    const t = theme(["system-file-manager", "org.kde.dolphin", "application-x-executable", "exec"]);
    const s = lib.sources("org.kde.dolphin", { id: "org.kde.dolphin", icon: "system-file-manager" }, opts(t));
    assert.deepStrictEqual(s, ["image://icon/system-file-manager", "file:///p1/system-file-manager.png", "file:///p1/system-file-manager.svg", "file:///p2/system-file-manager.png", "file:///p2/system-file-manager.svg", "image://icon/application-x-executable", ""]);
    assert.strictEqual(t.calls, 2); // system-file-manager, application-x-executable
}

// An absolute Icon= comes first; a miss everywhere ends on generic + "".
{
    const t = theme(["exec"]);
    const s = lib.sources("foo", { id: "foo.desktop", icon: "/opt/foo.png" }, opts(t));
    assert.deepStrictEqual(s, ["file:///opt/foo.png", "image://icon/exec", ""]);
    const none = lib.sources("bar", null, opts(theme([])));
    assert.deepStrictEqual(none, [""]);
}

// The shell's own windows use their own themed name.
{
    const t = theme(["preferences-system", "exec"]);
    assert.deepStrictEqual(lib.sources("org.quickshell", null, opts(t, { ownIcon: "preferences-system" })), ["image://icon/preferences-system", "image://icon/exec", ""]);
}

// Every name is looked up once across apps, misses included: listing the
// rule's apps again (the old per-valuesChanged recompute) costs nothing.
{
    const ids = ["org.pulseaudio.pavucontrol", "pavucontrol", "com.saivert.pwvucontrol", ".blueman-manager-wrapped", "nm-connection-editor", "org.gnome.Settings", "org.gnome.FileRoller", "org.kde.kdialog", "zenity", "org.gnome.Calculator", "nwg-look", "kvantummanager", "org.kde.kcolorchooser", "gcolor3", "com.github.finefindus.eyedropper", "org.gnome.clocks", "org.kde.dolphin"];
    const t = theme([]);
    for (const id of ids)
        lib.sources(id, null, opts(t));
    const first = t.calls;
    const unique = new Set(ids.flatMap(id => lib.candidateNames(id, null)).concat(generic)).size;
    assert.strictEqual(first, unique);
    for (let i = 0; i < 100; i++)
        for (const id of ids)
            lib.sources(id, null, opts(t));
    assert.strictEqual(t.calls, first);
}

// Signature: order-independent (Quickshell's rescans reorder rows), changes
// with ids, names, icons and WM classes.
{
    const a = { id: "a", name: "A", icon: "x", startupClass: "" };
    const b = { id: "b", name: "B", icon: "y", startupClass: "B" };
    assert.strictEqual(lib.signature([a, b]), lib.signature([b, a]));
    assert.notStrictEqual(lib.signature([a, b]), lib.signature([a]));
    assert.notStrictEqual(lib.signature([a, b]), lib.signature([a, Object.assign({}, b, { icon: "z" })]));
    assert.notStrictEqual(lib.signature([a, b]), lib.signature([a, Object.assign({}, b, { name: "Bee" })]));
    assert.notStrictEqual(lib.signature([a, b]), lib.signature([a, Object.assign({}, b, { startupClass: "b2" })]));
    assert.strictEqual(lib.signature([]), "");
    assert.strictEqual(lib.signature(null), "");
}

console.log("appicons: ok");
