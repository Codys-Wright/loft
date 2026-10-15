"""Unit `qt`: Qt / KDE apps (Dolphin first) in the Golden Gate look.

  kde.colors         a KDE color scheme ("Loft"): the palette for KColorScheme
                     and the app palette (Dolphin's view is KColorScheme::View)
  kvantum.kvconfig   a Kvantum theme ("Loft"): translucent windows (the glass
  kvantum.svg        niri blurs: Kvantum's own blur is off), opaque views,
                     rounded selection pills, flat toolbar buttons, the
                     palette's accent; every element Kvantum draws for Dolphin
                     is generated here, so nothing falls back to Kvantum's
                     built-in (Enlightenment-grey) default theme
  dolphin.qss        a Qt style sheet the dolphin launcher passes with
                     -stylesheet: Places rows inset like Nautilus's sidebar

  colors    palette, polarity
  material  glass tint / opacity / blur → the window (sidebar) glass
  shape     control radius (buttons, pills), surface radius (menus)

Nothing here is global: the `qt` hook (hooks.py) links these files in as the
Kvantum theme `Loft` and the color scheme `Loft`, assigns the Kvantum theme
to the apps listed in ~/.config/loft/qt.json only (kvantum.kvconfig
[Applications]), and writes the style / scheme keys into those apps' own rc
files (dolphinrc [KDE] widgetStyle, [UiSettings] ColorScheme), which KDE apps
read only when no KDE platform theme runs: Plasma sessions keep their own look.
"""

from __future__ import annotations

from pathlib import Path

from .. import color as c
from . import look
from .unit import Source, Unit, template


def inputs(src: Source) -> dict:
    m, sh = src.facet("material"), src.facet("shape")
    colors = {k: src.facet("colors")[k] for k in ("polarity", "palette")}
    g = m["glass"]
    return {
        "name": src.res.name,
        "colors": colors,
        "glass": {
            "blur": bool(m["blur"]["enabled"]),
            "tint": c.hex6(g["tint"]),
            # The sidebar glass alpha: gtk.css's glass sidebar rule (Nautilus)
            # through the Transparency dial and its GTK override, so both file
            # managers read alike and follow the same slider (Dolphin reads
            # its Kvantum theme at start, like GTK apps their CSS).
            "alpha": look.gtk_glass_alpha(m, look.dark(colors), src.res.transparency),
        },
        "radius": {"control": sh["radius"]["control"], "surface": sh["radius"]["surface"]},
    }


# ── colors ──────────────────────────────────────────────────────────────────


def _kde(col: str) -> str:
    """KDE color scheme syntax: r,g,b (opaque) or r,g,b,a."""
    r, g, b, a = c.parse(col)
    rgb = ",".join(str(round(x * 255)) for x in (r, g, b))
    return rgb if a >= 1 else f"{rgb},{round(a * 255)}"


def roles(i: dict) -> dict[str, str]:
    """Everything the templates and the SVG use, as #rrggbb[aa]."""
    p = look.palette(i["colors"])
    dark = look.dark(i["colors"])
    g = i["glass"]
    view = c.mix(p["bg"], p["surface"], 0.5)  # gtk.css view_bg_color (bg_alt)
    raised = p["surface"] if dark else c.mix(p["bg"], "#ffffff", 0.6)  # gtk_raised
    glass = c.with_alpha(c.mix(g["tint"], p["surface"], 0.5), g["alpha"]) if g["blur"] else p["surface"]
    return {
        **{k: p[k] for k in ("bg", "surface", "overlay", "text", "subtext", "accent", "accent2", "urgent", "ok", "warn")},
        "view": view,
        "view_alt": c.mix(view, p["surface"], 0.5),
        "raised": raised,
        "glass": glass,
        # The inactive window: the same glass, a touch denser (Finder dims
        # its sidebar in the background the same way).
        "glass_inactive": c.with_alpha(c.mix(g["tint"], p["surface"], 0.5), min(1.0, g["alpha"] + 0.06)) if g["blur"] else p["surface"],
        "button": c.mix(p["surface"], p["overlay"], 0.35) if dark else c.mix(p["bg"], "#ffffff", 0.75),
        "hover": c.with_alpha(p["text"], 0.08),
        "press": c.with_alpha(p["text"], 0.14),
        "hairline": c.with_alpha(p["text"], 0.1 if dark else 0.14),
        "field": c.with_alpha(p["text"], 0.06) if dark else c.mix(p["bg"], "#ffffff", 0.85),
        # Selected items: the accent as a tint (gtk_selection), the item's
        # own text color stays readable; grey when the window is in the back.
        "selection": c.with_alpha(p["accent"], 0.32 if dark else 0.24),
        "selection_hover": c.with_alpha(p["accent"], 0.4 if dark else 0.3),
        "selection_inactive": c.with_alpha(p["text"], 0.13 if dark else 0.1),
        # Opaque versions for the palette (QPalette::Highlight is also drawn
        # as a solid fill: text selections, combo popups).
        "highlight": c.mix(view, p["accent"], 0.4 if dark else 0.3),
        "on_accent": c.readable_on(p["accent"], p["bg"], p["text"]),
        "scroll": c.with_alpha(p["text"], 0.3),
        "scroll_hover": c.with_alpha(p["text"], 0.5),
        "groove": c.with_alpha(p["text"], 0.12),
        "disabled": c.mix(p["subtext"], p["bg"], 0.45),
        "dark": "true" if dark else "false",
    }


def variables(i: dict) -> dict[str, str]:
    r = roles(i)
    v = {"name": i["name"], "polarity": i["colors"].get("polarity", "dark")}
    v.update({k: x for k, x in r.items()})
    v.update({f"kde_{k}": _kde(x) for k, x in r.items() if k != "dark"})
    v["ctl"] = str(_ctl(i))
    v["srf"] = str(_srf(i))
    # Places rows inset from the sidebar's edges, as gtk.css's Nautilus rows.
    v["places_inset"] = "10"
    return v


def _ctl(i: dict) -> int:
    """Control radius → the frame size of buttons, fields and pills (Kvantum
    draws a rounded corner inside the frame), 4..8 px."""
    return int(max(4, min(8, round(float(i["radius"]["control"])))))


def _srf(i: dict) -> int:
    return int(max(6, min(12, round(float(i["radius"]["surface"]) * 0.65))))


# ── the Kvantum SVG ─────────────────────────────────────────────────────────
#
# Kvantum draws a widget from SVG elements found by id: an interior `E-STATE`
# and, when the section has a frame, eight frame parts `E-STATE-top`, `-left`,
# `-topleft`, … (sizes = frame.top/left/… in the kvconfig, here = the radius,
# so a corner part is exactly the rounded corner). States: normal, focused
# (hover), pressed, toggled (checked / selected), disabled, plus `-inactive`
# variants for a window in the background. An element that isn't there falls
# back to Kvantum's built-in theme, so every section Dolphin uses has its
# elements here.


class Svg:
    def __init__(self) -> None:
        self.parts: list[str] = []
        self.y = 0.0  # each element gets its own row, so nothing overlaps

    def _row(self, h: float) -> float:
        y = self.y
        self.y += h + 4
        return y

    @staticmethod
    def _paint(col: str | None) -> str:
        if not col:
            return 'fill="none"'
        r, g, b, a = c.parse(col)
        hx = c.hex6(col)
        return f'fill="{hx}"' + (f' fill-opacity="{c.num(a)}"' if a < 1 else "")

    @staticmethod
    def _stroke(col: str | None, w: float) -> str:
        if not col:
            return ""
        r, g, b, a = c.parse(col)
        return f' stroke="{c.hex6(col)}" stroke-width="{c.num(w)}"' + (f' stroke-opacity="{c.num(a)}"' if a < 1 else "")

    def rect(self, id_: str, w: float, h: float, fill: str | None) -> None:
        y = self._row(h)
        self.parts.append(f'<rect id="{id_}" x="0" y="{c.num(y)}" width="{c.num(w)}" height="{c.num(h)}" {self._paint(fill)}/>')

    def framed(self, el: str, f: int, fill: str | None, stroke: str | None = None, sw: float = 1.0, interior: bool = True) -> None:
        """A rounded rectangle cut into Kvantum's nine parts: frame size f,
        corner radius f, an optional hairline drawn inside the edge."""
        y = self._row(3 * f + 20)
        x0 = 0.0
        paint, s = self._paint(fill), self._stroke(stroke, sw)
        h = sw / 2
        out = []
        # Corners: a quarter disc (fill) and its arc (stroke).
        corners = {
            "topleft": (x0, y, f"M{0},{f} A{f},{f} 0 0 1 {f},{0} L{f},{f} Z", f"M{h},{f} A{f - h},{f - h} 0 0 1 {f},{h}"),
            "topright": (x0 + f + 10, y, f"M{0},{0} A{f},{f} 0 0 1 {f},{f} L{0},{f} Z", f"M{0},{h} A{f - h},{f - h} 0 0 1 {f - h},{f}"),
            "bottomleft": (x0, y + f + 10, f"M{0},{0} L{f},{0} L{f},{f} A{f},{f} 0 0 1 {0},{0} Z", f"M{h},{0} A{f - h},{f - h} 0 0 0 {f},{f - h}"),
            "bottomright": (x0 + f + 10, y + f + 10, f"M{0},{0} L{f},{0} A{f},{f} 0 0 1 {0},{f} Z", f"M{f - h},{0} A{f - h},{f - h} 0 0 1 {0},{f - h}"),
        }
        for part, (px, py, fp, sp) in corners.items():
            t = f'transform="translate({c.num(px)},{c.num(py)})"'
            inner = f'<rect x="0" y="0" width="{f}" height="{f}" fill="none"/>'  # keeps the bounds f×f
            inner += f'<path d="{fp}" {paint}/>' if fill else ""
            inner += f'<path d="{sp}" fill="none"{s}/>' if stroke else ""
            out.append(f'<g id="{el}-{part}" {t}>{inner}</g>')
        # Edges: f thick, stretched by Kvantum along their length.
        edges = {
            "top": (x0 + 2 * f + 20, y, 10, f, f"M0,{h} H10"),
            "bottom": (x0 + 2 * f + 20, y + f + 10, 10, f, f"M0,{f - h} H10"),
            "left": (x0 + 2 * f + 40, y, f, 10, f"M{h},0 V10"),
            "right": (x0 + 3 * f + 50, y, f, 10, f"M{f - h},0 V10"),
        }
        for part, (px, py, w, hh, sp) in edges.items():
            t = f'transform="translate({c.num(px)},{c.num(py)})"'
            inner = f'<rect x="0" y="0" width="{w}" height="{hh}" {paint}/>'
            inner += f'<path d="{sp}" fill="none"{s}/>' if stroke else ""
            out.append(f'<g id="{el}-{part}" {t}>{inner}</g>')
        if interior:
            out.append(f'<rect id="{el}" x="{c.num(x0 + 4 * f + 60)}" y="{c.num(y)}" width="10" height="10" {paint}/>')
        self.parts += out

    def shape(self, id_: str, w: float, h: float, body: str) -> None:
        """A free-standing element (indicator, arrow): body in its own w×h box."""
        y = self._row(h)
        self.parts.append(
            f'<g id="{id_}" transform="translate(0,{c.num(y)})"><rect x="0" y="0" width="{c.num(w)}" height="{c.num(h)}" fill="none"/>{body}</g>'
        )

    def text(self) -> str:
        w = 400
        return (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{c.num(self.y + 4)}" viewBox="0 0 {w} {c.num(self.y + 4)}">\n'
            + "\n".join(self.parts)
            + "\n</svg>\n"
        )


def _p(col: str) -> str:
    r, g, b, a = c.parse(col)
    return f'fill="{c.hex6(col)}"' + (f' fill-opacity="{c.num(a)}"' if a < 1 else "")


def _s(col: str, w: float) -> str:
    r, g, b, a = c.parse(col)
    return f'fill="none" stroke="{c.hex6(col)}" stroke-width="{c.num(w)}" stroke-linecap="round" stroke-linejoin="round"' + (
        f' stroke-opacity="{c.num(a)}"' if a < 1 else ""
    )


def svg(i: dict) -> str:
    r = roles(i)
    f, fs = _ctl(i), _srf(i)
    s = Svg()

    # The window: glass (sidebar, toolbar, status bar show it; views are opaque).
    s.rect("window-normal", 10, 10, r["glass"])
    s.rect("window-normal-inactive", 10, 10, r["glass_inactive"])

    # Push buttons, combo boxes: a soft raised pill with a hairline.
    s.framed("button-normal", f, r["button"], r["hairline"])
    s.framed("button-focused", f, c.mix(r["button"], r["text"], 0.06), r["hairline"])
    s.framed("button-pressed", f, c.mix(r["button"], r["text"], 0.12), r["hairline"])
    s.framed("button-toggled", f, r["selection"], r["hairline"])
    s.framed("button-disabled", f, c.with_alpha(r["button"], 0.5), r["hairline"])

    # Toolbar / flat tool buttons: invisible until hovered, then a pill.
    s.framed("tbutton-normal", f, None)
    s.framed("tbutton-focused", f, r["hover"])
    s.framed("tbutton-pressed", f, r["press"])
    s.framed("tbutton-toggled", f, r["press"])
    s.framed("tbutton-disabled", f, None)

    # Text fields (location bar, search, rename): a recessed field.
    s.framed("lineedit-normal", f, r["field"], r["hairline"])
    s.framed("lineedit-focused", f, r["field"], c.with_alpha(r["accent"], 0.75), 2)
    s.framed("lineedit-disabled", f, c.with_alpha(r["field"], 0.5), r["hairline"])

    # Items in views (files, Places rows): rounded selection pills.
    s.framed("itemview-focused", f, r["hover"])
    s.framed("itemview-pressed", f, r["selection_hover"])
    s.framed("itemview-toggled", f, r["selection"])
    s.framed("itemview-toggled-inactive", f, r["selection_inactive"])
    s.framed("itemview-pressed-inactive", f, r["selection_inactive"])

    # Menus and tooltips: opaque raised surfaces (niri doesn't blur popups).
    s.framed("menu-normal", fs, r["raised"], r["hairline"])
    s.framed("menuitem-focused", 4, r["accent"])
    s.framed("menuitem-pressed", 4, r["accent"])
    s.framed("menuitem-toggled", 4, r["accent"])
    s.framed("menubaritem-focused", f, r["hover"])
    s.framed("menubaritem-pressed", f, r["press"])
    s.framed("menubaritem-toggled", f, r["press"])
    s.framed("tooltip-normal", f, r["raised"], r["hairline"])

    # Tabs: a segmented look, the current tab a raised pill.
    s.framed("tab-normal", f, None)
    s.framed("tab-focused", f, r["hover"])
    s.framed("tab-toggled", f, r["button"], r["hairline"])
    s.framed("tabframe-normal", f, None, r["hairline"])

    # Frames, group boxes, details-view header.
    s.framed("common-normal", f, None, r["hairline"])
    s.framed("group-normal", f, c.with_alpha(r["text"], 0.03), r["hairline"])
    s.framed("header-normal", 2, None)
    s.framed("header-focused", 2, r["hover"])
    s.framed("header-pressed", 2, r["press"])
    s.framed("header-toggled", 2, None)
    s.rect("header-separator", 1, 10, r["hairline"])
    s.rect("splitter-normal", 1, 10, r["hairline"])
    s.rect("splitter-focused", 1, 10, c.with_alpha(r["accent"], 0.6))
    s.shape("splitter-grip-normal", 2, 2, "")
    s.shape("focus", 2, 2, "")

    # Scroll bars: thin pills, no groove, no arrows (transient in the kvconfig).
    sf = 3
    s.framed("scrollbarslider-normal", sf, r["scroll"])
    s.framed("scrollbarslider-focused", sf, r["scroll_hover"])
    s.framed("scrollbarslider-pressed", sf, r["scroll_hover"])
    s.framed("scrollbarslider-disabled", sf, None)
    s.shape("grip-normal", 2, 2, "")
    s.shape("grip-focused", 2, 2, "")
    s.shape("grip-pressed", 2, 2, "")
    # The groove element is shared with sliders (zoom slider): thin track,
    # accent up to the handle.
    s.framed("slider-normal", 2, r["groove"])
    s.framed("slider-focused", 2, r["groove"])
    s.framed("slider-disabled", 2, c.with_alpha(r["groove"], 0.5))
    s.framed("slider-toggled", 2, r["accent"])
    s.framed("slider-toggled-focused", 2, r["accent"])
    knob = c.mix(r["text"], "#ffffff", 0.5)
    for st in ("normal", "focused", "pressed", "disabled"):
        fill = knob if st != "disabled" else r["disabled"]
        s.shape(f"slidercursor-{st}", 16, 16, f'<circle cx="8" cy="8" r="6.5" {_p(fill)}/><circle cx="8" cy="8" r="6.5" {_s(r["hairline"], 1)}/>')

    # Progress bars (also the Places panel's capacity bars).
    s.framed("progress-normal", 2, r["groove"])
    s.framed("progress-pattern-normal", 2, r["accent"])
    s.framed("progress-pattern-focused", 2, r["accent"])

    # Check boxes and radio buttons: macOS-like, the accent when on.
    box = 16
    check = f'<path d="M4.5,8.3 L7,10.8 L11.6,5.4" {_s(r["on_accent"], 1.8)}/>'
    dash = f'<path d="M4.5,8 H11.5" {_s(r["on_accent"], 1.8)}/>'
    off = f'<rect x="0.5" y="0.5" width="15" height="15" rx="4" {_p(r["field"])}/><rect x="0.5" y="0.5" width="15" height="15" rx="4" {_s(c.with_alpha(r["text"], 0.3), 1)}/>'
    on = f'<rect x="0" y="0" width="16" height="16" rx="4" {_p(r["accent"])}/>'
    for st in ("normal", "focused", "pressed", "disabled"):
        s.shape(f"checkbox-{st}", box, box, off)
        s.shape(f"checkbox-checked-{st}", box, box, on + check)
        s.shape(f"checkbox-tristate-{st}", box, box, on + dash)
        roff = f'<circle cx="8" cy="8" r="7.5" {_p(r["field"])}/><circle cx="8" cy="8" r="7.5" {_s(c.with_alpha(r["text"], 0.3), 1)}/>'
        ron = f'<circle cx="8" cy="8" r="8" {_p(r["accent"])}/><circle cx="8" cy="8" r="3" {_p(r["on_accent"])}/>'
        s.shape(f"radio-{st}", box, box, roff)
        s.shape(f"radio-checked-{st}", box, box, ron)

    # Arrows (combo boxes, spin boxes, tree expanders, menus): chevrons.
    chev = {
        "down": "M3,6 L8,11 L13,6",
        "up": "M3,10 L8,5 L13,10",
        "left": "M10,3 L5,8 L10,13",
        "right": "M6,3 L11,8 L6,13",
    }
    for d, path in chev.items():
        for st, col in (("normal", r["subtext"]), ("focused", r["text"]), ("pressed", r["text"]), ("toggled", r["text"]), ("disabled", r["disabled"])):
            s.shape(f"arrow-{d}-{st}", 16, 16, f'<path d="{path}" {_s(col, 1.6)}/>')
    for st, col in (("normal", r["subtext"]), ("focused", r["text"]), ("pressed", r["text"]), ("disabled", r["disabled"])):
        s.shape(f"arrow-plus-{st}", 16, 16, f'<path d="M3,8 H13 M8,3 V13" {_s(col, 1.6)}/>')
        s.shape(f"arrow-minus-{st}", 16, 16, f'<path d="M3,8 H13" {_s(col, 1.6)}/>')
    # Tree expander and menu submenu indicators reuse the arrows; the
    # tool button's menu arrow is a small down chevron.
    return s.text()


def render(i: dict, template_dir: Path) -> dict:
    v = variables(i)
    return {
        "kde.colors": template(template_dir, "kde.colors", v),
        "kvantum.kvconfig": template(template_dir, "kvantum.kvconfig", v),
        "kvantum.svg": svg(i),
        "dolphin.qss": template(template_dir, "dolphin.qss", v),
    }


UNIT = Unit(
    name="qt",
    reads=("colors", "material", "shape"),
    files=("kde.colors", "kvantum.kvconfig", "kvantum.svg", "dolphin.qss"),
    inputs=inputs,
    render=render,
    hook="qt",
    module=__file__,
    templates=("kde.colors", "kvantum.kvconfig", "dolphin.qss"),
)
