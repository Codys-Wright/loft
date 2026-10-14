import QtQuick
import QtMultimedia

// The live camera picture (QtMultimedia). Loaded through a Loader by
// CameraMirror so a Qt without the QtMultimedia QML module only costs the
// preview, not the shell. Publishes its state to Capture.camera*.
Item {
    id: root

    property bool mirrored: true
    // A device description; "" = the system default.
    property string device: ""

    readonly property var inputs: devices.videoInputs
    readonly property bool hasCamera: inputs.length > 0
    readonly property var chosen: inputs.find(d => d.description === root.device) ?? devices.defaultVideoInput

    readonly property string state: !hasCamera ? "none" : camera.error !== Camera.NoError ? "error" : camera.active ? "live" : "starting"
    readonly property string deviceName: hasCamera ? chosen.description : ""
    readonly property string errorString: camera.errorString
    readonly property var deviceNames: inputs.map(d => d.description)

    MediaDevices {
        id: devices
    }

    CaptureSession {
        camera: Camera {
            id: camera
            cameraDevice: root.chosen
            active: root.hasCamera
        }
        videoOutput: output
    }

    VideoOutput {
        id: output
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        transform: Scale {
            origin.x: output.width / 2
            xScale: root.mirrored ? -1 : 1
        }
    }
}
