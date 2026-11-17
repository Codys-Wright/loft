// macOS 26 Tahoe's title bar, in numbers.
//
// Two sources:
//  - the metrics (bar height, bead size, spacing, insets) are measured on
//    real macOS 26.6 Tahoe: 2x screenshots of Cody's Mac, converted to points
//    (docs/KWIN.md §4.4 has the table). Loft uses the compact title bar
//    Brave and other tab-strip apps get: a 40 pt strip, 14 pt traffic lights
//    23 pt apart, centred 20 pt from the top, the first one 13 pt from the
//    window's left edge. (Brave on Linux draws its own strip 40 px tall too,
//    so KWin-decorated and client-decorated windows line up.)
//  - the art (colors, rims, glyphs, states, corners, shadow) is the MacTahoe
//    KDE theme's Aurorae decoration (a careful copy of Tahoe's;
//    vinceliuice/MacTahoe-kde, share/aurorae/themes/MacTahoe-{Light,Dark}/):
//    the rc's [General] and the SVGs (close.svg, minimize.svg, maximize.svg,
//    restore.svg, decoration.svg). Where a number comes from rendering that
//    theme in KWin 6.8 instead of from a file, the comment says "measured".
//
// The traffic lights are fixed colors on macOS, so they are not theme
// colors here either: only light / dark appearance picks a set.
#pragma once

#include <QColor>
#include <QPainterPath>
#include <QPointF>

namespace Loft::Tahoe
{

// ── layout (logical px, from the frame's outer edge) ────────────────────────

// macOS's compact title bar (Brave, Safari-style tab strips): 40 pt. A
// unified toolbar (Finder, Preview) is ~52 pt; the INI's TitleBarHeight
// picks that or anything else, and the beads stay centred (below).
constexpr qreal TitleBarHeight = 40;
// The beads: 14 pt circles, 23 pt centre to centre (9 pt gaps), centred
// vertically in the bar. macOS insets the first bead from the window's left
// edge by as much as from its top (13 pt in a 40 pt bar, 19 in a 52 pt
// toolbar), so the left inset follows the bar height the same way:
// left = top = (TitleBarHeight − 14) / 2. MacTahoe's Aurorae theme drew the
// same 14 px beads in a 34 px bar, 26 px apart, 16 px in.
constexpr qreal BeadRadius = 7; // also close.svg path2: "c 3.865929,0 6.999939,-3.134 …" (r = 7)
constexpr qreal ButtonCell = 2 * BeadRadius; // the clickable square: the bead
constexpr qreal ButtonSpacing = 9; // 23 − 14
constexpr qreal BeadRimWidth = 0.5; // light: a 6.5 px fill (path4) over the 7 px rim (path2)
// Keeps a bar set too low in the INI from cutting the beads (and leaves
// a 2 px margin above and below them).
constexpr qreal MinTitleBarHeight = ButtonCell + 4;
// The beads' inset from the top and the left for a bar this tall.
constexpr qreal buttonInset(qreal titleBarHeight)
{
    return (titleBarHeight - ButtonCell) / 2;
}
// decoration.svg decoration-topleft path1023: "C 443.296 201.0625 454 211.7665
// 454 225.0625" from x 430 → a 24 px corner. macOS rounds the bottom corners
// the same (Aurorae can't round the window under it; we can, borderRadius).
constexpr qreal CornerRadius = 24;
// BorderLeft / BorderRight / BorderBottom 1: a one-pixel frame around the
// window (with KWin's border size "Tiny", what MacTahoe users run).
constexpr qreal Border = 1;
// The title: macOS's title bar font is the bold system font at 13 pt; the
// family stays the KDE window-title font (Aurorae uses it as is, regular).
constexpr qreal TitleFontSize = 13;

// ── colors ──────────────────────────────────────────────────────────────────

struct Bead {
    QColor fill; // the face
    QColor rim; // light: the 0.5 px ring around it (and the pressed face); dark: = fill
};

struct Palette {
    // decoration.svg decoration-center / decoration-inactive-center
    QColor bar, barInactive;
    // decoration-bottom path14 / decoration-inactive-bottom path1: the
    // 1 px bottom frame (dark draws it a shade lighter than the bar).
    QColor bottom, bottomInactive;
    // rc ActiveTextColor / InactiveTextColor
    QColor text, textInactive;
    // decoration-top path966 / path996: white at 10 % / 5 % along the top
    // edge (dark: all around, decoration-left path4, decoration-bottom path13).
    QColor highlight, highlightInactive;
    bool highlightAllAround;
    // decoration-top path6098-4 / path6098-4-8: a 1 px black outline just
    // outside the frame.
    QColor outline, outlineInactive;
    // close / minimize / maximize .svg, "active-center"; "inactive-center"
    // for the grey beads of a window in the background.
    Bead close, minimize, zoom, idle;
    // pressed-center: light fills the bead with the rim color, dark lays
    // black at 20 % over it (path3626 opacity 0.2).
    bool pressedDarkens;
    // decoration.svg: the shadow paths' opacity (path6217-8 & co.) in front
    // of the "shadow_active" gradient; 0.5 for inactive windows in both.
    qreal shadowOpacity;
};

inline const Palette &palette(bool dark)
{
    static const Palette light{
        .bar = QColor(0xff, 0xff, 0xff),
        .barInactive = QColor(0xf2, 0xf2, 0xf2),
        .bottom = QColor(0xff, 0xff, 0xff),
        .bottomInactive = QColor(0xf2, 0xf2, 0xf2),
        .text = QColor(68, 68, 68),
        .textInactive = QColor(177, 177, 177),
        .highlight = QColor(255, 255, 255, 26),
        .highlightInactive = QColor(255, 255, 255, 13),
        .highlightAllAround = false,
        .outline = QColor(0, 0, 0, 38), // opacity 0.15
        .outlineInactive = QColor(0, 0, 0, 20), // opacity 0.08
        .close = {QColor(0xfe, 0x62, 0x54), QColor(0xcb, 0x4e, 0x43)},
        .minimize = {QColor(0xfd, 0xc9, 0x2d), QColor(0xca, 0xa1, 0x24)},
        .zoom = {QColor(0x28, 0xd3, 0x3f), QColor(0x20, 0xa9, 0x32)},
        .idle = {QColor(0xce, 0xce, 0xce), QColor(0xba, 0xba, 0xba)},
        .pressedDarkens = false,
        .shadowOpacity = 0.35,
    };
    static const Palette darkPalette{
        .bar = QColor(0x33, 0x33, 0x33),
        .barInactive = QColor(0x24, 0x24, 0x24),
        .bottom = QColor(0x36, 0x36, 0x36),
        .bottomInactive = QColor(0x24, 0x24, 0x24),
        .text = QColor(225, 225, 225),
        .textInactive = QColor(120, 120, 120),
        .highlight = QColor(255, 255, 255, 26),
        .highlightInactive = QColor(255, 255, 255, 13),
        .highlightAllAround = true,
        .outline = QColor(0, 0, 0, 255), // opacity 1
        .outlineInactive = QColor(0, 0, 0, 191), // opacity 0.75
        .close = {QColor(0xe9, 0x52, 0x4a), QColor(0xe9, 0x52, 0x4a)},
        .minimize = {QColor(0xf1, 0xae, 0x1b), QColor(0xf1, 0xae, 0x1b)},
        .zoom = {QColor(0x59, 0xc8, 0x37), QColor(0x59, 0xc8, 0x37)},
        .idle = {QColor(0x5d, 0x5d, 0x5d), QColor(0x5d, 0x5d, 0x5d)},
        .pressedDarkens = true,
        .shadowOpacity = 0.5,
    };
    return dark ? darkPalette : light;
}

// The glyphs: black at 50 % (every *-center glyph path: opacity 0.5).
inline QColor glyphColor()
{
    return QColor(0, 0, 0, 128);
}

// ── shadow ──────────────────────────────────────────────────────────────────
//
// Measured on a flat grey background (KWin 6.8, MacTahoe-Light/Dark), then
// fitted: at d px outside the frame, alpha = strength · (1 − d / reach)^1.5.
// The reaches of the focused window are the rc's shadow paddings
// (PaddingTop 21, PaddingLeft/Right 41, PaddingBottom 59); the strengths,
// times the palette's shadowOpacity, came out the same for light and dark
// (rms error < 0.004 per side, 0.013 at the top).

struct ShadowSide {
    qreal reach, strength;
};

struct ShadowShape {
    ShadowSide top, sides, bottom;
};

inline const ShadowShape &shadowShape(bool active)
{
    static const ShadowShape focused{{21, 0.25}, {41, 0.42}, {59, 0.70}};
    // Background windows: "shadow_inactive", a short, mostly downward shadow
    // at opacity 0.5 in both appearances.
    static const ShadowShape background{{8, 0.063}, {16.5, 0.196}, {14, 0.53}};
    return active ? focused : background;
}

constexpr qreal ShadowFalloff = 1.5;

// ── glyph paths ─────────────────────────────────────────────────────────────
//
// In bead units: the bead's centre at (0, 0), its radius 7. Converted from
// the SVG path data (translated so the bead's centre, (12, 1040.3622) in the
// files, is the origin). MacTahoe's beads are 14 px like macOS's, so the
// glyphs keep their size and proportions to the bead (× 6 px, − 8 × 2 px,
// zoom triangles in a 6 × 6 px box: macOS's are 6–7 pt in a 14 pt bead);
// they would scale with BeadRadius if it changed.

// close.svg path6-36: a rounded ×, 2 px strokes.
inline QPainterPath closeGlyph()
{
    QPainterPath p;
    p.moveTo(QPointF{-2.8284, -2.8284});
    p.cubicTo(QPointF{-3.2202, -2.4367}, QPointF{-3.2202, -1.806}, QPointF{-2.8284, -1.4142});
    p.lineTo(QPointF{-1.4142, 0});
    p.lineTo(QPointF{-2.8284, 1.4142});
    p.cubicTo(QPointF{-3.2202, 1.806}, QPointF{-3.2202, 2.4367}, QPointF{-2.8284, 2.8284});
    p.cubicTo(QPointF{-2.4367, 3.2202}, QPointF{-1.806, 3.2202}, QPointF{-1.4142, 2.8284});
    p.lineTo(QPointF{0, 1.4142});
    p.lineTo(QPointF{1.4142, 2.8284});
    p.cubicTo(QPointF{1.806, 3.2202}, QPointF{2.4367, 3.2202}, QPointF{2.8284, 2.8284});
    p.cubicTo(QPointF{3.2202, 2.4367}, QPointF{3.2202, 1.806}, QPointF{2.8284, 1.4142});
    p.lineTo(QPointF{1.4142, 0});
    p.lineTo(QPointF{2.8284, -1.4142});
    p.cubicTo(QPointF{3.2202, -1.806}, QPointF{3.2202, -2.4367}, QPointF{2.8284, -2.8284});
    p.cubicTo(QPointF{2.4367, -3.2202}, QPointF{1.806, -3.2202}, QPointF{1.4142, -2.8284});
    p.lineTo(QPointF{0, -1.4142});
    p.lineTo(QPointF{-1.4142, -2.8284});
    p.cubicTo(QPointF{-1.806, -3.2202}, QPointF{-2.4367, -3.2202}, QPointF{-2.8284, -2.8284});
    p.closeSubpath();
    return p;
}

// minimize.svg rect6-5: x 8, y 1039.36, 8 × 2, ry 1.
inline QPainterPath minimizeGlyph()
{
    QPainterPath p;
    p.addRoundedRect(QRectF(-4, -1, 8, 2), 1, 1);
    return p;
}

// maximize.svg path6-0-54: two triangles toward the corners (macOS's
// full-screen glyph: what green does without Option).
inline QPainterPath fullScreenGlyph()
{
    QPainterPath p;
    p.moveTo(QPointF{-1.5859, -3});
    p.lineTo(QPointF{3, 1.5859});
    p.lineTo(QPointF{3, -2});
    p.cubicTo(QPointF{3, -2.4155}, QPointF{2.4155, -3}, QPointF{2, -3});
    p.closeSubpath();
    p.moveTo(QPointF{-3, -1.5859});
    p.lineTo(QPointF{-3, 2});
    p.cubicTo(QPointF{-3, 2.4155}, QPointF{-2.4155, 3}, QPointF{-2, 3});
    p.lineTo(QPointF{1.5859, 3});
    p.closeSubpath();
    return p;
}

// Option held over the green bead (macOS: zoom instead of full screen): a
// "+", the minimize bar's 2 px rounded stroke both ways, 8 px across.
inline QPainterPath plusGlyph()
{
    QPainterPath h;
    h.addRoundedRect(QRectF(-4, -1, 8, 2), 1, 1);
    QPainterPath v;
    v.addRoundedRect(QRectF(-1, -4, 2, 8), 1, 1);
    return h.united(v);
}

} // namespace Loft::Tahoe
