import QtQuick
import qs.services

// Date over a large clock, macOS lock-screen style.
Column {
    id: root

    // Scales with the screen so it reads the same on a laptop and a 4K desk.
    property real sizeScale: 1.0

    readonly property bool twelveHour: /a/i.test(Qt.locale().timeFormat(Locale.ShortFormat))

    spacing: 0

    Timer {
        id: tick
        property date now: new Date()
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: now = new Date()
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: Qt.formatDateTime(tick.now, "dddd, MMMM d")
        color: Theme.withAlpha(Theme.text, 0.85)
        font.family: Theme.fontUi
        font.pixelSize: 24 * root.sizeScale
        font.weight: Font.DemiBold
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        // The locale decides 12/24 h; the AM/PM marker is dropped, as on macOS.
        text: root.twelveHour ? Qt.formatDateTime(tick.now, "h:mm AP").replace(/\s*[AaPp][Mm]$/, "") : Qt.formatDateTime(tick.now, "H:mm")
        color: Theme.withAlpha(Theme.text, 0.92)
        font.family: Theme.fontUi
        font.pixelSize: 120 * root.sizeScale
        font.weight: Font.Bold
        font.letterSpacing: -2 * root.sizeScale
    }
}
