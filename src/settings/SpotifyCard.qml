import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Settings → Appearance → Spotify: the themed Spotify (programs.loft.spotify,
// services/SpotifyTheme.qml). Shown once it is configured.
SettingsCard {
    id: card

    readonly property var sp: SpotifyTheme

    // The owner shows it while SpotifyTheme.configured || .setUp.
    onVisibleChanged: if (visible)
        sp.refresh()
    Component.onCompleted: sp.refresh()

    PageHeader {
        title: "Spotify"
    }

    SettingsRow {
        label: "Status"
        hint: card.statusText()
        hintColor: card.sp.error !== "" ? Theme.urgent : Theme.subtext

        SettingsButton {
            text: card.sp.busy ? "Working…" : "Re-apply"
            enabled: !card.sp.busy && card.sp.configured
            onClicked: card.sp.reapply()
        }
    }

    SettingsRow {
        label: "Follow theme"
        hint: card.sp.follow ? `Recolors live with the theme (scheme “${card.sp.themeSchemes[0] ?? "loft"}”)` : "Keeps the scheme below"
        SettingsSwitch {
            checked: card.sp.follow
            enabled: !card.sp.busy
            onToggled: on => card.sp.setFollow(on)
        }
    }

    SettingsRow {
        label: "Color scheme"
        hint: "spicetify-themes' text theme"
        enabled: !card.sp.follow
        SettingsSelect {
            enabled: !card.sp.follow && !card.sp.busy && card.sp.schemes.length > 0
            options: card.sp.schemes.map(s => ({
                        value: s,
                        label: s
                    }))
            current: card.sp.activeScheme
            placeholder: card.sp.activeScheme || "—"
            onActivated: v => card.sp.setScheme(v)
        }
    }

    function statusText() {
        if (sp.error !== "")
            return sp.error;
        if (sp.note !== "")
            return sp.note;
        if (!sp.setUp)
            return sp.pending ? "Not set up yet: runs at login or when Spotify starts" : "Not set up";
        let s = `Set up · Spotify ${sp.version}`;
        if (sp.pending === "copy")
            s += sp.running ? " · update waits for Spotify to quit" : " · update on next launch";
        else if (sp.pending === "apply")
            s += " · changes on next launch (or Re-apply)";
        return s;
    }
}
