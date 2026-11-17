import QtQuick
import qs.desktopmenu
import qs.services

// The desktop's mouse, on a wallpaper surface: a right-click (a click that
// lands on no window) opens the desktop menu at the pointer
// (desktopmenu/DesktopMenu.qml). With per-workspace surfaces niri gives
// input only to the one whose workspace is on screen.
MouseArea {
    required property string screenName

    enabled: Features.on("desktopMenu")
    acceptedButtons: Qt.RightButton
    onPressed: mouse => DesktopMenu.openAt(screenName, mouse.x, mouse.y)
}
