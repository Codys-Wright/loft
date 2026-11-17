// Unit tests for src/settings/settingsnav.js (Loft Settings' structure),
// run by `nix flake check` (settings-nav):
// node tests/settingsnav.test.js src/settings/settingsnav.js src/settings/SettingsApp.qml src launcher
const fs = require("fs");
const path = require("path");
const assert = require("assert");

const [navFile, appFile, ...roots] = process.argv.slice(2);
const src = fs.readFileSync(navFile, "utf8").replace(/^\.pragma library.*$/m, "");
const nav = new Function(`${src}; return { pages, groups, aliases, page, resolve, parentOf, topOf, childrenOf, path, allIds, searchPages, searchRows };`)();
const app = fs.readFileSync(appFile, "utf8");

// Every id of the flat sidebar before the redesign still opens a page.
const oldIds = ["appearance", "wallpaper", "lockscreen", "dock", "island", "displays", "spaces", "input", "layout", "keybinds", "keyremaps", "windowrules", "system", "sound", "capture", "features", "clipboard", "snippets", "phone", "spotlight", "everyday", "menubar", "desktopmenu", "quickpanel", "about"];
for (const id of oldIds)
    assert.strictEqual(nav.resolve(id), id, `old id ${id} no longer resolves`);

// The user's ask: Wallpaper lives under Appearance.
assert.strictEqual(nav.parentOf("wallpaper"), "appearance");
assert.strictEqual(nav.path("wallpaper"), "Appearance ▸ Wallpaper");
assert.strictEqual(nav.topOf("wallpaper"), "appearance");
assert.strictEqual(nav.topOf("appearance"), "appearance");
assert.strictEqual(nav.resolve("Keyboard"), "input");
assert.strictEqual(nav.resolve("nope"), "");

// Sidebar: each top-level page exactly once, sub-pages never; 10–14 entries.
const listed = nav.groups.flat();
assert.strictEqual(new Set(listed).size, listed.length, "a sidebar entry is listed twice");
const top = nav.allIds().filter(id => !nav.parentOf(id));
assert.deepStrictEqual([...listed].sort(), [...top].sort(), "sidebar ≠ the top-level pages");
assert.ok(listed.length >= 10 && listed.length <= 14, `${listed.length} sidebar entries`);

// Parents and children agree; one level deep.
for (const id of nav.allIds()) {
    const p = nav.parentOf(id);
    if (p) {
        assert.ok(nav.childrenOf(p).includes(id), `${p} doesn't list its child ${id}`);
        assert.strictEqual(nav.parentOf(p), "", `${p} is nested`);
    }
    for (const c of nav.childrenOf(id))
        assert.strictEqual(nav.parentOf(c), id, `${c} doesn't name its parent ${id}`);
    const info = nav.page(id);
    assert.ok(info.label && info.icon && info.badge, `${id} lacks label/icon/badge`);
}

// Aliases point at pages.
for (const [a, id] of Object.entries(nav.aliases))
    assert.ok(nav.pages[id], `alias ${a} → missing ${id}`);

// SettingsApp has a page slot for every page.
for (const id of nav.allIds())
    assert.ok(app.includes(`page: "${id}"`), `SettingsApp.qml has no PageSlot for ${id}`);

// Search: sub-pages and keywords.
assert.strictEqual(nav.searchPages("wallp")[0], "wallpaper");
assert.ok(nav.searchPages("hotkeys").includes("keybinds"));
assert.ok(nav.searchPages("trackpad").includes("input"));
assert.deepStrictEqual(nav.searchPages(""), []);
const index = [
    { page: "dock", label: "Magnification", kind: "row" },
    { page: "dock", label: "Show recent apps", kind: "row" },
    { page: "features", label: "Recent apps in Dock", kind: "row" },
    { page: "dock", label: "Magnification", kind: "row" }
];
assert.deepStrictEqual(nav.searchRows(index, "magn").map(h => h.label), ["Magnification"]);
assert.deepStrictEqual(nav.searchRows(index, "recent").map(h => h.page), ["features", "dock"]);

// Every caller in the tree that opens a Settings page names a known id:
// Panels.settingsSection = "x", showSettings("x"), settingsPage("x"),
// root.show("x") and `settings open x` / `settings x` IPC.
const bad = [];
const walk = dir => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const p = path.join(dir, e.name);
        if (e.isDirectory()) {
            if (e.name !== "node_modules" && !e.name.startsWith("."))
                walk(p);
        } else if (/\.(qml|js|go|sh|py|nix)$/.test(e.name)) {
            const text = fs.readFileSync(p, "utf8");
            const re = /(?:settingsSection\s*=\s*|showSettings\(|settingsPage\(|openSettings\()["']([a-z]+)["']|settings open ([a-z]+)/g;
            const own = p.endsWith("SettingsApp.qml") ? [...text.matchAll(/root\.show\("([a-z]+)"\)/g)] : [];
            let m;
            while ((m = re.exec(text)))
                if (!nav.resolve(m[1] ?? m[2]))
                    bad.push(`${p}: ${m[0]}`);
            // Spotlight's "… Settings" commands (elephant-commands/builtin.go).
            if (e.name === "builtin.go") {
                const block = text.slice(text.indexOf("// Settings pages"), text.indexOf('"settings-" + p.id'));
                for (const o of block.matchAll(/^\s*\{"([a-z]+)", "[^"]+", "/gm))
                    if (!nav.resolve(o[1]))
                        bad.push(`${p}: settings-${o[1]}`);
            }
            for (const o of own)
                if (!nav.resolve(o[1]))
                    bad.push(`${p}: ${o[0]}`);
        }
    }
};
for (const r of roots)
    walk(r);
assert.deepStrictEqual(bad, [], "callers open unknown Settings pages");

console.log(`settingsnav: ${nav.allIds().length} pages, ${listed.length} in the sidebar, ok`);
