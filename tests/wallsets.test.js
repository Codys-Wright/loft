// Unit tests for src/services/wallsets.js (display roles, wallpaper sets),
// run by `nix flake check` (wallpaper-sets):
//   node tests/wallsets.test.js src/services/wallsets.js tests/fixtures/wallsets/layouts.json
// The fixture is shared with tests/test_wallsets.py (cli/studio/wallsets.py).
const fs = require("fs");
const assert = require("assert");

const src = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma library.*$/m, "");
const lib = new Function(`${src}; return { roles, resolveSet, coverage, bestSet, capture, wsKey, mainOutput, shapeOf };`)();
const fixture = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));

for (const c of fixture.cases) {
    assert.deepStrictEqual(lib.roles(c.layout.outputs, c.layout.main), c.roles, `roles: ${c.name}`);
    assert.deepStrictEqual(lib.resolveSet(c.set, c.layout), c.resolved, `resolveSet: ${c.name}`);
    assert.strictEqual(lib.coverage(c.set, c.layout), c.coverage, `coverage: ${c.name}`);
    if (c.effective)
        assert.deepStrictEqual(lib.capture("saved", c.layout, c.effective), c.captured, `capture: ${c.name}`);
}

// A captured set resolves back onto the same layout.
const c0 = fixture.cases[0];
const back = lib.resolveSet(lib.capture("x", c0.layout, c0.effective), c0.layout);
assert.deepStrictEqual(back.displays, c0.effective.displays);
for (const [k, p] of Object.entries(back.workspaces))
    assert.strictEqual(p, c0.effective.workspaces[k]);

// bestSet: the set naming the most displays wins; ties keep the first.
const sets = [{ name: "one", displays: { main: "/a" } }, { name: "three", displays: { main: "/a", left: "/b", right: "/c" } }, { name: "also3", displays: { main: "/a", portrait: "/b", "display-3": "/c" } }];
assert.strictEqual(lib.bestSet(sets, c0.layout).name, "three");
assert.strictEqual(lib.bestSet([{ name: "any", displays: { "*": "/a" } }], c0.layout), null);

assert.strictEqual(lib.wsKey({ name: "", idx: 3 }, "X Y Z"), "X Y Z#3");
assert.strictEqual(lib.wsKey({ name: "music", idx: 3 }, "X Y Z"), "music");
assert.strictEqual(lib.shapeOf({ width: 3440, height: 1440 }), "ultrawide");
assert.strictEqual(lib.mainOutput([], ""), null);

console.log(`wallsets.js: ${fixture.cases.length} layouts ok`);
