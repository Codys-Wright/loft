#include "decoration.h"
#include "tahoe.h"

#include <KDecoration3/DecoratedWindow>
#include <KDecoration3/DecorationSettings>
#include <KDecoration3/DecorationShadow>
#include <KDecoration3/ScaleHelpers>

#include <KPluginFactory>

#include <QGuiApplication>
#include <QHash>
#include <QHoverEvent>
#include <QMouseEvent>
#include <QPainter>
#include <QPainterPath>
#include <QStyleHints>

#include <cmath>

K_PLUGIN_FACTORY_WITH_JSON(LoftDecorationFactory, "loft.json", registerPlugin<Loft::Decoration>();)

namespace Loft
{

using KDecoration3::DecorationButtonType;

// ── shadow ──────────────────────────────────────────────────────────────────
//
// One nine-patch image per (appearance, focus, radius): Tahoe's shadow
// (tahoe.h: per side, strength · (1 − d / reach)^1.5, blended elliptically
// round the corners), the window's own area punched out so translucent
// windows don't darken. The 1 px outline over it is KWin's border outline
// (updateShadow), which KWin draws in whole device pixels at any scale.
//
// KWin maps the image's pixels 1:1 to logical pixels (scene/shadowitem.cpp
// takes the element sizes as logical sizes), so it is drawn at scale 1.

namespace
{

QPainterPath roundedRect(const QRectF &r, qreal radius)
{
    QPainterPath p;
    if (radius > 0) {
        p.addRoundedRect(r, radius, radius);
    } else {
        p.addRect(r);
    }
    return p;
}

std::shared_ptr<KDecoration3::DecorationShadow> makeShadow(bool dark, bool active, qreal radius)
{
    static QHash<QString, std::shared_ptr<KDecoration3::DecorationShadow>> cache;
    const QString key = QStringLiteral("%1/%2/%3").arg(dark).arg(active).arg(radius);
    if (auto it = cache.constFind(key); it != cache.constEnd()) {
        return *it;
    }
    const Tahoe::Palette &pal = Tahoe::palette(dark);
    const Tahoe::ShadowShape &shape = Tahoe::shadowShape(active);
    const qreal opacity = active ? pal.shadowOpacity : 0.5;

    // Padding: the reach of each side (at least the outline's pixel).
    const int padTop = std::max(1, int(std::ceil(shape.top.reach)));
    const int padSide = std::max(1, int(std::ceil(shape.sides.reach)));
    const int padBottom = std::max(1, int(std::ceil(shape.bottom.reach)));
    const int r = std::max(1, int(std::ceil(radius)));
    const int box = 2 * r + 1; // the window, shrunk to its corners
    const QRectF window(padSide, padTop, box, box);
    const QPointF centre = window.center();
    const qreal inner = box / 2.0 - radius; // half the straight part of each edge

    QImage img(2 * padSide + box, padTop + box + padBottom, QImage::Format_ARGB32_Premultiplied);
    img.fill(Qt::transparent);
    for (int y = 0; y < img.height(); ++y) {
        auto *line = reinterpret_cast<QRgb *>(img.scanLine(y));
        const qreal py = y + 0.5;
        const Tahoe::ShadowSide &vertical = py < centre.y() ? shape.top : shape.bottom;
        for (int x = 0; x < img.width(); ++x) {
            // Distance outside the rounded window, and its direction.
            const qreal qx = std::abs(x + 0.5 - centre.x()) - inner;
            const qreal qy = std::abs(py - centre.y()) - inner;
            qreal d, ux, uy;
            if (qx > 0 && qy > 0) {
                const qreal len = std::hypot(qx, qy);
                d = len - radius;
                ux = qx / len;
                uy = qy / len;
            } else if (qx > qy) {
                d = qx - radius;
                ux = 1;
                uy = 0;
            } else {
                d = qy - radius;
                ux = 0;
                uy = 1;
            }
            if (d <= 0) {
                continue;
            }
            // Between two sides, the reach is the ellipse through both and
            // the strength their blend.
            const qreal reach = 1 / std::hypot(ux / shape.sides.reach, uy / vertical.reach);
            const qreal strength = shape.sides.strength * ux * ux + vertical.strength * uy * uy;
            const qreal t = 1 - d / reach;
            if (t <= 0) {
                continue;
            }
            const qreal a = std::clamp(opacity * strength * std::pow(t, Tahoe::ShadowFalloff), 0.0, 1.0);
            line[x] = qRgba(0, 0, 0, int(std::round(a * 255)));
        }
    }
    {
        QPainter p(&img);
        p.setRenderHint(QPainter::Antialiasing);
        p.setPen(Qt::NoPen);
        p.setCompositionMode(QPainter::CompositionMode_DestinationOut);
        p.setBrush(Qt::black);
        p.drawPath(roundedRect(window, radius));
    }

    auto shadow = std::make_shared<KDecoration3::DecorationShadow>();
    shadow->setPadding(QMarginsF(padSide, padTop, padSide, padBottom));
    shadow->setInnerShadowRect(QRectF(window.center(), QSizeF(1, 1)));
    shadow->setShadow(img);
    cache.insert(key, shadow);
    return shadow;
}

} // namespace

// ── decoration ──────────────────────────────────────────────────────────────

Decoration::Decoration(QObject *parent, const QVariantList &args)
    : KDecoration3::Decoration(parent, args)
{
}

Decoration::~Decoration() = default;

bool Decoration::maximized() const
{
    return window()->isMaximized();
}

qreal Decoration::radius() const
{
    return maximized() ? 0 : look().cornerRadius;
}

qreal Decoration::border() const
{
    // One device pixel (a crisp line at fractional scales), none when the
    // window fills the screen.
    return maximized() ? 0 : KDecoration3::snapToPixelGrid(Tahoe::Border, window()->scale());
}

bool Decoration::init()
{
    auto *w = window();
    setOpaque(false);

    m_buttons = new KDecoration3::DecorationButtonGroup(this);
    for (auto type : {DecorationButtonType::Close, DecorationButtonType::Minimize, DecorationButtonType::Maximize}) {
        m_buttons->addButton(new Button(type, this, m_buttons));
    }

    auto relayout = [this] {
        updateLayout();
        updateShadow();
        update();
    };
    connect(Config::self(), &Config::changed, this, relayout);
    connect(settings().get(), &KDecoration3::DecorationSettings::fontChanged, this, relayout);
    connect(settings().get(), &KDecoration3::DecorationSettings::reconfigured, this, relayout);
    connect(w, &KDecoration3::DecoratedWindow::widthChanged, this, relayout);
    connect(w, &KDecoration3::DecoratedWindow::maximizedChanged, this, relayout);
    connect(w, &KDecoration3::DecoratedWindow::scaleChanged, this, relayout);
    connect(w, &KDecoration3::DecoratedWindow::activeChanged, this, [this] {
        updateShadow();
        update();
    });
    connect(w, &KDecoration3::DecoratedWindow::captionChanged, this, [this] {
        update(titleBar());
    });

    updateLayout();
    updateShadow();
    return true;
}

void Decoration::updateLayout()
{
    const Look &l = look();
    auto *w = window();
    const qreal scale = w->scale();
    const qreal h = KDecoration3::snapToPixelGrid(l.titleBarHeight, scale);
    const qreal b = border();

    // Tahoe's 1 px frame on the sides and bottom (MacTahoe's Border* 1); the
    // window resizes through an invisible margin beyond it, as on macOS.
    setBorders(QMarginsF(b, h, b, b));
    const qreal grip = maximized() ? 0 : 4;
    setResizeOnlyBorders(QMarginsF(grip, 0, grip, grip));
    setTitleBar(QRectF(0, 0, w->width() + 2 * b, h));
    // KWin clips the whole window (bar, frame and client) to this.
    setBorderRadius(KDecoration3::BorderRadius(radius()));

    // The beads: 14 px, 9 px apart, centred in the bar and inset from the
    // left by as much as from the top (tahoe.h: macOS's 13 px in a 40 px
    // bar), on the pixel grid.
    const qreal inset = KDecoration3::snapToPixelGrid(Tahoe::buttonInset(h), scale);
    m_buttons->setSpacing(Tahoe::ButtonSpacing);
    for (auto *button : m_buttons->buttons()) {
        button->setGeometry(QRectF(0, 0, Tahoe::ButtonCell, Tahoe::ButtonCell));
    }
    m_buttons->setPos(QPointF(inset, inset));
}

void Decoration::updateShadow()
{
    const bool active = window()->isActive();
    const Tahoe::Palette &pal = Tahoe::palette(look().dark);
    setShadow(makeShadow(look().dark, active, radius()));
    // Just outside the frame, following its corners.
    setBorderOutline(KDecoration3::BorderOutline(1, active ? pal.outline : pal.outlineInactive, KDecoration3::BorderRadius(radius())));
}

void Decoration::setButtonsHovered(bool hovered)
{
    if (hovered != m_buttonsHovered) {
        m_buttonsHovered = hovered;
        for (auto *b : m_buttons->buttons()) {
            b->update();
        }
    }
}

// Over the group, gaps included (macOS lights all three as soon as the
// pointer reaches any of them; the gaps don't flicker them off).
void Decoration::hoverEnterEvent(QHoverEvent *event)
{
    KDecoration3::Decoration::hoverEnterEvent(event);
    setButtonsHovered(m_buttons->geometry().contains(event->position()));
}

void Decoration::hoverMoveEvent(QHoverEvent *event)
{
    KDecoration3::Decoration::hoverMoveEvent(event);
    setButtonsHovered(m_buttons->geometry().contains(event->position()));
}

void Decoration::hoverLeaveEvent(QHoverEvent *event)
{
    KDecoration3::Decoration::hoverLeaveEvent(event);
    setButtonsHovered(false);
}

void Decoration::paint(QPainter *painter, const QRectF &repaintArea)
{
    const Look &l = look();
    const Tahoe::Palette &pal = Tahoe::palette(l.dark);
    auto *w = window();
    const bool active = w->isActive();
    const QRectF bar = titleBar();
    const qreal b = border();
    const QRectF frame(0, 0, bar.width(), bar.height() + w->height() + b);
    const qreal r = radius();

    painter->save();
    painter->setRenderHint(QPainter::Antialiasing);
    painter->setPen(Qt::NoPen);

    // The bar and the 1 px frame (KWin only asks for the border areas; the
    // client covers the rest). The bottom frame line has its own shade.
    const QPainterPath shape = roundedRect(frame, r);
    painter->setBrush(active ? l.titleBarActive : l.titleBarInactive);
    painter->drawPath(shape);
    if (b > 0) {
        painter->setBrush(active ? pal.bottom : pal.bottomInactive);
        painter->drawPath(shape.intersected(roundedRect(QRectF(0, frame.bottom() - b, frame.width(), b), 0)));
    }

    // The highlight: a 1 px white line inside the edge, along the top (light)
    // or all around (dark).
    QPainterPath ring = shape.subtracted(roundedRect(frame.adjusted(1, 1, -1, -1), std::max<qreal>(0, r - 1)));
    if (!pal.highlightAllAround || b == 0) {
        ring = ring.intersected(roundedRect(QRectF(0, 0, frame.width(), std::max<qreal>(r, 1)), 0));
    }
    painter->setBrush(active ? pal.highlight : pal.highlightInactive);
    painter->drawPath(ring);

    // The title, centred on the whole window (macOS; Aurorae centres it
    // between the buttons) and kept clear of the beads on both sides.
    QFont font = settings()->font();
    font.setPixelSize(int(std::round(l.fontSize)));
    font.setWeight(QFont::DemiBold);
    painter->setFont(font);
    painter->setPen(active ? l.textActive : l.textInactive);
    const qreal clear = m_buttons->geometry().right() + Tahoe::ButtonSpacing;
    const QRectF titleRect = bar.adjusted(clear, 0, -clear, 0);
    if (titleRect.width() > 0) {
        const QString text = painter->fontMetrics().elidedText(w->caption(), Qt::ElideRight, int(titleRect.width()));
        painter->drawText(titleRect, Qt::AlignCenter | Qt::TextSingleLine, text);
    }
    painter->restore();

    m_buttons->paint(painter, repaintArea);
}

void Decoration::mousePressEvent(QMouseEvent *event)
{
    KDecoration3::Decoration::mousePressEvent(event);
    if (event->isAccepted()) {
        return; // a bead's
    }
    const QPointF pos = event->position();
    if (!titleBar().contains(pos) || m_buttons->geometry().contains(pos)) {
        return;
    }
    if (event->button() == Qt::RightButton) {
        // KWin's window menu, at the pointer.
        requestShowWindowMenu(QRect(pos.toPoint(), QSize(1, 1)));
        event->accept();
        return;
    }
    if (event->button() != Qt::LeftButton) {
        return;
    }
    // A double-click on the bar zooms (maximizes), as on macOS, whatever
    // KWin's title-bar action is. The first press stays KWin's (a drag
    // moves the window).
    const int interval = QGuiApplication::styleHints()->mouseDoubleClickInterval();
    const qreal slop = QGuiApplication::styleHints()->startDragDistance();
    if (m_lastPress.isValid() && m_lastPress.elapsed() <= interval && (pos - m_lastPressPos).manhattanLength() <= slop) {
        m_lastPress.invalidate();
        requestToggleMaximization(Qt::LeftButton);
        event->accept();
        return;
    }
    m_lastPress.start();
    m_lastPressPos = pos;
}

// ── buttons ─────────────────────────────────────────────────────────────────

Button::Button(DecorationButtonType type, Decoration *decoration, QObject *parent)
    : KDecoration3::DecorationButton(type, decoration, parent)
{
    // The base class wires the click to KWin: close, minimize, toggle
    // maximize (left = both ways, middle = vertical, right = horizontal).
    if (type == DecorationButtonType::Maximize) {
        setAcceptedButtons(Qt::LeftButton | Qt::MiddleButton | Qt::RightButton);
    }
}

void Button::paint(QPainter *painter, const QRectF &)
{
    auto *deco = static_cast<Decoration *>(decoration());
    if (!deco) {
        return;
    }
    const Tahoe::Palette &pal = Tahoe::palette(deco->look().dark);
    // Grey in the background (inactive-center), in color when focused or
    // under the pointer (macOS lights a background window's beads on hover;
    // MacTahoe keeps them grey there).
    const bool lit = (deco->window()->isActive() || deco->buttonsHovered()) && isEnabled();
    Tahoe::Bead bead = pal.idle;
    QPainterPath glyph;
    if (lit) {
        switch (type()) {
        case DecorationButtonType::Close:
            bead = pal.close;
            glyph = Tahoe::closeGlyph();
            break;
        case DecorationButtonType::Minimize:
            bead = pal.minimize;
            glyph = Tahoe::minimizeGlyph();
            break;
        default:
            bead = pal.zoom;
            glyph = deco->maximized() ? Tahoe::restoreGlyph() : Tahoe::zoomGlyph();
            break;
        }
    }

    const QPointF c = geometry().center();
    painter->save();
    painter->setRenderHint(QPainter::Antialiasing);
    painter->setPen(Qt::NoPen);
    painter->translate(c);
    const qreal R = Tahoe::BeadRadius;
    const bool pressed = lit && isPressed();
    // The rim (light), then the face.
    painter->setBrush(bead.rim);
    painter->drawEllipse(QPointF(0, 0), R, R);
    if (!pressed || pal.pressedDarkens) {
        if (bead.fill != bead.rim) {
            const qreal f = R - Tahoe::BeadRimWidth;
            painter->setBrush(bead.fill);
            painter->drawEllipse(QPointF(0, 0), f, f);
        }
    }
    if (pressed && pal.pressedDarkens) {
        painter->setBrush(QColor(0, 0, 0, 51)); // pressed-center path3626: black, opacity 0.2
        painter->drawEllipse(QPointF(0, 0), R, R);
    }
    if (deco->buttonsHovered() && lit) {
        painter->setBrush(Tahoe::glyphColor());
        painter->drawPath(glyph);
    }
    painter->restore();
}

} // namespace Loft

#include "decoration.moc"
