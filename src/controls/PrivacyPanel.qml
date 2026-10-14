import QtQuick
import QtQuick.Layouts
import qs.services

// The camera indicator's menu: who uses a camera, who records audio.
ColumnLayout {
    id: root

    property bool details: false
    property bool shown: true
    property bool inMenu: true
    signal dismiss
    signal openSettings(string section)

    spacing: 0

    PanelHeader {
        title: "Camera & Microphone"
    }

    PanelSection {
        text: "Camera"
    }
    Repeater {
        model: Privacy.cameraUsers
        delegate: PanelRow {
            required property var modelData
            interactive: false
            text: modelData.name
            detail: modelData.pid ? `PID ${modelData.pid}` : ""
            glyph: "󰄀"
            glyphActive: true
        }
    }
    PanelRow {
        visible: Privacy.cameraUsers.length === 0
        interactive: false
        dim: true
        text: "Not in use"
    }

    PanelSection {
        text: "Microphone"
    }
    Repeater {
        model: Sound.recordingApps
        delegate: PanelRow {
            required property var modelData
            interactive: false
            text: modelData
            glyph: "󰍬"
            glyphActive: true
        }
    }
    PanelRow {
        visible: Sound.recordingApps.length === 0
        interactive: false
        dim: true
        text: "Not in use"
    }
}
