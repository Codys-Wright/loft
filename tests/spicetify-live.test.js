// Tests for spicetify/loft-live.js (the live recolor extension), with a fake
// DOM and fetch. Run: node tests/spicetify-live.test.js spicetify/loft-live.js
"use strict";

const assert = require("assert");
const path = require("path");
const live = require(path.resolve(process.argv[2]));

const A = ":root {\n    --spice-main: #1a1b26;\n    --spice-text: #c0caf5;\n\n    --spice-rgb-main: 26,27,38;\n    --spice-rgb-text: 192,202,245;\n}\n";
const B = ":root {\n    --spice-main: #eff1f5;\n    --spice-text: #4c4f69;\n\n    --spice-rgb-main: 239,241,245;\n    --spice-rgb-text: 76,79,105;\n}\n";

// A minimal document: <head> with Spicetify's two stylesheet links.
function fakeDoc() {
    const head = {
        children: [],
        appendChild(n) {
            n.parentNode = head;
            head.children.push(n);
            return n;
        },
        insertBefore(n, ref) {
            n.parentNode = head;
            const i = ref ? head.children.indexOf(ref) : -1;
            if (i < 0)
                head.children.push(n);
            else
                head.children.splice(i, 0, n);
            return n;
        }
    };
    const link = (href) => ({ tag: "link", href, getAttribute: k => (k === "href" ? href : null) });
    const colors = link("colors.css");
    const user = link("user.css");
    head.appendChild(colors);
    head.appendChild(user);
    for (const n of head.children)
        Object.defineProperty(n, "nextSibling", { get: () => head.children[head.children.indexOf(n) + 1] ?? null });
    return {
        head,
        documentElement: head,
        hidden: false,
        createElement(tag) {
            const n = { tag, id: "", textContent: "" };
            Object.defineProperty(n, "nextSibling", { get: () => head.children[head.children.indexOf(n) + 1] ?? null });
            return n;
        },
        getElementById(id) {
            return head.children.find(n => n.id === id) ?? null;
        },
        querySelector(sel) {
            const m = /^link\[href\^="(.+)"\]$/.exec(sel);
            assert.ok(m, `unexpected selector ${sel}`);
            return head.children.find(n => n.tag === "link" && n.href.startsWith(m[1])) ?? null;
        }
    };
}

function fakeFetch(files) {
    const calls = [];
    const fn = async (url, opts) => {
        calls.push({ url, opts });
        const name = url.split("?")[0];
        if (!(name in files))
            return { ok: false, text: async () => "" };
        return { ok: true, text: async () => files[name] };
    };
    fn.calls = calls;
    return fn;
}

(async () => {
    // parseVars / looksValid
    const v = live.parseVars(A);
    assert.strictEqual(v["--spice-main"], "#1a1b26");
    assert.strictEqual(v["--spice-rgb-text"], "192,202,245");
    assert.ok(live.looksValid(A));
    assert.ok(!live.looksValid(":root { --spice-main: #000; }"), "needs text + rgb-main too");
    assert.ok(!live.looksValid("<html>404</html>"));
    assert.strictEqual(live.normalize(A), live.normalize(A.replace(/\n\s+/g, " ")));

    // The poller: cache-busted fetches from the app origin (relative URL).
    const doc = fakeDoc();
    const files = { "colors.css": A };
    const fetch = fakeFetch(files);
    let t = 1000;
    const tick = live.createPoller(doc, fetch, () => t++);

    assert.strictEqual(await tick(), true, "first read is applied");
    assert.match(fetch.calls[0].url, /^colors\.css\?loft=1000$/);
    assert.strictEqual(fetch.calls[0].opts.cache, "no-store");
    const style = doc.getElementById(live.STYLE_ID);
    assert.ok(style, "style element created");
    // Same cascade slot as colors.css: right after it, before user.css.
    assert.deepStrictEqual(doc.head.children.map(n => n.href ?? n.id), ["colors.css", live.STYLE_ID, "user.css"]);
    assert.strictEqual(style.textContent, A);

    assert.strictEqual(await tick(), false, "unchanged file: nothing to do");
    assert.strictEqual(fetch.calls[1].url, "colors.css?loft=1001", "every poll is cache-busted");

    // `loft theme apply` rewrote colors.css: swapped in place, one element.
    files["colors.css"] = B;
    assert.strictEqual(await tick(), true);
    assert.strictEqual(doc.getElementById(live.STYLE_ID).textContent, B);
    assert.strictEqual(doc.head.children.filter(n => n.id === live.STYLE_ID).length, 1);
    assert.strictEqual(doc.head.children.length, 3);

    // A half-written / broken file never replaces good colors.
    files["colors.css"] = ":root {\n    --spice-main: #ff";
    assert.strictEqual(await tick(), false);
    assert.strictEqual(doc.getElementById(live.STYLE_ID).textContent, B);

    // Missing file / fetch error: ignored.
    delete files["colors.css"];
    assert.strictEqual(await tick(), false);
    const throwing = live.createPoller(doc, async () => {
        throw new Error("offline");
    }, () => 0);
    assert.strictEqual(await throwing(), false);

    // No colors.css link (Spicetify layout change): falls back to <head>.
    const bare = fakeDoc();
    bare.head.children.splice(0, 1);
    live.applyCss(bare, A);
    assert.strictEqual(bare.head.children[bare.head.children.length - 1].id, live.STYLE_ID);

    // The real colors.css format `loft spotify sync` writes parses whole.
    const fs = require("fs");
    if (process.argv[3]) {
        const real = fs.readFileSync(process.argv[3], "utf8");
        const rv = live.parseVars(real);
        assert.ok(live.looksValid(real));
        assert.strictEqual(Object.keys(rv).filter(k => k.startsWith("--spice-rgb-")).length * 2, Object.keys(rv).length);
    }

    console.log("spicetify-live: ok");
})().catch(e => {
    console.error(e);
    process.exit(1);
});
