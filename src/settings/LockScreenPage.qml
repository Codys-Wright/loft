import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.services

// Settings → Lock Screen: which design locks the screen with this theme.
// "From <theme>": the built-in design, the theme's own designs and curated
// ones; "Matching vibes": every other installed pack's, closest colors
// first. Thumbnails are the pack's preview image when it ships one, else a
// static card in the design's colors over its backdrop. Choices are per
// theme (Vibes); "Preview lock" locks now with the current choice.
ColumnLayout {
    id: page
    spacing: 12

    readonly property bool devMode: Quickshell.env("STUDIO_DEV") === "1"

    readonly property string currentName: {
        if (Vibes.chosenLock === "builtin" || (Vibes.chosenLock === "" && Vibes.defaultLock === ""))
            return "Studio (built-in)";
        const path = Vibes.chosenLock || Vibes.defaultLock;
        const l = Vibes.locks.find(x => x.path === path);
        return l ? `${l.name} · ${l.source_pack}` : path.split("/").pop();
    }

    component LockThumb: VibeThumb {
        id: lt
        required property var modelData
        image: modelData.preview ?? ""
        title: modelData.name
        subtitle: (modelData.origin === "curated" ? "Curated · " : "") + modelData.source_pack + (modelData.format === "qylock" ? " · qylock" : "")
        isDefault: modelData.path === Vibes.defaultLock
        selected: Vibes.isCurrentLock(modelData.path)
        badge: Vibes.lockErrorDesign === modelData.path && Vibes.lockError !== "" ? "fails to load" : ""
        onClicked: Vibes.chooseLock(modelData.origin === "own" && modelData.path === Vibes.defaultLock ? "" : modelData.path)

        LockPreviewCard {
            visible: !lt.modelData.preview
            colors: lt.modelData.palette ?? {}
            background: lt.modelData.background ?? ""
        }
    }

    SettingsCard {
        PageHeader {
            title: "Lock Screen"
            SettingsButton {
                text: "Use theme default"
                enabled: Vibes.chosenLock !== ""
                onClicked: Vibes.chooseLock("")
            }
            SettingsButton {
                text: "Preview lock"
                icon: "󰌾"
                primary: true
                onClicked: Vibes.previewLock()
            }
        }

        SettingsRow {
            label: "Design for " + Vibes.theme
            hint: page.currentName + (page.devMode ? "  ·  dev session: unlock with `lock devUnlock`" : "")
        }

        Text {
            visible: Vibes.lockError !== ""
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
            text: `${Vibes.lockErrorDesign.split("/").slice(-3).join("/")} didn't load, so the built-in design was used: ${Vibes.lockError}`
            color: Theme.warn
            font.family: Theme.fontUi
            font.pixelSize: 11
        }
    }

    SettingsCard {
        PageHeader {
            title: "From " + Vibes.theme
        }

        Flow {
            Layout.fillWidth: true
            spacing: 10

            VibeThumb {
                title: "Studio"
                subtitle: "built-in · follows the theme"
                isDefault: Vibes.defaultLock === ""
                selected: Vibes.isCurrentLock("builtin")
                onClicked: Vibes.chooseLock(Vibes.defaultLock === "" ? "" : "builtin")

                LockPreviewCard {
                    frosted: true
                    colors: ({ bg: Theme.bg, surface: Theme.surface, text: Theme.text, accent: Theme.accent })
                    background: Vibes.wallpaperFor("")
                }
            }

            Repeater {
                model: Vibes.themeLocks
                delegate: LockThumb {}
            }
        }
    }

    SettingsCard {
        PageHeader {
            title: "Matching vibes"
        }

        Text {
            Layout.fillWidth: true
            text: Vibes.matchingLocks.length === 0 ? (Vibes.loading ? "Ranking…" : "No other lock designs installed (qylock: and cozytile: packs bring them).") : "Lock designs of other installed themes, closest colors first"
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
        }

        Flow {
            Layout.fillWidth: true
            spacing: 10

            Repeater {
                model: Vibes.matchingLocks
                delegate: LockThumb {
                    score: modelData.score ?? -1
                }
            }
        }
    }
}
