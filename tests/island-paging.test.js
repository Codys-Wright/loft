// Unit tests for src/island/paging.js (the Dynamic Island's wheel / swipe
// paging), run by `nix flake check` (island-paging):
// node tests/island-paging.test.js src/island/paging.js src/island/Island.qml
const fs = require("fs");
const assert = require("assert");

const src = fs.readFileSync(process.argv[2], "utf8").replace(/^\.pragma library.*$/m, "");
const P = new Function(`${src}; return { fresh, step, idle, LOCK_MS };`)();

// Feed events (ms apart), the wheel resting (idle) whenever a gap is > 200 ms
// as the island's timer does; collect the pages stepped.
function run(events, gap = 16) {
    let st = P.fresh(), t = 1000, out = [];
    for (const e of events) {
        if (e.wait) {
            t += e.wait;
            if (e.wait > 200)
                st = P.idle();
            continue;
        }
        const r = P.step(st, { ax: e.ax ?? 0, ay: e.ay ?? 0, px: e.px ?? 0, py: e.py ?? 0 }, t);
        st = r.st;
        if (r.d)
            out.push(r.d);
        t += gap;
    }
    return out;
}
// What QtWayland delivers (measured in a loft-dev session): a wheel notch is
// angle 120 / pixels 15; a touchpad's N px is angle 12·N / pixels N.
const notch = (dir) => ({ ay: dir * 120, py: dir * 15 });
const hNotch = (dir) => ({ ax: dir * 120, px: dir * 15 });
const swipe = (dx, n) => Array.from({ length: n }, () => ({ ax: dx * 12, px: dx }));

// A wheel notch pages: down = next, up = previous; sideways notches too.
assert.deepStrictEqual(run([notch(-1)]), [1]);
assert.deepStrictEqual(run([notch(1)]), [-1]);
assert.deepStrictEqual(run([hNotch(-1)]), [1]);
// Notches a beat apart: one page each.
assert.deepStrictEqual(run([notch(-1), { wait: 300 }, notch(-1), { wait: 300 }, notch(-1)]), [1, 1, 1]);
// A fast spin: the first notch pages, the rest of that burst is swallowed
// until the lock runs out (450 ms): a long spin keeps paging, slowly.
assert.deepStrictEqual(run(Array(10).fill(notch(-1)), 30), [1]);
assert.deepStrictEqual(run(Array(20).fill(notch(-1)), 30), [1, 1]);
// A hi-res wheel (eighth notches) adds up to one page.
assert.deepStrictEqual(run(Array(8).fill({ ay: -15, py: -1.875 })), [1]);

// One two-finger swipe (60 px in 3 px events) = one page, its tail ignored.
assert.deepStrictEqual(run(swipe(-3, 20)), [1]);
assert.deepStrictEqual(run(swipe(3, 20)), [-1]);
// Jitter (a few px) doesn't page; nor does a 10 px nudge in one event.
assert.deepStrictEqual(run(swipe(-1, 6)), []);
assert.deepStrictEqual(run([{ ax: -120, px: -10 }]), []);
// Two separate swipes = two pages.
assert.deepStrictEqual(run([...swipe(-3, 20), { wait: 400 }, ...swipe(-3, 20)]), [1, 1]);
// Mostly-vertical motion with a little sideways drift pages by its vertical.
assert.deepStrictEqual(run([{ ay: -120, py: -15, ax: 30, px: 4 }]), [1]);

// The regression behind "the mouse wheel doesn't page": QtWayland delivers
// wheel events from a TouchPad-type device, which WheelHandler ignores by
// default (Mouse only), and one WheelHandler takes one orientation.
const qml = fs.readFileSync(process.argv[3], "utf8");
const handler = qml.match(/component PageWheel: WheelHandler \{[\s\S]*?\n    \}/);
assert.ok(handler, "Island.qml: PageWheel component");
assert.match(handler[0], /acceptedDevices: PointerDevice\.AllDevices/);
assert.match(qml, /PageWheel \{\s*orientation: Qt\.Vertical/);
assert.match(qml, /PageWheel \{\s*orientation: Qt\.Horizontal/);

console.log("island-paging: ok");
