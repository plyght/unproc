import AppIntents
import SwiftUI
import WidgetKit

@main
struct UnprocWidgetsBundle: WidgetBundle {
    var body: some Widget {
        UnprocCameraControl()
    }
}

/// Control Centre / Lock Screen / Action Button control that launches the
/// camera. Because it runs a `CameraCaptureIntent`, the system opens the
/// lock-screen capture extension while locked and the app when unlocked.
struct UnprocCameraControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "lol.peril.unproc.camera") {
            ControlWidgetButton(action: UnprocCaptureIntent()) {
                Label("unproc", systemImage: "camera.aperture")
            }
        }
        .displayName("unproc")
        .description("Open the unproc camera.")
    }
}
