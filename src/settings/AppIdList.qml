import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// An editable list of app ids (niri app-id): a row per app (icon, name,
// remove) and an "Add app" picker of running apps, or any id typed in.
// Settings → Everyday (Keep Awake, Quit lists), Keyboard Shortcuts (Apps to
// leave alone).
ColumnLayout {
    id: list
    property var apps: []
    property string emptyText: "No apps yet"
    signal changed(var apps)
    Layout.fillWidth: true
    spacing: 6

    // Apps to pick from: running ones first, then those already listed.
    function candidates(listed) {
        const ids = [...new Set(Niri.windows.map(w => w.app_id).filter(a => a && Apps.own[a] === undefined))];
        return ids.filter(a => !listed.includes(a)).sort((a, b) => Apps.name(a).localeCompare(Apps.name(b))).map(a => ({ value: a, label: Apps.name(a) }));
    }

    Repeater {
        model: list.apps
        delegate: RowLayout {
            required property string modelData
            Layout.fillWidth: true
            spacing: 10
            AppIcon {
                Layout.preferredWidth: 20
                Layout.preferredHeight: 20
                appId: modelData
                pixelSize: 40
            }
            Text {
                Layout.fillWidth: true
                text: `${Apps.name(modelData)}  ·  ${modelData}`
                color: Theme.text
                font.family: Theme.fontUi
                font.pixelSize: 13
                elide: Text.ElideRight
            }
            SettingsButton {
                text: "Remove"
                onClicked: list.changed(list.apps.filter(a => a !== modelData))
            }
        }
    }
    Text {
        visible: list.apps.length === 0
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        text: list.emptyText
        color: Theme.subtext
        font.family: Theme.fontUi
        font.pixelSize: 12
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        SettingsSelect {
            Layout.fillWidth: true
            placeholder: "Add a running app…"
            options: list.candidates(list.apps)
            current: null
            onActivated: v => list.changed(list.apps.concat([v]))
        }
        SettingsTextField {
            id: idField
            implicitWidth: 180
            placeholder: "or an app id"
            onCommitted: t => {
                const id = t.trim();
                if (id !== "" && !list.apps.includes(id))
                    list.changed(list.apps.concat([id]));
                idField.clear();
            }
        }
    }
}
