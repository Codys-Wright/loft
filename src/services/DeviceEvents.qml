pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Bluetooth

// Announces Bluetooth devices connecting/disconnecting as island banners
// (with battery level when the device reports it), like iOS/macOS.
Singleton {
    id: root

    Instantiator {
        model: Bluetooth.devices

        delegate: QtObject {
            required property BluetoothDevice modelData
            readonly property bool connected: modelData.connected
            // Skip the initial state; announce changes only.
            property bool seen: false

            Component.onCompleted: {
                seen = true;
                checkBattery();
            }

            // Low battery on headsets, mice, keyboards… (with the alerts
            // module): once at ≤ 15 %, again only after it went above 25 %.
            readonly property real battery: modelData.batteryAvailable ? modelData.battery : -1
            property bool warned: false
            onBatteryChanged: checkBattery()
            function checkBattery() {
                if (battery < 0)
                    return;
                if (battery > 0.25)
                    warned = false;
                if (warned || battery > 0.15 || !modelData.connected || !Features.on("alerts") || !Settings.system.alertBattery)
                    return;
                if (!/headset|headphone|mouse|keyboard|gaming|input|audio/.test(modelData.icon ?? ""))
                    return;
                warned = true;
                Notifications.show({
                    appName: "Bluetooth",
                    appIcon: modelData.icon || "battery-caution",
                    summary: `${modelData.name}: battery low`,
                    body: `${Math.round(battery * 100)}% left — charge it soon.`,
                    image: "",
                    actions: []
                });
            }
            onConnectedChanged: {
                if (!seen)
                    return;
                const battery = connected && modelData.batteryAvailable ? `  ·  ${Math.round(modelData.battery * 100)}%` : "";
                Notifications.show({
                    appName: "Bluetooth",
                    appIcon: modelData.icon || "bluetooth",
                    summary: modelData.name,
                    body: (connected ? "Connected" : "Disconnected") + battery,
                    image: "",
                    actions: []
                });
            }
        }
    }
}
