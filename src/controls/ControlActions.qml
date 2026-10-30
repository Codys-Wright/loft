pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Networking
import Quickshell.Services.UPower
import qs.capture
import qs.services

// What clicking a control does, for toggles and actions (panels open
// through MenuState in the bar and expand in place in the Control Center).
// Lives outside services/ because it reaches into capture/.
Singleton {
    id: root

    // (The bar closes its own menu before calling trigger.)
    function closePanels() {
        Panels.controlCenterOpen = false;
    }

    function trigger(id) {
        switch (id) {
        case "caffeine":
            KeepAwake.toggle();
            break;
        case "cleaning":
            closePanels();
            Cleaning.start();
            break;
        case "nightLight":
            NightLight.enabled = !NightLight.enabled;
            break;
        case "performanceMode":
            // Off → Performance → Ultra → Off.
            PerformanceMode.cycle();
            break;
        case "powerMode":
            {
                const order = [PowerProfile.PowerSaver, PowerProfile.Balanced, PowerProfile.Performance];
                let next = order[(order.indexOf(PowerProfiles.profile) + 1) % order.length];
                if (next === PowerProfile.Performance && !PowerProfiles.hasPerformanceProfile)
                    next = order[0];
                PowerProfiles.profile = next;
                break;
            }
        case "focusTimer":
            FocusTimer.active ? FocusTimer.stop() : FocusTimer.start();
            break;
        case "record":
            closePanels();
            Recorder.active ? Recorder.stop() : Recorder.start();
            break;
        case "micMute":
            Sound.setMicsMuted(!Sound.micsMuted);
            break;
        case "focus":
            Panels.doNotDisturb = !Panels.doNotDisturb;
            break;
        case "wifi":
            Networking.wifiEnabled = !Networking.wifiEnabled;
            break;
        case "bluetooth":
            if (Controls.btAdapter)
                Controls.btAdapter.enabled = !Controls.btAdapter.enabled;
            break;
        case "screenshot":
            closePanels();
            Capture.openSelector();
            break;
        case "lock":
            closePanels();
            LockState.requestLock();
            break;
        case "overview":
            closePanels();
            Niri.toggleOverview();
            break;
        case "displays":
            closePanels();
            Panels.settingsSection = "displays";
            Panels.settingsOpen = true;
            break;
        case "clipboard":
            closePanels();
            Clipboard.panelOpen = Clipboard.enabled && !Clipboard.panelOpen;
            break;
        case "colorPicker":
            closePanels();
            Capture.capture("color", "area", 0);
            break;
        case "spotlight":
            closePanels();
            Quickshell.execDetached(["loft-launcher", "open"]);
            break;
        }
    }
}
