#include "config.h"
#include "tahoe.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QTimer>

namespace Loft
{

QColor parseColor(const QString &text)
{
    const QString s = text.trimmed();
    if (!s.startsWith(QLatin1Char('#')) || (s.size() != 7 && s.size() != 9)) {
        return {};
    }
    bool ok = false;
    const uint v = s.mid(1).toUInt(&ok, 16);
    if (!ok) {
        return {};
    }
    if (s.size() == 7) {
        return QColor((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
    }
    return QColor((v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff);
}

Look tahoeLook(bool dark)
{
    const Tahoe::Palette &p = Tahoe::palette(dark);
    Look look;
    look.dark = dark;
    look.titleBarActive = p.bar;
    look.titleBarInactive = p.barInactive;
    look.textActive = p.text;
    look.textInactive = p.textInactive;
    look.cornerRadius = Tahoe::CornerRadius;
    look.titleBarHeight = Tahoe::TitleBarHeight;
    look.fontSize = Tahoe::TitleFontSize;
    return look;
}

Look parseLook(const QString &ini)
{
    // Collect first: the appearance decides the defaults the other keys
    // override, wherever it appears in the file.
    QHash<QString, QString> values; // "Section/Key" → value
    QString section;
    const auto lines = ini.split(QLatin1Char('\n'));
    for (const QString &raw : lines) {
        const QString line = raw.trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char(';')) || line.startsWith(QLatin1Char('#'))) {
            continue;
        }
        if (line.startsWith(QLatin1Char('[')) && line.endsWith(QLatin1Char(']'))) {
            section = line.mid(1, line.size() - 2).trimmed();
            continue;
        }
        const int eq = line.indexOf(QLatin1Char('='));
        if (eq <= 0) {
            continue;
        }
        values.insert(section + QLatin1Char('/') + line.left(eq).trimmed(), line.mid(eq + 1).trimmed());
    }

    const QString appearance = values.value(QStringLiteral("General/Appearance")).toLower();
    Look look = tahoeLook(appearance != QLatin1String("light"));

    static const QList<std::pair<const char *, QColor Look::*>> colors = {
        {"TitleBarActive", &Look::titleBarActive},
        {"TitleBarInactive", &Look::titleBarInactive},
        {"TextActive", &Look::textActive},
        {"TextInactive", &Look::textInactive},
    };
    for (const auto &[name, member] : colors) {
        const QColor c = parseColor(values.value(QLatin1String("Colors/") + QLatin1String(name)));
        if (c.isValid()) {
            look.*member = c;
        }
    }
    static const QList<std::pair<const char *, qreal Look::*>> metrics = {
        {"CornerRadius", &Look::cornerRadius},
        {"TitleBarHeight", &Look::titleBarHeight},
        {"FontSize", &Look::fontSize},
    };
    for (const auto &[name, member] : metrics) {
        bool ok = false;
        const qreal n = values.value(QLatin1String("Metrics/") + QLatin1String(name)).toDouble(&ok);
        if (ok && n >= 0 && n <= 200) {
            look.*member = n;
        }
    }
    // Keep the beads inside the bar, and the title readable.
    look.titleBarHeight = std::max<qreal>(look.titleBarHeight, Tahoe::ButtonTop + Tahoe::ButtonCell);
    look.fontSize = std::max<qreal>(look.fontSize, 6);
    return look;
}

QString lookPath()
{
    QString state = qEnvironmentVariable("LOFT_STATE_DIR");
    if (state.isEmpty()) {
        QString xdg = qEnvironmentVariable("XDG_STATE_HOME");
        if (xdg.isEmpty()) {
            xdg = QDir::homePath() + QLatin1String("/.local/state");
        }
        state = xdg + QLatin1String("/loft");
    }
    return state + QLatin1String("/current/kdecoration.ini");
}

Config *Config::self()
{
    static Config *instance = new Config();
    return instance;
}

Config::Config()
    : m_path(lookPath())
{
    // `current` is a link the theme engine swaps atomically, so watch the
    // file, the directory it lives in and the state dir that holds the link.
    // Several events arrive per swap: coalesce them.
    auto *debounce = new QTimer(this);
    debounce->setSingleShot(true);
    debounce->setInterval(150);
    connect(debounce, &QTimer::timeout, this, [this] {
        reload();
        rewatch();
    });
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, debounce, qOverload<>(&QTimer::start));
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, debounce, qOverload<>(&QTimer::start));
    reload();
    rewatch();
}

void Config::reload()
{
    Look look = tahoeLook(true);
    QFile f(m_path);
    if (f.open(QIODevice::ReadOnly)) {
        look = parseLook(QString::fromUtf8(f.readAll()));
    }
    if (!(look == m_look)) {
        m_look = look;
        Q_EMIT changed();
    }
}

void Config::rewatch()
{
    if (!m_watcher.files().isEmpty()) {
        m_watcher.removePaths(m_watcher.files());
    }
    if (!m_watcher.directories().isEmpty()) {
        m_watcher.removePaths(m_watcher.directories());
    }
    const QFileInfo file(m_path);
    const QString current = file.absolutePath();
    const QString state = QFileInfo(current).absolutePath();
    // Create nothing: a missing state dir means the defaults, until Loft
    // renders a theme (then KWin's reconfigure or a new window picks it up).
    for (const QString &p : {m_path, current, state}) {
        if (QFileInfo::exists(p)) {
            m_watcher.addPath(p);
        }
    }
}

} // namespace Loft
