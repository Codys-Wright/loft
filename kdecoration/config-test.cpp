// The INI parsing the decoration does, without KWin (ctest).
#include "config.h"

#include <cstdio>

static int failures = 0;
#define CHECK(cond)                                                                                                                                            \
    do {                                                                                                                                                       \
        if (!(cond)) {                                                                                                                                         \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                                              \
            ++failures;                                                                                                                                        \
        }                                                                                                                                                      \
    } while (0)

int main()
{
    using namespace Loft;
    // Loft's #rrggbbaa, not Qt's #aarrggbb.
    CHECK(parseColor(QStringLiteral("#4c4f6938")) == QColor(0x4c, 0x4f, 0x69, 0x38));
    CHECK(parseColor(QStringLiteral("#ff5f57")) == QColor(0xff, 0x5f, 0x57));
    CHECK(!parseColor(QStringLiteral("red")).isValid());
    CHECK(!parseColor(QStringLiteral("#12345")).isValid());

    const Look defaults;
    const Look l = parseLook(QStringLiteral("; comment\n"
                                            "[Colors]\n"
                                            "TitleBarActive=#e6e9ef\n"
                                            "ButtonInactive = #4c4f6938\n"
                                            "Close=nonsense\n"
                                            "Unknown=#000000\n"
                                            "[Metrics]\n"
                                            "CornerRadius=0\n"
                                            "TitleBarHeight=30\n"
                                            "ButtonSize=50\n"
                                            "FontSize=-3\n"
                                            "[Other]\n"
                                            "TextActive=#000000\n"));
    CHECK(l.titleBarActive == QColor(0xe6, 0xe9, 0xef));
    CHECK(l.buttonInactive == QColor(0x4c, 0x4f, 0x69, 0x38));
    CHECK(l.close == defaults.close); // a bad value keeps the default
    CHECK(l.textActive == defaults.textActive); // only [Colors] sets colors
    CHECK(l.cornerRadius == 0);
    CHECK(l.titleBarHeight == 30);
    CHECK(l.buttonSize == 30); // clamped to the bar
    CHECK(l.fontSize == defaults.fontSize); // negative ignored

    CHECK(parseLook(QString()) == defaults);

    qputenv("LOFT_STATE_DIR", "/s");
    CHECK(lookPath() == QStringLiteral("/s/current/kdecoration.ini"));
    qunsetenv("LOFT_STATE_DIR");
    qputenv("XDG_STATE_HOME", "/x");
    CHECK(lookPath() == QStringLiteral("/x/loft/current/kdecoration.ini"));

    if (failures == 0) {
        std::puts("config-test: ok");
    }
    return failures == 0 ? 0 : 1;
}
