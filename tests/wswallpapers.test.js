// Unit tests for src/services/wswallpapers.js (which per-workspace wallpaper
// surfaces exist), run by `nix flake check` (workspace-wallpapers):
// node tests/wswallpapers.test.js src/services/wswallpapers.js
const fs = require("fs");
const assert = require("assert");

const src = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma library.*$/m, "");
const lib = new Function(`${src}; return { plan, step, overviewRadius, refOf };`)();

// 10 workspaces × 3 outputs; the 2nd one has names on its first two.
const screens = ["A", "B", "C"];
function layout(active) {
    const ws = [];
    for (const s of screens)
        for (let i = 1; i <= 10; i++)
            ws.push({ output: s, idx: i, name: s === "B" && i <= 2 ? `b${i}` : "", is_active: i === active[s] });
    return ws;
}
const keys = p => Object.keys(p).sort();

assert.strictEqual(lib.refOf({ idx: 3, name: "" }), "3");
assert.strictEqual(lib.refOf({ idx: 3, name: "chat" }), "chat");

// Zoom → workspaces visible on each side in the overview.
assert.strictEqual(lib.overviewRadius(0.5), 1);
assert.strictEqual(lib.overviewRadius(0.25), 2);
assert.strictEqual(lib.overviewRadius(0.1), 5);
assert.strictEqual(lib.overviewRadius(1), 1);

// Normal view: the active workspace and one neighbor each way, full size.
let p = lib.plan(layout({ A: 1, B: 2, C: 5 }), screens, {});
assert.deepStrictEqual(keys(p), ["A|1", "A|2", "B|3", "B|b1", "B|b2", "C|4", "C|5", "C|6"].sort());
assert.ok(Object.values(p).every(e => e.scale === 1));
assert.strictEqual(Object.keys(p).length, 8); // of 30 workspaces

// Overview at 0.5: ±2; the outer ones decoded at the overview's zoom.
p = lib.plan(layout({ A: 1, B: 2, C: 5 }), screens, { overview: true, zoom: 0.5 });
assert.strictEqual(p["C|3"].scale, 0.5);
assert.strictEqual(p["C|7"].scale, 0.5);
assert.strictEqual(p["C|4"].scale, 1);
assert.strictEqual(p["C|8"], undefined);
assert.strictEqual(Object.keys(p).length, 3 + 4 + 5);
// …but a surface that already is full size stays full size.
const live = { "C|7": { screen: "C", ref: "7", scale: 1, until: 0 } };
p = lib.plan(layout({ A: 1, B: 2, C: 5 }), screens, { overview: true, zoom: 0.5, live });
assert.strictEqual(p["C|7"].scale, 1);

// Smaller zoom shows more.
p = lib.plan(layout({ A: 5, B: 5, C: 5 }), ["A"], { overview: true, zoom: 0.25 });
assert.deepStrictEqual(keys(p), ["A|2", "A|3", "A|4", "A|5", "A|6", "A|7", "A|8"]);

// The naive way (for measurements): all of them.
p = lib.plan(layout({ A: 1, B: 1, C: 1 }), screens, { all: true });
assert.strictEqual(Object.keys(p).length, 30);

// A screen without an active workspace (no workspaces yet) gets nothing.
assert.deepStrictEqual(lib.plan([], screens, {}), {});

// Grace: an entry no longer wanted stays until its time, then goes.
const want1 = lib.plan(layout({ A: 1, B: 1, C: 1 }), ["A"], {});
let s = lib.step({}, want1, 1000, 1500);
assert.ok(s.changed);
assert.deepStrictEqual(keys(s.live), ["A|1", "A|2"]);
assert.strictEqual(s.pending, false);
const want3 = lib.plan(layout({ A: 3, B: 1, C: 1 }), ["A"], {});
s = lib.step(s.live, want3, 2000, 1500);
assert.deepStrictEqual(keys(s.live), ["A|1", "A|2", "A|3", "A|4"]);
assert.strictEqual(s.live["A|1"].until, 3500);
assert.strictEqual(s.live["A|2"].until, 0); // a neighbor again
assert.ok(s.pending);
// Nothing new before the deadline: no change.
const s2 = lib.step(s.live, want3, 3000, 1500);
assert.strictEqual(s2.changed, false);
assert.strictEqual(s2.live, s.live);
// After it: gone.
s = lib.step(s.live, want3, 3600, 1500);
assert.deepStrictEqual(keys(s.live), ["A|2", "A|3", "A|4"]);
assert.strictEqual(s.pending, false);
// Coming back within the grace period keeps the surface (no reload).
s = lib.step(s.live, lib.plan(layout({ A: 9, B: 1, C: 1 }), ["A"], {}), 4000, 1500);
assert.strictEqual(s.live["A|3"].until, 5500);
s = lib.step(s.live, want3, 4500, 1500);
assert.strictEqual(s.live["A|3"].until, 0);
// A scale change (overview → full) is a change.
s = lib.step({ "A|7": { screen: "A", ref: "7", scale: 0.5, until: 0 } }, { "A|7": { screen: "A", ref: "7", scale: 1 } }, 0, 1500);
assert.ok(s.changed);
assert.strictEqual(s.live["A|7"].scale, 1);

console.log("wswallpapers: ok");
