#include "config.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
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

Look parseLook(const QString &ini, Look look)
{
    QString section;
    const auto lines = ini.split(QLatin1Char('\n'));
    for (const QString &raw : lines) {
        const QString line = raw.trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char(';'))) {
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
        const QString key = line.left(eq).trimmed();
        const QString value = line.mid(eq + 1).trimmed();
        if (section == QLatin1String("Colors")) {
            const QColor c = parseColor(value);
            if (!c.isValid()) {
                continue;
            }
            static const QList<std::pair<const char *, QColor Look::*>> colors = {
                {"TitleBarActive", &Look::titleBarActive},
                {"TitleBarInactive", &Look::titleBarInactive},
                {"TextActive", &Look::textActive},
                {"TextInactive", &Look::textInactive},
                {"Close", &Look::close},
                {"Minimize", &Look::minimize},
                {"Maximize", &Look::maximize},
                {"ButtonInactive", &Look::buttonInactive},
                {"Glyph", &Look::glyph},
                {"ShadowActive", &Look::shadowActive},
                {"ShadowInactive", &Look::shadowInactive},
            };
            for (const auto &[name, member] : colors) {
                if (key == QLatin1String(name)) {
                    look.*member = c;
                }
            }
        } else if (section == QLatin1String("Metrics")) {
            bool ok = false;
            const qreal n = value.toDouble(&ok);
            if (!ok || n < 0 || n > 200) {
                continue;
            }
            static const QList<std::pair<const char *, qreal Look::*>> metrics = {
                {"CornerRadius", &Look::cornerRadius},
                {"TitleBarHeight", &Look::titleBarHeight},
                {"ButtonSize", &Look::buttonSize},
                {"ButtonSpacing", &Look::buttonSpacing},
                {"ButtonInset", &Look::buttonInset},
                {"FontSize", &Look::fontSize},
            };
            for (const auto &[name, member] : metrics) {
                if (key == QLatin1String(name)) {
                    look.*member = n;
                }
            }
        }
    }
    // Keep the beads inside the bar, and the title readable.
    look.titleBarHeight = std::max<qreal>(look.titleBarHeight, 8);
    look.buttonSize = std::min(look.buttonSize, look.titleBarHeight);
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
    Look look;
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
