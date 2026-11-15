// dev.loft.decoration: a title bar with macOS traffic lights at the left
// (close / minimize / maximize, KWin's own actions), the title centered, the
// top corners rounded. Colors and metrics: config.h.
#pragma once

#include "config.h"

#include <KDecoration3/Decoration>
#include <KDecoration3/DecorationButton>
#include <KDecoration3/DecorationButtonGroup>

#include <QVariantList>

namespace Loft
{

class Decoration : public KDecoration3::Decoration
{
    Q_OBJECT
public:
    explicit Decoration(QObject *parent = nullptr, const QVariantList &args = QVariantList());
    ~Decoration() override;

    bool init() override;
    void paint(QPainter *painter, const QRectF &repaintArea) override;

    // Hovering any bead shows every bead's glyph (and lights them up in the
    // background), as on macOS.
    bool buttonsHovered() const
    {
        return m_buttonsHovered;
    }
    const Look &look() const
    {
        return Config::self()->look();
    }

protected:
    void mousePressEvent(QMouseEvent *event) override;

private:
    void updateLayout();
    void updateShadow();
    void updateButtonsHovered();
    bool maximized() const;
    qreal radius() const;

    KDecoration3::DecorationButtonGroup *m_buttons = nullptr;
    bool m_buttonsHovered = false;
};

class Button : public KDecoration3::DecorationButton
{
    Q_OBJECT
public:
    Button(KDecoration3::DecorationButtonType type, Decoration *decoration, QObject *parent = nullptr);
    void paint(QPainter *painter, const QRectF &repaintArea) override;
};

} // namespace Loft
