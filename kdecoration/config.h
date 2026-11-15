// Loft's decoration look: macOS Tahoe's title bar (tahoe.h) in the theme's
// appearance, light or dark, from <state>/current/kdecoration.ini
// (cli/loft/render/kdecoration.py), which is watched so a theme change
// repaints open windows.
#pragma once

#include <QColor>
#include <QFileSystemWatcher>
#include <QObject>
#include <QString>

namespace Loft
{

struct Look {
    // [General] Appearance=light|dark. Picks Tahoe's light or dark bar,
    // text, grey beads, outline and shadow; the traffic lights' colors are
    // fixed per appearance (tahoe.h), as on macOS.
    bool dark = true;
    // Tahoe's values for the appearance, unless the INI overrides them
    // ([Colors], [Metrics]).
    QColor titleBarActive;
    QColor titleBarInactive;
    QColor textActive;
    QColor textInactive;
    qreal cornerRadius = 0;
    qreal titleBarHeight = 0;
    qreal fontSize = 0; // px

    bool operator==(const Look &) const = default;
};

// Tahoe's look for an appearance, nothing overridden.
Look tahoeLook(bool dark);

// #rrggbb or #rrggbbaa (CSS / Loft order, not Qt's #aarrggbb); anything else → an invalid QColor.
QColor parseColor(const QString &text);

// An INI document → a look: [General] Appearance (light | dark, default
// dark), then [Colors] TitleBarActive / TitleBarInactive / TextActive /
// TextInactive and [Metrics] CornerRadius / TitleBarHeight / FontSize over
// that appearance's Tahoe values. Unknown keys and bad values are ignored.
Look parseLook(const QString &ini);

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
    Look m_look = tahoeLook(true);
    QFileSystemWatcher m_watcher;
};

} // namespace Loft
