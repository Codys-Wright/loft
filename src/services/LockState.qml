pragma Singleton

import QtQuick
import Quickshell

// Whether the session is locked, for modules that react to locking
// (clipboard auto-clear, …). Set by lock/Lock.qml; read-only for everyone else.
Singleton {
    property bool locked: false
}
