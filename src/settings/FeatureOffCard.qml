import QtQuick
import QtQuick.Layouts
import qs.components
import qs.services

// Shown in place of a page whose module is switched off (General ▸
// Features): what the module does and the switch that turns it on. The
// page itself comes back as it was.
SettingsCard {
    id: card
    property string feature
    readonly property var module: Features.module(feature)

    visible: feature !== "" && !Features.on(feature)

    SettingsRow {
        label: `${card.module?.label ?? card.feature} is off`
        hint: (card.module?.description ?? "") + " · its menus, shortcuts and settings come back as they were"
        SettingsSwitch {
            checked: false
            onToggled: on => Features.set(card.feature, on)
        }
    }
}
