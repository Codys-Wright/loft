import QtQuick
import qs.desktopmenu
import qs.palette
import qs.services

// The desktop's mouse, on a wallpaper surface: a right-click (a click that
// lands on no window) opens the desktop menu at the pointer
// (desktopmenu/DesktopMenu.qml). The middle button held on the desktop opens
// the radial menu there: drag toward a slice and let go (palette/Radial.qml).
// The surface keeps the pointer until the release, so it feeds the wheel.
// With per-workspace surfaces niri gives input only to the one whose
// workspace is on screen.
MouseArea {
    required property string screenName

    enabled: Features.on("desktopMenu") || Features.on("radialMenu")
    acceptedButtons: (Features.on("desktopMenu") ? Qt.RightButton : 0) | (Features.on("radialMenu") ? Qt.MiddleButton : 0)
    onPressed: mouse => {
        if (mouse.button === Qt.MiddleButton)
            Radial.openAt(screenName, mouse.x, mouse.y, "mouse");
        else
            DesktopMenu.openAt(screenName, mouse.x, mouse.y);
    }
    onPositionChanged: mouse => {
        if (pressedButtons & Qt.MiddleButton)
            Radial.pointer(mouse.x, mouse.y);
    }
    onReleased: mouse => {
        if (mouse.button === Qt.MiddleButton)
            Radial.release();
    }
}
