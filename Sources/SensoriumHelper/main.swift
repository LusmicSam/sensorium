// SensoriumHelper: the lightweight background service for trackpad gestures, brightness and volume.
// Started at login by a LaunchAgent; no Dock icon, no menus, no SwiftUI.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let service = GestureService()
service.start()
app.run()
