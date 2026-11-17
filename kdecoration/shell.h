// What the decoration asks of Loft's shell, and the one bit of KWin's input
// state it needs (Option held). Shared by every decorated window.
//
// - Loft's shell: through loft-kwin's dev.loft.KWinBridge on the session bus
//   (crates/loft-kwin). The decoration doesn't know its window's id, so it
//   sends where it is (decoration-local point + the frame's size) and the
//   loft-bridge KWin script finds the window under the pointer. The bridge
//   only exists while the shell runs (it's the shell's child); without it,
//   `send` returns false and the caller does KWin's own thing.
// - Option (Alt): KWin builds decoration hover events without modifiers
//   (input.cpp DecorationEventFilter), and a modifier press alone sends the
//   decoration nothing. KWin's InputRedirection (a child of the application)
//   has a keyboardModifiersChanged signal: connected by name, so the plugin
//   doesn't link KWin. Outside KWin (System Settings' previews) it isn't
//   there and Option just never reads as held.
#pragma once

#include <QObject>
#include <QPointF>
#include <QSizeF>
#include <QString>

#include <functional>

namespace Loft
{

class Shell : public QObject
{
    Q_OBJECT
public:
    static Shell *self();

    // Option (Alt) is held right now.
    bool optionHeld() const
    {
        return m_option;
    }

    // loft-kwin's bridge is on the bus (the shell runs).
    bool online() const
    {
        return m_online;
    }

    // Ask the bridge for `action` ("menu", "tileMenu", "fullscreen") on the
    // window whose decoration is `frame` big, at `anchor` (decoration-local:
    // where a menu goes). False when the bridge isn't there: nothing was sent.
    // `failed` runs later if the call errors (the shell went away meanwhile).
    bool send(const QString &action, const QPointF &anchor, const QSizeF &frame, std::function<void()> failed = {});

Q_SIGNALS:
    void optionHeldChanged(bool held);

private Q_SLOTS:
    void modifiersChanged(Qt::KeyboardModifiers mods);

private:
    Shell();
    void watchModifiers();

    bool m_option = false;
    bool m_online = false;
};

} // namespace Loft
