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

            Component.onCompleted: seen = true
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
