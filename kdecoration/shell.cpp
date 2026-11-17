#include "shell.h"

#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusServiceWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaMethod>
#include <QPointer>

namespace Loft
{

namespace
{
const QString Service = QStringLiteral("dev.loft.KWinBridge");
const QString Path = QStringLiteral("/Bridge");
const QString Interface = QStringLiteral("dev.loft.KWinBridge");
} // namespace

Shell *Shell::self()
{
    static Shell *instance = new Shell();
    return instance;
}

Shell::Shell()
{
    auto bus = QDBusConnection::sessionBus();
    auto *watcher = new QDBusServiceWatcher(Service, bus, QDBusServiceWatcher::WatchForOwnerChange, this);
    connect(watcher, &QDBusServiceWatcher::serviceOwnerChanged, this, [this](const QString &, const QString &, const QString &owner) {
        m_online = !owner.isEmpty();
    });
    // The current owner, without blocking KWin's thread.
    if (bus.isConnected()) {
        const QDBusMessage ask = QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.DBus"),
                                                                QStringLiteral("/org/freedesktop/DBus"),
                                                                QStringLiteral("org.freedesktop.DBus"),
                                                                QStringLiteral("NameHasOwner"));
        auto *call = new QDBusPendingCallWatcher(bus.asyncCall(QDBusMessage(ask) << Service), this);
        connect(call, &QDBusPendingCallWatcher::finished, this, [this](QDBusPendingCallWatcher *w) {
            const QDBusPendingReply<bool> reply = *w;
            if (!reply.isError() && reply.value()) {
                m_online = true;
            }
            w->deleteLater();
        });
    }
    watchModifiers();
}

void Shell::watchModifiers()
{
    // KWin::InputRedirection: InputRedirection::create(kwinApp()) in main.cpp.
    QObject *input = nullptr;
    if (auto *app = QCoreApplication::instance()) {
        for (QObject *child : app->children()) {
            if (qstrcmp(child->metaObject()->className(), "KWin::InputRedirection") == 0) {
                input = child;
                break;
            }
        }
    }
    if (!input) {
        return;
    }
    const QMetaObject *mo = input->metaObject();
    const int signal = mo->indexOfSignal(QMetaObject::normalizedSignature("keyboardModifiersChanged(Qt::KeyboardModifiers,Qt::KeyboardModifiers)"));
    const int slot = metaObject()->indexOfSlot(QMetaObject::normalizedSignature("modifiersChanged(Qt::KeyboardModifiers)"));
    if (signal >= 0 && slot >= 0) {
        connect(input, mo->method(signal), this, metaObject()->method(slot));
    }
}

void Shell::modifiersChanged(Qt::KeyboardModifiers mods)
{
    const bool held = mods & Qt::AltModifier;
    if (held != m_option) {
        m_option = held;
        Q_EMIT optionHeldChanged(held);
    }
}

bool Shell::send(const QString &action, const QPointF &anchor, const QSizeF &frame, std::function<void()> failed)
{
    if (!m_online) {
        return false;
    }
    const QJsonObject request{
        {QStringLiteral("action"), action},
        {QStringLiteral("x"), anchor.x()},
        {QStringLiteral("y"), anchor.y()},
        {QStringLiteral("width"), frame.width()},
        {QStringLiteral("height"), frame.height()},
    };
    QDBusMessage msg = QDBusMessage::createMethodCall(Service, Path, Interface, QStringLiteral("TitleBar"));
    msg << QString::fromUtf8(QJsonDocument(request).toJson(QJsonDocument::Compact));
    // Short: a hung shell shouldn't leave a click without an answer.
    auto *call = new QDBusPendingCallWatcher(QDBusConnection::sessionBus().asyncCall(msg, 1000), this);
    connect(call, &QDBusPendingCallWatcher::finished, this, [failed](QDBusPendingCallWatcher *w) {
        const QDBusPendingReply<bool> reply = *w;
        if ((reply.isError() || !reply.value()) && failed) {
            failed();
        }
        w->deleteLater();
    });
    return true;
}

} // namespace Loft
