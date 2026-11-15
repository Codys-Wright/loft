// Loft's decoration look: built-in defaults, overridden by the theme's
// <state>/current/kdecoration.ini (cli/loft/render/kdecoration.py), which is
// watched so a theme change repaints open windows.
#pragma once

#include <QColor>
#include <QFileSystemWatcher>
#include <QObject>
#include <QString>

namespace Loft
{

struct Look {
    QColor titleBarActive{0x2c, 0x2c, 0x30};
    QColor titleBarInactive{0x22, 0x22, 0x26};
    QColor textActive{0xe6, 0xe6, 0xea};
    QColor textInactive{0x8a, 0x8a, 0x90};
    QColor close{0xff, 0x5f, 0x57};
    QColor minimize{0xfe, 0xbc, 0x2e};
    QColor maximize{0x28, 0xc8, 0x40};
    QColor buttonInactive{0xe6, 0xe6, 0xea, 0x38};
    QColor glyph{0, 0, 0, 0x8c};
    QColor shadowActive{0, 0, 0, 0x66};
    QColor shadowInactive{0, 0, 0, 0x29};
    qreal cornerRadius = 12;
    qreal titleBarHeight = 24;
    qreal buttonSize = 12;
    qreal buttonSpacing = 8;
    qreal buttonInset = 10;
    qreal fontSize = 11; // px

    bool operator==(const Look &) const = default;
};

// #rrggbb or #rrggbbaa (CSS / Loft order, not Qt's #aarrggbb); invalid → nullopt-ish (invalid QColor).
QColor parseColor(const QString &text);

// Applies an INI document's [Colors] / [Metrics] keys over `base`. Unknown
// keys and bad values are ignored (they keep base's value).
Look parseLook(const QString &ini, Look base = Look{});

// $LOFT_STATE_DIR, else $XDG_STATE_HOME/loft, else ~/.local/state/loft; + current/kdecoration.ini.
QString lookPath();

class Config : public QObject
{
    Q_OBJECT
public:
    static Config *self();
    const Look &look() const
    {
        return m_look;
    }

Q_SIGNALS:
    void changed();

private:
    Config();
    void reload();
    void rewatch();

    QString m_path;
    Look m_look;
    QFileSystemWatcher m_watcher;
};

} // namespace Loft
