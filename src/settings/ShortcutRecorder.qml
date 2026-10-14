import QtQuick
import qs.components
import qs.services

// A shortcut as key caps (⌃ ⌥ ⇧ ❖ Mod + key) that records a new one when
// clicked, like macOS's shortcut fields: press the combination, Esc cancels,
// ⌫ alone clears (disables). Keys are named by their physical key (the
// event's xkb keycode → the US keysym niri binds), so ⇧1 is `Shift+1`, not
// `exclam`. Mod is ISO_Level3_Shift (Right Alt; Esc / Caps Lock held with
// xremap). niri runs its own binds before any window sees them, so a
// combination niri already has can't be pressed here: type it instead
// (Settings → Keyboard Shortcuts' “Type a shortcut” field).
Rectangle {
    id: rec

    property var modifiers: []
    property string trigger: ""
    property bool recording: false
    // Shown when there is no combo (a disabled shortcut).
    property string placeholder: "Off"
    property bool dim: false

    signal startRequested
    signal captured(string combo)
    signal cleared
    signal canceled

    // While recording: modifiers held right now (live feedback).
    property var held: []
    property bool modHeld: false
    property string hint: ""

    implicitWidth: Math.max(96, caps.implicitWidth + 16)
    implicitHeight: 26
    radius: 6
    color: recording ? Theme.withAlpha(Theme.accent, 0.18) : hover.containsMouse ? Theme.withAlpha(Theme.text, 0.1) : trigger === "" ? Theme.withAlpha(Theme.text, 0.05) : "transparent"
    border.width: recording ? 1.5 : 0
    border.color: Theme.accent
    opacity: dim && !recording ? 0.5 : 1

    onRecordingChanged: {
        held = [];
        modHeld = false;
        hint = "";
        if (recording)
            forceActiveFocus();
    }

    // ── Names ────────────────────────────────────────────────────────────
    function keyCap(part) {
        return ({
                Mod: "Mod",
                Shift: "⇧",
                Ctrl: "⌃",
                Alt: "⌥",
                Super: "⌘",
                ISO_Level3_Shift: "Mod",
                Return: "↩",
                Tab: "⇥",
                BackSpace: "⌫",
                Delete: "⌦",
                Escape: "Esc",
                Space: "Space",
                Left: "←",
                Right: "→",
                Up: "↑",
                Down: "↓",
                Page_Up: "PgUp",
                Page_Down: "PgDn",
                Slash: "/",
                Comma: ",",
                Period: ".",
                Minus: "−",
                Equal: "=",
                Semicolon: ";",
                Apostrophe: "'",
                Grave: "`",
                Bracketleft: "[",
                Bracketright: "]",
                Backslash: "\\",
                MouseBack: "Mouse Back",
                MouseForward: "Mouse Fwd",
                MouseMiddle: "Middle Click",
                WheelScrollUp: "Wheel ↑",
                WheelScrollDown: "Wheel ↓",
                XF86AudioRaiseVolume: "Vol +",
                XF86AudioLowerVolume: "Vol −",
                XF86AudioMute: "Mute",
                XF86AudioPlay: "Play",
                XF86AudioNext: "Next",
                XF86AudioPrev: "Prev",
                XF86MonBrightnessUp: "Bright +",
                XF86MonBrightnessDown: "Bright −"
            })[part] ?? part;
    }

    // xkb keycode (evdev + 8) → the keysym a US layout gives it unshifted,
    // spelled the way loft-niri normalizes it.
    readonly property var keycodes: {
        const m = { 9: "Escape", 22: "BackSpace", 23: "Tab", 36: "Return", 65: "Space", 20: "Minus", 21: "Equal", 34: "Bracketleft", 35: "Bracketright", 47: "Semicolon", 48: "Apostrophe", 49: "Grave", 51: "Backslash", 59: "Comma", 60: "Period", 61: "Slash", 107: "Print", 110: "Home", 111: "Up", 112: "Page_Up", 113: "Left", 114: "Right", 115: "End", 116: "Down", 117: "Page_Down", 118: "Insert", 119: "Delete", 104: "KP_Enter", 121: "XF86AudioMute", 122: "XF86AudioLowerVolume", 123: "XF86AudioRaiseVolume", 171: "XF86AudioNext", 172: "XF86AudioPlay", 173: "XF86AudioPrev", 232: "XF86MonBrightnessDown", 233: "XF86MonBrightnessUp" };
        const rows = [[10, "1234567890"], [24, "QWERTYUIOP"], [38, "ASDFGHJKL"], [52, "ZXCVBNM"]];
        for (const [start, keys] of rows)
            for (let i = 0; i < keys.length; i++)
                m[start + i] = keys[i];
        for (let i = 0; i < 10; i++)
            m[67 + i] = `F${i + 1}`;
        m[95] = "F11";
        m[96] = "F12";
        for (let i = 0; i < 12; i++)
            m[191 + i] = `F${i + 13}`;
        return m;
    }

    // Modifier keys themselves (they only change `held`).
    function isModifierKey(event) {
        return [Qt.Key_Shift, Qt.Key_Control, Qt.Key_Alt, Qt.Key_Meta, Qt.Key_Super_L, Qt.Key_Super_R, Qt.Key_Hyper_L, Qt.Key_Hyper_R, Qt.Key_AltGr, Qt.Key_CapsLock, Qt.Key_Mode_switch].includes(event.key) || [50, 62, 37, 105, 64, 108, 133, 134, 66, 92].includes(event.nativeScanCode);
    }

    function isLevel3(event) {
        return event.key === Qt.Key_AltGr || event.nativeScanCode === 108 || event.nativeScanCode === 92;
    }

    function modsOf(event) {
        const out = [];
        const m = event.modifiers;
        if (modHeld || (m & Qt.GroupSwitchModifier))
            out.push("Mod");
        if (m & Qt.MetaModifier)
            out.push("Super");
        if (m & Qt.ControlModifier)
            out.push("Ctrl");
        if (m & Qt.AltModifier)
            out.push("Alt");
        if (m & Qt.ShiftModifier)
            out.push("Shift");
        return out;
    }

    function nameOf(event) {
        const byCode = keycodes[event.nativeScanCode];
        if (byCode)
            return byCode;
        if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z)
            return String.fromCharCode(event.key);
        if (event.key >= Qt.Key_0 && event.key <= Qt.Key_9)
            return String.fromCharCode(event.key);
        if (event.key >= Qt.Key_F1 && event.key <= Qt.Key_F35)
            return `F${event.key - Qt.Key_F1 + 1}`;
        return "";
    }

    // Function, media and navigation keys may stand alone; letters, digits
    // and punctuation need a modifier (or they'd stop typing).
    function needsModifier(name) {
        return name.length === 1 || ["Space", "Return", "Tab", "BackSpace", "Minus", "Equal", "Bracketleft", "Bracketright", "Semicolon", "Apostrophe", "Grave", "Backslash", "Comma", "Period", "Slash"].includes(name);
    }

    Keys.onPressed: event => {
        if (!recording)
            return;
        event.accepted = true;
        if (isLevel3(event))
            modHeld = true;
        if (isModifierKey(event)) {
            held = modsOf(event).concat(isLevel3(event) && !modsOf(event).includes("Mod") ? ["Mod"] : []);
            return;
        }
        const mods = modsOf(event);
        const name = nameOf(event);
        if (mods.length === 0 && name === "Escape") {
            rec.canceled();
            return;
        }
        if (mods.length === 0 && (name === "BackSpace" || name === "Delete")) {
            rec.cleared();
            return;
        }
        if (name === "") {
            hint = "That key has no name niri knows";
            return;
        }
        if (mods.length === 0 && needsModifier(name)) {
            hint = "Add a modifier (⌘ ⌃ ⌥ ⇧ or Mod)";
            return;
        }
        rec.captured(mods.concat([name]).join("+"));
    }
    Keys.onReleased: event => {
        if (!recording)
            return;
        event.accepted = true;
        if (isLevel3(event))
            modHeld = false;
        if (isModifierKey(event))
            held = modsOf(event).filter(m => m !== "Mod" || modHeld);
    }

    // Recording ends with a combination, Esc, a click on the field again,
    // or another field starting (not on focus loss: the page's "type it"
    // field takes the focus while recording).

    Row {
        id: caps
        anchors.centerIn: parent
        spacing: 3

        Repeater {
            model: rec.recording ? rec.held : rec.trigger !== "" ? rec.modifiers.concat([rec.trigger]) : []
            delegate: Rectangle {
                required property string modelData
                width: Math.max(22, capText.implicitWidth + 10)
                height: 22
                radius: 5
                color: Theme.withAlpha(Theme.text, 0.1)
                border.width: 1
                border.color: Theme.withAlpha(Theme.text, 0.12)

                Text {
                    id: capText
                    anchors.centerIn: parent
                    text: rec.keyCap(parent.modelData)
                    color: Theme.text
                    font.family: Theme.fontUi
                    font.pixelSize: 11
                    font.weight: Font.Medium
                }
            }
        }

        Text {
            visible: rec.recording || rec.trigger === ""
            anchors.verticalCenter: parent.verticalCenter
            text: rec.recording ? (rec.hint || (rec.held.length ? "…" : "Type shortcut")) : rec.placeholder
            color: rec.recording ? (rec.hint ? Theme.warn : Theme.accent) : Theme.subtext
            font.family: Theme.fontUi
            font.pixelSize: 11
            font.italic: !rec.recording
        }
    }

    MouseArea {
        id: hover
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: rec.recording ? rec.canceled() : rec.startRequested()
    }
}
