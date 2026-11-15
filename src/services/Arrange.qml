pragma Singleton

import QtQuick
import Quickshell

// Arrange (vorssaint "Window layout", Rectangle-style snapping) the niri
// way. niri has no title bars to hover, so this is a menu: the app menu's
// and the dock's "Arrange ▸", and a keyboard palette (Mod+Ctrl+A, `arrange
// open`, everyday/Everyday.qml) at the focused window.
//
// Floating windows snap like on macOS — halves, thirds, two thirds, fill,
// center — with SetWindowWidth/Height + MoveFloatingWindow as proportions of
// the working area. Tiled windows live in niri's scrolling columns, so
// halves there mean column widths (⅓ ½ ⅔ full), plus window heights,
// center, consume/expel. Both: full screen, maximize to edges, float/tile,
// move to display.
Singleton {
    id: root

    // ── Presets ──────────────────────────────────────────────────────────
    // Floating: [x, y, w, h] in % of the working area.
    readonly property var floatPresets: ({
            leftHalf: { label: "Left Half", rect: [0, 0, 50, 100] },
            rightHalf: { label: "Right Half", rect: [50, 0, 50, 100] },
            topHalf: { label: "Top Half", rect: [0, 0, 100, 50] },
            bottomHalf: { label: "Bottom Half", rect: [0, 50, 100, 50] },
            leftThird: { label: "Left Third", rect: [0, 0, 100 / 3, 100] },
            centerThird: { label: "Center Third", rect: [100 / 3, 0, 100 / 3, 100] },
            rightThird: { label: "Right Third", rect: [200 / 3, 0, 100 / 3, 100] },
            leftTwoThirds: { label: "Left Two Thirds", rect: [0, 0, 200 / 3, 100] },
            rightTwoThirds: { label: "Right Two Thirds", rect: [100 / 3, 0, 200 / 3, 100] },
            topLeft: { label: "Top Left", rect: [0, 0, 50, 50] },
            topRight: { label: "Top Right", rect: [50, 0, 50, 50] },
            bottomLeft: { label: "Bottom Left", rect: [0, 50, 50, 50] },
            bottomRight: { label: "Bottom Right", rect: [50, 50, 50, 50] },
            fill: { label: "Fill", rect: [0, 0, 100, 100] }
        })

    // Tiled: column widths in %.
    readonly property var columnPresets: ({
            third: { label: "One Third", width: 100 / 3 },
            half: { label: "Half", width: 50 },
            twoThirds: { label: "Two Thirds", width: 200 / 3 }
        })

    // Apply a preset by name to window `w` (default: the focused one).
    // Floating presets on a tiled window first float it; column presets on
    // a floating window tile it.
    function apply(name, w) {
        w = w ?? Compositor.focusedWindow;
        if (!w)
            return false;
        const f = floatPresets[name];
        if (f) {
            if (!w.is_floating)
                Compositor.setFloating(w.id, true);
            const [x, y, width, height] = f.rect;
            Compositor.setWindowWidthPercent(w.id, width);
            Compositor.setWindowHeightPercent(w.id, height);
            Compositor.moveFloatingWindowPercent(w.id, x, y);
            return true;
        }
        const c = columnPresets[name];
        if (c) {
            if (w.is_floating)
                Compositor.setFloating(w.id, false);
            Compositor.setColumnWidthPercent(w.id, c.width);
            return true;
        }
        switch (name) {
        case "maximizeColumn":
            Compositor.maximizeColumn(w.id);
            return true;
        case "expandColumn":
            Compositor.expandColumn(w.id);
            return true;
        case "halfHeight":
            Compositor.setWindowHeightPercent(w.id, 50);
            return true;
        case "resetHeight":
            Compositor.resetWindowHeight(w.id);
            return true;
        case "center":
            Compositor.centerWindow(w.id);
            return true;
        case "centerVisible":
            Compositor.centerVisibleColumns(w.id);
            return true;
        case "consume":
            Compositor.consumeOrExpelWindowLeft(w.id);
            return true;
        case "expel":
            Compositor.expelWindowFromColumn(w.id);
            return true;
        case "fullscreen":
            Compositor.toggleFullscreen(w.id);
            return true;
        case "maximizeEdges":
            Compositor.maximizeToEdges(w.id);
            return true;
        case "float":
            Compositor.toggleFloating(w.id);
            return true;
        }
        return false;
    }

    // ── Menu items (MenuState's shape) ───────────────────────────────────
    function item(key, label, w, name) {
        return { key: `arr-${key}`, label: label, enabled: true, run: () => root.apply(name, w) };
    }

    function sep(key) {
        return { key: `arr-s-${key}`, separator: true, label: "", enabled: true };
    }

    function header(key, label) {
        return { key: `arr-h-${key}`, label: label, enabled: false, header: true };
    }

    function floatItems(w, names) {
        return names.map(n => item(n, floatPresets[n].label, w, n));
    }

    function items(w) {
        if (!w)
            return [];
        const out = [];
        if (w.is_floating) {
            out.push(...floatItems(w, ["leftHalf", "rightHalf", "topHalf", "bottomHalf"]));
            out.push(sep("thirds"));
            out.push(...floatItems(w, ["leftThird", "centerThird", "rightThird", "leftTwoThirds", "rightTwoThirds"]));
            out.push(sep("quarters"));
            out.push({ key: "arr-quarters", label: "Quarters", enabled: true, submenu: true, children: floatItems(w, ["topLeft", "topRight", "bottomLeft", "bottomRight"]) });
            out.push(sep("fill"));
            out.push(item("fill", "Fill", w, "fill"));
            out.push(item("center", "Center", w, "center"));
        } else {
            out.push(header("width", "Column Width"));
            for (const n of ["third", "half", "twoThirds"])
                out.push(item(n, columnPresets[n].label, w, n));
            out.push(item("maximizeColumn", "Full Width", w, "maximizeColumn"));
            out.push(item("expandColumn", "Fill Available Width", w, "expandColumn"));
            out.push(sep("height"));
            out.push(header("height", "Window Height"));
            out.push(item("halfHeight", "Half", w, "halfHeight"));
            out.push(item("resetHeight", "Automatic", w, "resetHeight"));
            out.push(sep("center"));
            out.push(item("center", "Center Column", w, "center"));
            out.push(item("centerVisible", "Center Visible Columns", w, "centerVisible"));
            out.push(item("consume", "Join Column on the Left", w, "consume"));
            out.push(item("expel", "Take Out of Column", w, "expel"));
            out.push(sep("snap"));
            out.push({ key: "arr-snap", label: "Float and Snap", enabled: true, submenu: true, children: floatItems(w, ["leftHalf", "rightHalf", "leftThird", "centerThird", "rightThird", "leftTwoThirds", "rightTwoThirds", "fill"]) });
        }
        out.push(sep("screen"));
        out.push(item("maximizeEdges", "Maximize to Edges", w, "maximizeEdges"));
        out.push(item("fullscreen", "Full Screen", w, "fullscreen"));
        out.push(item("float", w.is_floating ? "Tile Window" : "Float Window", w, "float"));
        const here = Compositor.workspaces.find(x => x.id === w.workspace_id)?.output ?? "";
        const outputs = [...new Set(Compositor.workspaces.map(x => x.output ?? ""))].filter(o => o !== "");
        if (outputs.length > 1)
            out.push({
                key: "arr-display",
                label: "Move to Display",
                enabled: true,
                submenu: true,
                children: outputs.map(o => ({ key: `arr-out-${o}`, label: o, enabled: o !== here, toggle: "radio", checked: o === here, run: () => Compositor.moveWindowToOutput(w.id, o) }))
            });
        return out;
    }
}
