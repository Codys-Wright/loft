import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.services

// The radial menu on one screen (Radial.qml): a transparent overlay that
// takes the keyboard and pointer, with the wheel centered where the pointer
// was. Moving the pointer selects; releasing the held modifier (⌃ / ⌘ of
// ⌃⌘Space) runs the selection, a click runs it too. Keys: arrows / Tab turn
// the selection, Enter runs, 1–9 pick a slice, Esc closes (or leaves a
// submenu ring).
PanelWindow {
    id: root

    required property ShellScreen modelData
    screen: modelData

    readonly property bool shown: Radial.open && (Radial.screen || modelData.name) === modelData.name

    visible: shown || fade.running
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "loft:radial"
    WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    anchors {
        top: true
        bottom: true
        left: true
        right: true
    }
    color: "transparent"

    // Only once the wheel stops scaling: the region follows geometry, not scale.
    BackgroundEffect.blurRegion: blur
    Region {
        id: blur
        item: Theme.blur && shown && wheel.scale === 1 ? wheel.disc : null
        shape: RegionShape.Ellipse
    }

    onShownChanged: {
        if (shown) {
            keys.forceActiveFocus();
            placeTimeout.restart();
        }
    }

    // No pointer report (it's on another display): the middle of this one.
    Timer {
        id: placeTimeout
        interval: 120
        onTriggered: if (root.shown && !Radial.placed) {
            Radial.cx = root.width / 2;
            Radial.cy = root.height / 2;
        }
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        onPositionChanged: mouse => Radial.pointer(mouse.x, mouse.y)
        onEntered: Radial.pointer(mouseX, mouseY)
        onPressed: mouse => {
            Radial.pointer(mouse.x, mouse.y);
            if (mouse.button === Qt.RightButton)
                Radial.close();
        }
        // Press–drag–release from the wheel picks like a click.
        onReleased: mouse => {
            if (mouse.button === Qt.LeftButton || mouse.button === Qt.MiddleButton) {
                if (Radial.selectedSlice || Math.hypot(mouse.x - Radial.cx, mouse.y - Radial.cy) < Radial.hub)
                    Radial.click();
                else
                    Radial.close();
            }
        }
    }

    Item {
        id: keys
        focus: root.shown
        Keys.onReleased: event => {
            // The held modifier of ⌃⌘Space let go (Mod is Super, Alt or
            // ISO_Level3_Shift, depending on the keyboard setup).
            if (Radial.source === "key" && [Qt.Key_Control, Qt.Key_Meta, Qt.Key_Super_L, Qt.Key_Super_R, Qt.Key_Alt, Qt.Key_AltGr, Qt.Key_Mode_switch].includes(event.key)) {
                Radial.release();
                event.accepted = true;
            }
        }
        Keys.onPressed: event => {
            const sel = Radial.selection;
            const k = event.key;
            if (k === Qt.Key_Escape) {
                if (sel.child >= 0 || Radial.ring >= 0) {
                    Radial.ring = -1;
                    Radial.px = Radial.cx;
                    Radial.py = Radial.cy;
                } else
                    Radial.close();
            } else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) {
                if (Radial.selectedSlice?.children)
                    Radial.point(sel.main, 0);
                else
                    Radial.click();
            } else if (k === Qt.Key_Right || k === Qt.Key_Tab || k === Qt.Key_Down) {
                if (sel.child >= 0)
                    Radial.point(sel.main, sel.child + 1);
                else
                    Radial.point(sel.main < 0 ? 0 : sel.main + 1);
            } else if (k === Qt.Key_Left || k === Qt.Key_Backtab || k === Qt.Key_Up) {
                if (sel.child >= 0)
                    Radial.point(sel.main, sel.child - 1);
                else
                    Radial.point(sel.main < 0 ? Radial.slices.length - 1 : sel.main - 1);
            } else if (k >= Qt.Key_1 && k <= Qt.Key_9) {
                const i = k - Qt.Key_1;
                if (i < Radial.slices.length) {
                    Radial.point(i);
                    if (!Radial.slices[i].children)
                        Radial.click();
                    else
                        Radial.point(i, 0);
                }
            } else
                return;
            Radial.sticky = true;
            event.accepted = true;
        }
    }

    RadialWheel {
        id: wheel
        x: Radial.cx - width / 2
        y: Radial.cy - height / 2
        slices: Radial.slices
        selMain: Radial.selection.main
        selChild: Radial.selection.child
        ring: Radial.ring
        radius: Radial.radius
        hub: Radial.hub
        ringRadius: Radial.ringRadius
        caption: Radial.selectedSlice ? Radial.sliceLabel(Radial.selectedSlice) : (Radial.profile?.name ?? "") === "Default" || !Radial.profile ? "" : Radial.profile.name

        opacity: root.shown && Radial.placed ? 1 : 0
        scale: root.shown && Radial.placed ? 1 : 0.82
        Behavior on opacity {
            NumberAnimation {
                id: fade
                duration: root.shown ? 160 : 120
                easing.type: Easing.OutQuart
            }
        }
        Behavior on scale {
            NumberAnimation {
                duration: 200
                easing.type: Easing.OutQuart
            }
        }
    }
}
