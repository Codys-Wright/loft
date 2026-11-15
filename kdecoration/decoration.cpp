#include "decoration.h"

#include <KDecoration3/DecoratedWindow>
#include <KDecoration3/DecorationSettings>
#include <KDecoration3/DecorationShadow>
#include <KDecoration3/ScaleHelpers>

#include <KPluginFactory>

#include <QHash>
#include <QMouseEvent>
#include <QPainter>
#include <QPainterPath>

#include <cmath>

K_PLUGIN_FACTORY_WITH_JSON(LoftDecorationFactory, "loft.json", registerPlugin<Loft::Decoration>();)

namespace Loft
{

using KDecoration3::DecorationButtonType;

// ── shadow ──────────────────────────────────────────────────────────────────
//
// One nine-patch image per (color, radius): a rounded box, a little lower
// than the window, blurred (three box blurs ≈ a gaussian), the window's own
// area punched out so translucent title bars don't darken.

namespace
{
constexpr int ShadowBlur = 22; // px of blur outside the window
constexpr int ShadowOffsetY = 6;

void boxBlurAlpha(QImage &img, int r)
{
    if (r < 1) {
        return;
    }
    const int w = img.width(), h = img.height();
    QList<int> line(std::max(w, h));
    for (int pass = 0; pass < 3; ++pass) {
        for (int y = 0; y < h; ++y) { // horizontal
            uchar *row = img.scanLine(y);
            int sum = 0;
            for (int x = -r; x <= r; ++x) {
                sum += row[std::clamp(x, 0, w - 1)];
            }
            for (int x = 0; x < w; ++x) {
                line[x] = sum / (2 * r + 1);
                sum += row[std::min(x + r + 1, w - 1)] - row[std::max(x - r, 0)];
            }
            for (int x = 0; x < w; ++x) {
                row[x] = uchar(line[x]);
            }
        }
        for (int x = 0; x < w; ++x) { // vertical
            int sum = 0;
            for (int y = -r; y <= r; ++y) {
                sum += img.scanLine(std::clamp(y, 0, h - 1))[x];
            }
            for (int y = 0; y < h; ++y) {
                line[y] = sum / (2 * r + 1);
                sum += img.scanLine(std::min(y + r + 1, h - 1))[x] - img.scanLine(std::max(y - r, 0))[x];
            }
            for (int y = 0; y < h; ++y) {
                img.scanLine(y)[x] = uchar(line[y]);
            }
        }
    }
}

std::shared_ptr<KDecoration3::DecorationShadow> makeShadow(const QColor &color, qreal radius)
{
    static QHash<QString, std::shared_ptr<KDecoration3::DecorationShadow>> cache;
    const QString key = color.name(QColor::HexArgb) + QLatin1Char('/') + QString::number(radius);
    if (auto it = cache.constFind(key); it != cache.constEnd()) {
        return *it;
    }
    const int m = ShadowBlur + ShadowOffsetY; // padding on every side
    const int r = int(std::ceil(radius));
    const int box = 2 * r + 1; // the window, shrunk to its corners
    const int size = 2 * m + box;
    const QRectF window(m, m, box, box);

    QImage mask(size, size, QImage::Format_Alpha8);
    mask.fill(0);
    {
        QPainter p(&mask);
        p.setRenderHint(QPainter::Antialiasing);
        p.setPen(Qt::NoPen);
        p.setBrush(Qt::white);
        p.drawRoundedRect(window.adjusted(1, 1 + ShadowOffsetY, -1, ShadowOffsetY), r, r);
    }
    boxBlurAlpha(mask, ShadowBlur / 3);

    QImage img(size, size, QImage::Format_ARGB32_Premultiplied);
    img.fill(color);
    {
        QPainter p(&img);
        p.setCompositionMode(QPainter::CompositionMode_DestinationIn);
        p.drawImage(0, 0, mask);
        p.setRenderHint(QPainter::Antialiasing);
        p.setCompositionMode(QPainter::CompositionMode_DestinationOut);
        p.setPen(Qt::NoPen);
        p.setBrush(Qt::black);
        p.drawRoundedRect(window, r, r);
    }

    auto shadow = std::make_shared<KDecoration3::DecorationShadow>();
    shadow->setPadding(QMarginsF(m, m, m, m));
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
    auto *w = window();
    return w->isMaximized();
}

qreal Decoration::radius() const
{
    return maximized() ? 0 : look().cornerRadius;
}

bool Decoration::init()
{
    auto *w = window();
    setOpaque(false);

    m_buttons = new KDecoration3::DecorationButtonGroup(this);
    for (auto type : {DecorationButtonType::Close, DecorationButtonType::Minimize, DecorationButtonType::Maximize}) {
        auto *b = new Button(type, this, m_buttons);
        m_buttons->addButton(b);
        connect(b, &KDecoration3::DecorationButton::hoveredChanged, this, &Decoration::updateButtonsHovered);
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

    // The bar is the only border; the sides and bottom resize through an
    // invisible margin, so windows sit edge to edge like on macOS.
    setBorders(QMarginsF(0, h, 0, 0));
    const qreal grip = maximized() ? 0 : 4;
    setResizeOnlyBorders(QMarginsF(grip, 0, grip, grip));
    setTitleBar(QRectF(0, 0, w->width(), h));
    // borderRadius rounds the window under the decoration: its top meets
    // the bar square, its bottom takes the window radius.
    setBorderRadius(KDecoration3::BorderRadius(0, 0, radius(), radius()));

    m_buttons->setSpacing(l.buttonSpacing);
    for (auto *b : m_buttons->buttons()) {
        b->setGeometry(QRectF(0, 0, l.buttonSize, l.buttonSize));
    }
    m_buttons->setPos(QPointF(l.buttonInset, KDecoration3::snapToPixelGrid((h - l.buttonSize) / 2, scale)));
}

void Decoration::updateShadow()
{
    const Look &l = look();
    const QColor c = window()->isActive() ? l.shadowActive : l.shadowInactive;
    setShadow(makeShadow(c, radius()));
}

void Decoration::updateButtonsHovered()
{
    bool hovered = false;
    for (auto *b : m_buttons->buttons()) {
        hovered = hovered || b->isHovered();
    }
    if (hovered != m_buttonsHovered) {
        m_buttonsHovered = hovered;
        for (auto *b : m_buttons->buttons()) {
            b->update();
        }
    }
}

void Decoration::paint(QPainter *painter, const QRectF &repaintArea)
{
    const Look &l = look();
    auto *w = window();
    const bool active = w->isActive();
    const QRectF bar = titleBar();
    const qreal r = std::min(radius(), bar.height());

    painter->save();
    painter->setRenderHint(QPainter::Antialiasing);
    painter->setPen(Qt::NoPen);
    painter->setBrush(active ? l.titleBarActive : l.titleBarInactive);
    // Rounded at the top only: the window's bottom corners are KWin's
    // (borderRadius), the bar meets the window square.
    QPainterPath path;
    path.setFillRule(Qt::WindingFill); // the union, not the overlap's XOR
    path.addRoundedRect(bar, r, r);
    path.addRect(bar.adjusted(0, r, 0, 0));
    painter->drawPath(path.simplified());

    // The title, centered on the whole bar (it lines up with the window) and
    // kept clear of the beads on both sides.
    QFont font = settings()->font();
    font.setPixelSize(int(std::round(l.fontSize)));
    painter->setFont(font);
    painter->setPen(active ? l.textActive : l.textInactive);
    const qreal clear = m_buttons->geometry().right() + l.buttonSpacing;
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
    if (event->button() == Qt::RightButton && titleBar().contains(event->position()) && !m_buttons->geometry().contains(event->position())) {
        // KWin's window menu, at the pointer.
        requestShowWindowMenu(QRect(event->position().toPoint(), QSize(1, 1)));
        event->accept();
    }
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
    const Look &l = deco->look();
    const bool lit = (deco->window()->isActive() || deco->buttonsHovered()) && isEnabled();
    QColor fill = l.buttonInactive;
    if (lit) {
        switch (type()) {
        case DecorationButtonType::Close:
            fill = l.close;
            break;
        case DecorationButtonType::Minimize:
            fill = l.minimize;
            break;
        default:
            fill = l.maximize;
            break;
        }
        if (isPressed()) {
            fill = fill.darker(125);
        }
    }

    const QRectF g = geometry();
    painter->save();
    painter->setRenderHint(QPainter::Antialiasing);
    painter->setPen(Qt::NoPen);
    painter->setBrush(fill);
    painter->drawEllipse(g);
    // A thin darker rim, like Aqua's beads.
    if (lit) {
        painter->setPen(QPen(fill.darker(115), 0.5));
        painter->setBrush(Qt::NoBrush);
        painter->drawEllipse(g.adjusted(0.25, 0.25, -0.25, -0.25));
    }

    if (deco->buttonsHovered() && isEnabled()) {
        const QPointF c = g.center();
        const qreal s = g.width() / 2;
        painter->setPen(QPen(l.glyph, std::max<qreal>(1.0, g.width() / 10), Qt::SolidLine, Qt::RoundCap));
        painter->setBrush(Qt::NoBrush);
        switch (type()) {
        case DecorationButtonType::Close: { // ×
            const qreal d = s * 0.42;
            painter->drawLine(c + QPointF(-d, -d), c + QPointF(d, d));
            painter->drawLine(c + QPointF(-d, d), c + QPointF(d, -d));
            break;
        }
        case DecorationButtonType::Minimize: // −
            painter->drawLine(c + QPointF(-s * 0.55, 0), c + QPointF(s * 0.55, 0));
            break;
        default: { // ⤢: two triangles pointing to the corners
            painter->setPen(Qt::NoPen);
            painter->setBrush(l.glyph);
            const qreal a = s * 0.5, gap = s * 0.08;
            QPolygonF tl{c + QPointF(-a, -a), c + QPointF(a * 0.55 - gap, -a), c + QPointF(-a, a * 0.55 - gap)};
            QPolygonF br{c + QPointF(a, a), c + QPointF(-a * 0.55 + gap, a), c + QPointF(a, -a * 0.55 + gap)};
            painter->drawPolygon(tl);
            painter->drawPolygon(br);
            break;
        }
        }
    }
    painter->restore();
}

} // namespace Loft

#include "decoration.moc"
