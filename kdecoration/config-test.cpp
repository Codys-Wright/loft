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

    // No file, or no appearance: Tahoe dark.
    const Look dark = tahoeLook(true);
    const Look light = tahoeLook(false);
    CHECK(parseLook(QString()) == dark);
    CHECK(dark.titleBarActive == QColor(0x33, 0x33, 0x33)); // MacTahoe-Dark decoration.svg
    CHECK(light.titleBarActive == QColor(0xff, 0xff, 0xff));
    CHECK(light.textInactive == QColor(177, 177, 177)); // MacTahoe-Lightrc InactiveTextColor
    CHECK(dark.cornerRadius == 24 && dark.titleBarHeight == 34 && dark.fontSize == 13);

    // The appearance applies wherever it is in the file, overrides on top.
    const Look l = parseLook(QStringLiteral("; comment\n"
                                            "[Colors]\n"
                                            "TitleBarActive=#e6e9ef\n"
                                            "TextInactive=nonsense\n"
                                            "Close=#000000\n" // traffic lights are fixed
                                            "[Metrics]\n"
                                            "CornerRadius=0\n"
                                            "TitleBarHeight=12\n"
                                            "FontSize=-3\n"
                                            "[Other]\n"
                                            "TextActive=#000000\n"
                                            "[General]\n"
                                            "Appearance = Light\n"));
    CHECK(!l.dark);
    CHECK(l.titleBarActive == QColor(0xe6, 0xe9, 0xef));
    CHECK(l.titleBarInactive == light.titleBarInactive);
    CHECK(l.textInactive == light.textInactive); // a bad value keeps Tahoe's
    CHECK(l.textActive == light.textActive); // only [Colors] sets colors
    CHECK(l.cornerRadius == 0);
    CHECK(l.titleBarHeight == 26); // clamped: the beads fit
    CHECK(l.fontSize == light.fontSize); // negative ignored
    CHECK(parseLook(QStringLiteral("[General]\nAppearance=dark\n")) == dark);
    CHECK(parseLook(QStringLiteral("[General]\nAppearance=sepia\n")) == dark);

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
