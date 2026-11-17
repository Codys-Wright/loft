import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Appearance (below its overview, AppearanceOverview):
// transparency and blur, the menu bar's look, light / dark, the theme
// chooser and Spotify's colors. Moved here from SettingsApp.qml unchanged.
ColumnLayout {
    id: page
    spacing: 12

    component Row_: SettingsRow {}
    component Switch_: SettingsSwitch {}
    component Card: SettingsCard {}

    // Appearance: Transparency + Blur first (the shell's own
    // Liquid Glass slider is under its Advanced).
    TransparencyCard {}

    Card {
        Row_ {
            label: "Reduce transparency"
            hint: "Flat, opaque menus, panels and windows; no blur"
            Switch_ {
                checked: Theme.reduceTransparency
                onToggled: on => Settings.appearance.reduceTransparency = on
            }
        }

        Row_ {
            label: "Shell blur"
            hint: Theme.reduceTransparency ? "Off with Reduce transparency" : (Settings.appearance.blur < 0 ? "Following the theme" : "Overridden") + " · menus, panels and the dock blur what's behind them"
            enabled: !Theme.reduceTransparency
            Switch_ {
                checked: Theme.blur
                enabled: !Theme.reduceTransparency
                onToggled: on => Settings.appearance.blur = on ? 1 : 0
            }
        }

        Row_ {
            label: "Show menu bar background"
            hint: "Off: titles and icons sit on the wallpaper"
            Switch_ {
                checked: Theme.barBackground
                onToggled: on => Settings.appearance.barBackground = on ? 1 : 0
            }
        }

        Row_ {
            label: "Adaptive menu bar text"
            hint: Theme.barBackground ? "Only without the menu bar background" : "Light or dark from the wallpaper under the bar"
            enabled: !Theme.barBackground
            Switch_ {
                checked: Theme.barAdaptiveText
                enabled: !Theme.barBackground
                onToggled: on => Settings.appearance.barAdaptiveText = on ? 1 : 0
            }
        }

        Text {
            visible: Settings.appearance.blur >= 0 || Settings.appearance.barBackground >= 0 || Settings.appearance.barAdaptiveText >= 0
            text: "Reset to theme"
            color: Theme.accent
            font.family: Theme.fontUi
            font.pixelSize: 12
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    Settings.appearance.blur = -1;
                    Settings.appearance.barBackground = -1;
                    Settings.appearance.barAdaptiveText = -1;
                }
            }
        }

        Row_ {
            label: "Appearance"
            hint: ThemeManager.hasModes ? "Light or dark for the shell, niri, terminals and apps" : `${ThemeManager.label || "This theme"} has only a ${Theme.dark ? "dark" : "light"} look`
            enabled: ThemeManager.hasModes && !ThemeManager.applying
            SettingsSegmented {
                options: [
                    {
                        value: "light",
                        label: "Prefer Light"
                    },
                    {
                        value: "dark",
                        label: "Prefer Dark"
                    }
                ]
                current: Theme.dark ? "dark" : "light"
                enabled: ThemeManager.hasModes && !ThemeManager.applying
                onActivated: v => ThemeManager.setMode(v)
            }
        }

        Row_ {
            label: "Theme"
            hint: ThemeManager.applying ? "Applying…" : ThemeManager.error || "Recolors the shell, niri, terminals, GTK and the launcher"
        }

        Flow {
            Layout.fillWidth: true
            spacing: 10

            Repeater {
                model: ThemeManager.themes

                delegate: Rectangle {
                    id: card
                    required property var modelData
                    readonly property var p: modelData.palette
                    readonly property bool current: modelData.name === Theme.name

                    width: 150
                    height: 104
                    radius: 14
                    color: p.bg
                    border.width: current ? 3 : 1
                    border.color: current ? Theme.accent : Theme.glassBorder

                    // A tiny desktop: wallpaper strip, glass bar, accent dots.
                    Rectangle {
                        anchors {
                            left: parent.left
                            right: parent.right
                            top: parent.top
                            margins: 8
                        }
                        height: 50
                        radius: 8
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0; color: (card.modelData.wallpaper?.gradient ?? [])[0] ?? card.p.surface }
                            GradientStop { position: 1; color: (card.modelData.wallpaper?.gradient ?? [])[2] ?? card.p.overlay }
                        }

                        Rectangle {
                            anchors {
                                left: parent.left
                                right: parent.right
                                top: parent.top
                                margins: 5
                            }
                            height: 10
                            radius: 5
                            color: Theme.withAlpha(card.modelData.glass?.tint ?? card.p.bg, 0.6)
                        }

                        Row {
                            anchors {
                                left: parent.left
                                bottom: parent.bottom
                                margins: 6
                            }
                            spacing: 4
                            Repeater {
                                model: [card.p.accent, card.p.accent2, card.p.ok, card.p.warn, card.p.urgent]
                                delegate: Rectangle {
                                    required property var modelData
                                    width: 10
                                    height: 10
                                    radius: 5
                                    color: modelData
                                }
                            }
                        }
                    }

                    Text {
                        anchors {
                            left: parent.left
                            right: polarityGlyph.left
                            bottom: parent.bottom
                            margins: 10
                            rightMargin: 6
                        }
                        text: card.modelData.name
                        color: card.p.text
                        font.family: Theme.fontUi
                        font.pixelSize: 13
                        font.weight: card.current ? Font.Bold : Font.Medium
                        elide: Text.ElideRight
                    }

                    Text {
                        id: polarityGlyph
                        anchors {
                            right: parent.right
                            bottom: parent.bottom
                            margins: 10
                        }
                        text: card.modelData.polarity === "light" ? "󰖨" : "󰖔"
                        color: card.p.subtext
                        font.family: Theme.fontIcons
                        font.pixelSize: 12
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: ThemeManager.apply(card.modelData.name)
                    }
                }
            }
        }
    }

    // Appearance → Spotify (programs.loft.spotify)
    SpotifyCard {
        visible: SpotifyTheme.configured || SpotifyTheme.setUp
    }
}
