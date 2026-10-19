// Unit tests for src/services/wsicons.js (the menu bar's workspace icons,
// WorkspaceIcons.qml), run by `nix flake check` (workspace-icons):
// node tests/wsicons.test.js src/services/wsicons.js
const fs = require("fs");
const assert = require("assert");

const src = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma library.*$/m, "");
const lib = new Function(`${src}; return { guess, normalize, resolve, table };`)();

const music = String.fromCodePoint(0xF075A);
const code = String.fromCodePoint(0xF0169);
const home = String.fromCodePoint(0xF02DC);

// Cody's workspaces all get a built-in icon.
for (const n of ["main", "code", "music", "gaming", "comms", "media", "notes", "lab", "stream", "recording", "setup", "research"])
    assert.notStrictEqual(lib.guess(n), "", `no built-in icon for ${n}`);

// Case, trailing digits, separators.
assert.strictEqual(lib.guess("Music"), music);
assert.strictEqual(lib.guess("  MUSIC "), music);
assert.strictEqual(lib.guess("code2"), code);
assert.strictEqual(lib.guess("code-2"), code);
assert.strictEqual(lib.guess("my-music"), music);
assert.strictEqual(lib.guess("Home Base"), home);
assert.strictEqual(lib.guess("hidden-DP-4"), String.fromCodePoint(0xF0209));

// Unknown and unnamed: no icon (the bar keeps its dot).
assert.strictEqual(lib.guess("zorblax"), "");
assert.strictEqual(lib.guess(""), "");
assert.strictEqual(lib.guess(null), "");
assert.strictEqual(lib.guess(undefined), "");

// Every key appears once, every icon is one nf-md glyph.
const seen = new Set();
for (const row of lib.table()) {
    assert.ok(row.icon.codePointAt(0) >= 0xF0001 && row.icon.codePointAt(0) <= 0xF1AF0, `not nf-md: ${row.names}`);
    for (const n of row.names) {
        assert.strictEqual(n, n.toLowerCase());
        assert.ok(!seen.has(n), `duplicate key ${n}`);
        seen.add(n);
    }
}

// normalize: lowercase keys, strings only.
assert.deepStrictEqual(lib.normalize({ Music: "x", code: 3, " Lab ": "y" }), { music: "x", lab: "y" });
assert.deepStrictEqual(lib.normalize(null), {});
assert.deepStrictEqual(lib.normalize("nope"), {});

// resolve: user > nix > built-in; "" from the user = no icon.
assert.strictEqual(lib.resolve("Music", {}, {}), music);
assert.strictEqual(lib.resolve("Music", {}, { music: "N" }), "N");
assert.strictEqual(lib.resolve("Music", { music: "U" }, { music: "N" }), "U");
assert.strictEqual(lib.resolve("Music", { music: "" }, { music: "N" }), "");
assert.strictEqual(lib.resolve("zorblax", {}, { zorblax: "Z" }), "Z");
assert.strictEqual(lib.resolve("", { "": "x" }, {}), "");
assert.strictEqual(lib.resolve("music", undefined, undefined), music);

console.log("wsicons: ok");
