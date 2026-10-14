pragma Singleton

import QtQuick
import Quickshell

// Keyboard navigation inside a panel (menu bar dropdowns, an expanded
// Control Center module): Up/Down walk the rows marked `navigable: true`
// under `root`, in reading order; Enter activates the highlighted one.
// Rows highlight when `Nav.item === row` (hover moves it too), so mouse
// and keyboard share one highlight, like macOS menus. One surface takes
// the keyboard at a time, hence one global.
Singleton {
    id: nav

    property Item root: null
    property Item item: null
    // A text field has the keyboard (Enter/Space go to it, not the menu).
    property bool typing: false

    function rows() {
        const out = [];
        const walk = it => {
            for (const c of it.children) {
                if (!c.visible)
                    continue;
                if (c.navigable === true)
                    out.push(c);
                walk(c);
            }
        };
        if (nav.root)
            walk(nav.root);
        const pos = c => c.mapToItem(nav.root, 0, 0);
        return out.sort((a, b) => pos(a).y - pos(b).y || pos(a).x - pos(b).x);
    }

    function step(delta) {
        const l = rows();
        if (l.length === 0)
            return;
        const i = l.indexOf(item);
        item = i < 0 ? (delta > 0 ? l[0] : l[l.length - 1]) : l[(i + delta + l.length) % l.length];
    }

    function activate() {
        if (item && item.visible && typeof item.activate === "function") {
            item.activate();
            return true;
        }
        return false;
    }

    // Type to select: the next row whose text starts with the letter.
    function typeSelect(t) {
        const l = rows().filter(r => (r.text ?? "").toLowerCase().startsWith(t.toLowerCase()));
        if (l.length === 0)
            return;
        const all = rows();
        const i = all.indexOf(item);
        item = l.find(r => all.indexOf(r) > i) ?? l[0];
    }

    function reset(r) {
        nav.root = r;
        item = null;
    }
}
