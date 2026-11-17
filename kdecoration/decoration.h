// dev.loft.decoration: macOS 26 Tahoe's title bar (tahoe.h). Traffic lights
// at the left, the title centred on the window, rounded corners, Tahoe's
// outline and shadow; light or dark with the Loft theme (config.h).
//
// Behaviour is macOS's (docs/WINDOW-DECORATIONS.md, "Under KWin"): red
// closes, yellow minimizes (KWin's own actions); green is full screen, or
// zoom (maximize) with Option held, and pressing and holding it opens Loft's
// window menu (tiling, displays) at the button; a right-click on the bar
// opens that menu at the pointer. Loft's shell does the full screen and the
// menu (shell.h); without it, green maximizes and the menu is KWin's.
#pragma once

#include "config.h"

#include <KDecoration3/Decoration>
#include <KDecoration3/DecorationButton>
#include <KDecoration3/DecorationButtonGroup>

#include <QElapsedTimer>
#include <QTimer>
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

    // The pointer is over the traffic lights (the beads or the gaps between
    // them): every bead shows its glyph and lights up, also on a window in
    // the background, as on macOS.
    bool buttonsHovered() const
    {
        return m_buttonsHovered;
    }
    const Look &look() const
    {
        return Config::self()->look();
    }
    bool maximized() const;
    // Loft's window menu at `anchor` (decoration-local), or KWin's when the
    // shell isn't there. `kind`: "menu" (right-click) or "tileMenu" (green held).
    void showWindowMenu(const QString &kind, const QPointF &anchor);

protected:
    void hoverEnterEvent(QHoverEvent *event) override;
    void hoverMoveEvent(QHoverEvent *event) override;
    void hoverLeaveEvent(QHoverEvent *event) override;
    void mousePressEvent(QMouseEvent *event) override;

private:
    void updateLayout();
    void updateShadow();
    void setButtonsHovered(bool hovered);
    qreal radius() const;
    qreal border() const;

    KDecoration3::DecorationButtonGroup *m_buttons = nullptr;
    bool m_buttonsHovered = false;
    QElapsedTimer m_lastPress; // double-click on the bar → zoom
    QPointF m_lastPressPos;
};

class Button : public KDecoration3::DecorationButton
{
    Q_OBJECT
public:
    Button(KDecoration3::DecorationButtonType type, Decoration *decoration, QObject *parent = nullptr);
    void paint(QPainter *painter, const QRectF &repaintArea) override;

protected:
    void mousePressEvent(QMouseEvent *event) override;
    void mouseReleaseEvent(QMouseEvent *event) override;

private:
    // Green only.
    void zoomClicked();
    void held();

    QTimer *m_hold = nullptr; // press and hold → the window menu
    bool m_heldOpened = false; // that release isn't a click
    bool m_pressOption = false; // Option was down at the press
};

} // namespace Loft
