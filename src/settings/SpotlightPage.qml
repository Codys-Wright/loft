import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Spotlight: the default web search, favorite !bangs and
// Quicklinks (your own keywords: "yt lofi", "np firefox", "gm"). Changes save
// as you leave a field and apply on Spotlight's next keystroke.
// Data: services/Spotlight.qml (<state>/spotlight.json).
ColumnLayout {
    id: page
    spacing: 12

    component Hint: Text {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 12
    }

    SettingsCard {
        PageHeader {
            title: "Spotlight"
        }

        Hint {
            text: "Type ! to browse 13,500 DuckDuckGo bangs (!nixpk finds NixOS Packages). Enter or Tab scopes Spotlight to the engine — type the search, Enter opens it; Backspace leaves. !yt lofi searches right away. Quicklinks below work without the !: yt, then Enter, or yt lofi."
        }

        SettingsRow {
            label: "Default search engine"
            hint: "Plain queries offer “Search … for …” with it"

            SettingsSelect {
                options: {
                    const opts = Spotlight.engines.slice();
                    if (!opts.some(o => o.value === Spotlight.defaultEngine))
                        opts.push({ value: Spotlight.defaultEngine, label: "!" + Spotlight.defaultEngine });
                    return opts;
                }
                current: Spotlight.defaultEngine
                onActivated: v => Spotlight.setDefaultEngine(v)
            }
            SettingsTextField {
                implicitWidth: 110
                placeholder: "or any !bang"
                text: Spotlight.engines.some(o => o.value === Spotlight.defaultEngine) ? "" : "!" + Spotlight.defaultEngine
                onCommitted: t => {
                    if (t.trim() !== "")
                        Spotlight.setDefaultEngine(t);
                }
            }
        }

        SettingsRow {
            label: "Favorite bangs"
            hint: "First in the ! list, after quicklinks"

            SettingsTextField {
                implicitWidth: 320
                placeholder: "yt gh nixpkgs w"
                text: Spotlight.favorites.join(" ")
                onCommitted: t => Spotlight.setFavorites(t.split(/[\s,]+/))
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: "Quicklinks"
            SettingsButton {
                text: "Add custom link"
                onClicked: Spotlight.addQuicklink({ keyword: "link", name: "New quicklink", url: "https://example.com/search?q=%TERM%" })
            }
        }

        Hint {
            text: "A keyword, then a !bang or your own URL (%TERM% marks the search; without it the link just opens). Typing the exact keyword makes it Spotlight's first result. In a !bang scope, Ctrl+K creates a quicklink for it."
        }

        // Pick a bang: search, click to add.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            SettingsTextField {
                id: bangSearch
                Layout.fillWidth: true
                placeholder: "Add from bangs — search “nixpk”, “youtube”, “maps”…"
                onEdited: t => {
                    bangSearch.current = t;
                    searchDelay.restart();
                }
                onCommitted: t => {
                    bangSearch.current = t;
                    searchDelay.restart();
                }
                property string current: ""
            }

            Timer {
                id: searchDelay
                interval: 120
                onTriggered: Spotlight.searchBangs(bangSearch.current)
            }
        }

        Repeater {
            model: bangSearch.current.trim() === "" ? [] : Spotlight.bangResults

            delegate: Rectangle {
                id: hit
                required property var modelData
                Layout.fillWidth: true
                implicitHeight: 34
                radius: 8
                color: hitMouse.containsMouse ? Theme.withAlpha(Theme.accent, 0.18) : Theme.withAlpha(Theme.text, 0.04)

                RowLayout {
                    anchors {
                        fill: parent
                        leftMargin: 10
                        rightMargin: 10
                    }
                    spacing: 10
                    Text {
                        text: hit.modelData.name
                        color: Theme.text
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                        font.weight: Font.Medium
                    }
                    Text {
                        Layout.fillWidth: true
                        text: hit.modelData.detail
                        color: Theme.subtext
                        font.family: Theme.fontUi
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                    Text {
                        text: "Add"
                        color: Theme.accent
                        font.family: Theme.fontUi
                        font.pixelSize: 12
                    }
                }

                MouseArea {
                    id: hitMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Spotlight.addQuicklink({
                        keyword: hit.modelData.key,
                        name: hit.modelData.name,
                        bang: hit.modelData.key
                    })
                }
            }
        }

        // Keyed by count, not the array: saving one quicklink must not rebuild
        // every row (and steal focus from the field being edited).
        Repeater {
            model: Spotlight.quicklinks.length

            delegate: RowLayout {
                id: card
                required property int index
                readonly property var ql: Spotlight.quicklinks[index] ?? ({})
                Layout.fillWidth: true
                spacing: 8

                SettingsTextField {
                    implicitWidth: 72
                    placeholder: "keyword"
                    text: card.ql.keyword ?? ""
                    onCommitted: t => {
                        const kw = t.trim().toLowerCase().replace(/\s+/g, "");
                        if (kw !== "")
                            Spotlight.updateQuicklink(card.ql.id, { keyword: kw });
                    }
                }
                SettingsTextField {
                    implicitWidth: 170
                    placeholder: "Name"
                    text: card.ql.name ?? ""
                    onCommitted: t => Spotlight.updateQuicklink(card.ql.id, { name: t })
                }
                SettingsTextField {
                    Layout.fillWidth: true
                    placeholder: "!bang or https://…%TERM%"
                    text: card.ql.bang ? "!" + card.ql.bang : (card.ql.url ?? "")
                    onCommitted: t => {
                        const v = t.trim();
                        if (v.startsWith("!"))
                            Spotlight.updateQuicklink(card.ql.id, { bang: v.slice(1), url: "" });
                        else
                            Spotlight.updateQuicklink(card.ql.id, { url: v, bang: "" });
                    }
                }
                SettingsButton {
                    text: "↑"
                    enabled: card.index > 0
                    onClicked: Spotlight.moveQuicklink(card.ql.id, -1)
                }
                SettingsButton {
                    text: "↓"
                    enabled: card.index < Spotlight.quicklinks.length - 1
                    onClicked: Spotlight.moveQuicklink(card.ql.id, 1)
                }
                SettingsButton {
                    text: "Test"
                    onClicked: Spotlight.test(card.ql)
                }
                SettingsButton {
                    text: "Delete"
                    onClicked: Spotlight.removeQuicklink(card.ql.id)
                }
            }
        }
    }
}
