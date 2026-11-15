// macOS 26 Tahoe's title bar, in numbers.
//
// Taken from the MacTahoe KDE theme's Aurorae decoration (a careful copy of
// Tahoe's title bar; vinceliuice/MacTahoe-kde, share/aurorae/themes/
// MacTahoe-{Light,Dark}/): the rc's [Layout] / [General] and the SVGs
// (close.svg, minimize.svg, maximize.svg, restore.svg, decoration.svg).
// Where a number comes from rendering that theme in KWin 6.8 instead of from
// a file, the comment says "measured" (docs/KWIN.md §4.4 has the method).
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

// MacTahoe-*rc [Layout]: TitleEdgeTop 8 + max(TitleHeight 16, ButtonHeight 16
// + ButtonMarginTop 2) + TitleEdgeBottom 8. Aurorae counts the button margin
// into the title row, so the bar it draws is 34 px tall (measured), not 32.
constexpr qreal TitleBarHeight = 34;
// The beads: 14 px circles (the SVGs' r=7 path) in 16 px button cells
// (ButtonWidth/ButtonHeight 16), cells 10 px apart (ButtonSpacing 10), the
// first cell TitleEdgeLeft 16 px from the frame's edge, its top at
// TitleEdgeTop 8 + ButtonMarginTop 2 = 10. So bead centres sit at
// x = 24, 50, 76 and y = 18 (measured: the close bead covers x 17..30,
// y 11..24 of the frame).
constexpr qreal ButtonCell = 16;
constexpr qreal ButtonSpacing = 10;
constexpr qreal ButtonLeft = 16;
constexpr qreal ButtonTop = 10;
constexpr qreal BeadRadius = 7; // close.svg path2: "c 3.865929,0 6.999939,-3.134 …" (r = 7)
constexpr qreal BeadRimWidth = 0.5; // light: a 6.5 px fill (path4) over the 7 px rim (path2)
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
// files, is the origin).

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
// full-screen / zoom glyph).
inline QPainterPath zoomGlyph()
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

// restore.svg path1031 / path1838 (the maximized window's green bead): the
// triangles turned toward the centre.
inline QPainterPath restoreGlyph()
{
    QPainterPath p;
    p.moveTo(QPointF{0, -4.5859});
    p.lineTo(QPointF{0, -1});
    p.cubicTo(QPointF{0, -0.5845}, QPointF{0.5845, 0}, QPointF{1, 0});
    p.lineTo(QPointF{4.5859, 0});
    p.closeSubpath();
    p.moveTo(QPointF{0, 4.5859});
    p.lineTo(QPointF{0, 1});
    p.cubicTo(QPointF{0, 0.5845}, QPointF{-0.5845, 0}, QPointF{-1, 0});
    p.lineTo(QPointF{-4.5859, 0});
    p.closeSubpath();
    return p;
}

} // namespace Loft::Tahoe
