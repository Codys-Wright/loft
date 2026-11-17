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
// "When Idle": lock / displays off / suspend timings (services/Idle.qml).
ColumnLayout {
    id: page
    spacing: 12

    readonly property bool devMode: Quickshell.env("LOFT_DEV") === "1"

    readonly property string currentName: {
        if (Vibes.chosenLock === "builtin" || (Vibes.chosenLock === "" && Vibes.defaultLock === ""))
            return "Loft (built-in)";
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

    // ── When idle (services/Idle.qml)
    SettingsCard {
        id: idleCard

        readonly property var eff: Idle.effective ?? ({})

        // Fixed choices plus the current value when it isn't one of them
        // (programs.loft.idle may say 7 min).
        function choices(list, current) {
            const v = list.slice();
            if (current !== undefined && !v.includes(current))
                v.push(current);
            v.sort((a, b) => (a === 0 ? Infinity : a) - (b === 0 ? Infinity : b));
            return v.map(x => ({ value: x, label: Idle.format(x) }));
        }

        PageHeader {
            title: "When Idle"
        }

        Text {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            color: Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            text: {
                if (!Idle.kde)
                    return "Under niri, swayidle locks and turns the displays off with programs.loft.idle; these settings apply in a Plasma (Loft) session.";
                const k = Idle.kdeValues;
                if (!k)
                    return "Plasma's locker and PowerDevil follow these while Loft runs.";
                return `Plasma's locker and PowerDevil follow these while Loft runs (KDE's own values come back without Loft). KDE now: lock ${Idle.format(k.lockAfter).toLowerCase()}, displays off ${Idle.format(k.screenOffAfter).toLowerCase()}, suspend ${Idle.format(k.suspendAfter).toLowerCase()}` + (Idle.matches ? "." : " (applying…)");
            }
        }

        Text {
            visible: Idle.error !== ""
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            text: Idle.error
            color: Theme.warn
            font.family: Theme.fontUi
            font.pixelSize: 11
        }

        SettingsRow {
            label: "Lock the screen after"
            SettingsSelect {
                options: idleCard.choices([0, 60, 120, 300, 600, 900, 1800, 3600], idleCard.eff.lockAfter)
                current: idleCard.eff.lockAfter
                onActivated: v => Idle.set("lockAfter", v)
            }
        }
        SettingsRow {
            label: "Turn displays off after"
            SettingsSelect {
                options: idleCard.choices([0, 60, 120, 300, 600, 900, 1800, 3600], idleCard.eff.screenOffAfter)
                current: idleCard.eff.screenOffAfter
                onActivated: v => Idle.set("screenOffAfter", v)
            }
        }
        SettingsRow {
            visible: Idle.kde
            label: "Sleep after"
            hint: "Keep Awake holds it off (Settings → Everyday)"
            SettingsSelect {
                options: idleCard.choices([0, 900, 1800, 3600, 7200], idleCard.eff.suspendAfter)
                current: idleCard.eff.suspendAfter
                onActivated: v => Idle.set("suspendAfter", v)
            }
        }
        SettingsRow {
            visible: Idle.kde
            label: "Unlock without password for"
            hint: "Right after an idle lock, a key or a move unlocks"
            SettingsSelect {
                options: [0, 5, 10, 30, 60].map(x => ({ value: x, label: x === 0 ? "No grace" : `${x} s` }))
                current: idleCard.eff.lockGrace
                onActivated: v => Idle.set("lockGrace", v)
            }
        }
        SettingsRow {
            visible: Idle.kde
            label: "Lock before sleep"
            SettingsSwitch {
                checked: Settings.idle.lockOnResume
                onToggled: on => Idle.set("lockOnResume", on)
            }
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
                title: "Loft"
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
