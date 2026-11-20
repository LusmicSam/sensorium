import SensoriumCore
import Foundation
import Observation

enum KeyColorMode: String, Codable, CaseIterable, Identifiable {
    case live = "Live", heat = "Heat (press count)", hold = "Hold time"
    var id: String { rawValue }
}

enum AccelUnits: String, Codable, CaseIterable, Identifiable {
    case g = "g", ms2 = "m/s²"
    var id: String { rawValue }
}

enum MenuWidget: String, Codable, CaseIterable, Identifiable {
    case battery = "Battery", temps = "Temperatures", pressure = "Pressure graph", trackpad = "Trackpad",
         vibration = "Vibration & taps", accel = "Accelerometer", gyro = "Gyroscope", level = "Bubble level",
         lid = "Lid angle", light = "Ambient light", keys = "Typing rhythm", haptic = "Haptic buttons",
         touchID = "Touch ID"
    var id: String { rawValue }
}

enum MenuBarText: String, Codable, CaseIterable, Identifiable {
    case none = "Icon only", chipTemp = "Hottest chip °", batteryPercent = "Battery %",
         batteryWatts = "Battery watts", lid = "Lid angle", pressure = "Trackpad pressure"
    var id: String { rawValue }
}

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system = "Match system", light = "Light", dark = "Dark"
    var id: String { rawValue }
}

enum MenuTab: String, Codable, CaseIterable, Identifiable {
    case mine = "Mine", touch = "Touch", motion = "Motion", temps = "Temps", power = "Power"
    var id: String { rawValue }
}

enum WidgetLevel: String, Codable, CaseIterable, Identifiable {
    case desktop = "On the desktop (behind windows)", floating = "Always on top"
    var id: String { rawValue }
}

/// One desktop widget: what it shows and where it sits (screen coordinates, bottom-left origin).
struct DesktopWidgetConfig: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: MenuWidget
    var x: Double
    var y: Double
    var width: Double = 250
}

/// Every knob in the app. Saved to UserDefaults as one JSON blob.
struct TweakValues: Codable, Equatable {
    // Display
    var fps: Double = 30
    var historySeconds: Double = 6
    var appearance: AppearanceMode = .system
    // Trackpad
    var pressureSmoothing: Double = 0.35   // EMA weight of the newest sample (1 = raw)
    var pressureMax: Double = 2000
    var touchScale: Double = 1.5
    var flipY = false
    var showFingerLabels = true
    var showVelocity = false
    var showSensorGrid = true
    // Haptics
    var hapticOnPressure = false
    var hapticThreshold: Double = 800
    var hapticRearm: Double = 0.6          // re-arm below threshold x this
    var hapticID = 6
    var hapticArg1: Double = 0
    var hapticArg2: Double = 0
    // Motion
    var accelUnits: AccelUnits = .g
    var accelRange: Double = 1.2
    var tapThreshold: Double = 40          // mg
    var vibMax: Double = 200               // mg, graph range
    var baselineSmoothing: Double = 0.02
    var showGyro = true
    var gyroRange: Double = 30
    var levelZeroX: Double = 0
    var levelZeroY: Double = 0
    // Keyboard
    var globalKeys = false
    var swallowKeys = true
    var keyColorMode: KeyColorMode = .live
    var rhythmSeconds: Double = 5
    var keyFade: Double = 0.6
    // Sensors
    var slowPollSeconds: Double = 1
    var fahrenheit = false
    var showPowerRails = false
    // Menu bar popover
    var menuWidgets: [MenuWidget] = [.battery, .temps, .pressure, .vibration, .lid, .light]
    var menuColumns = 2
    var menuWidth: Double = 420
    var menuBarText: MenuBarText = .chipTemp
    var menuTab: MenuTab = .mine
    // Desktop widgets
    var desktopWidgets: [DesktopWidgetConfig] = []
    var widgetsShown = true
    var widgetLevel: WidgetLevel = .desktop
    var widgetOpacity: Double = 1
    var widgetsLocked = false
    var widgetsClickThrough = false
    var widgetFPS: Double = 15
    var showDockIcon = true
    var pauseWhenHidden = true
    // No Sleep (caffeinate)
    var caffDisplay = true      // -d keep the display on
    var caffIdle = true         // -i stop idle sleep
    var caffSystem = false      // -s stop system sleep (only on AC power)
    var caffMinutes: Double = 0 // 0 = until turned off
    var coffeeInMenuBar = false  // separate one-click coffee cup that toggles No Sleep
    // Trackpad gestures, regions and tasks
    var gestures = GestureConfig()
    // Look
    var theme: AppTheme = .futuristic
}

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case futuristic = "Futuristic", native = "Native macOS"
    var id: String { rawValue }
}

@Observable final class Tweaks {
    static let shared = Tweaks()
    static var persist = true   // the snapshot debug run turns this off
    private static let storeKey = "sensorium.tweaks.v1"

    var v: TweakValues {
        didSet { if v != oldValue { save() } }
    }

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.storeKey), var saved = Self.decodeTolerant(d) {
            // One-time: the old 60 fps default becomes the lighter 30 fps (saved right away;
            // didSet doesn't run inside init, which is why the first version of this didn't stick).
            var migrated = false
            if !UserDefaults.standard.bool(forKey: "sensorium.migrated.fps30b") {
                if saved.fps == 60 { saved.fps = 30; migrated = true }
                UserDefaults.standard.set(true, forKey: "sensorium.migrated.fps30b")
            }
            v = saved
            if migrated { save() }
        } else {
            v = TweakValues()
        }
    }

    private var postedGestures: GestureConfig?

    private func save() {
        guard Self.persist else { return }
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: Self.storeKey) }
        if postedGestures != v.gestures {   // the background helper reloads on this
            postedGestures = v.gestures
            SharedConfig.post(SharedConfig.changed)
        }
    }

    func reset() { v = TweakValues() }

    /// Saved values laid over today's defaults, so adding a new tweak never wipes the old ones.
    private static func decodeTolerant(_ data: Data) -> TweakValues? {
        guard let defaults = try? JSONEncoder().encode(TweakValues()),
              var base = (try? JSONSerialization.jsonObject(with: defaults)) as? [String: Any],
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        base.merge(saved) { _, new in new }
        guard let merged = try? JSONSerialization.data(withJSONObject: base) else { return nil }
        return try? JSONDecoder().decode(TweakValues.self, from: merged)
    }
}
