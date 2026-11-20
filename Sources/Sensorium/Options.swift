import SensoriumCore
import SwiftUI

struct TweakSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double?
    var format = "%.2f"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
            }
            // Snap to `step` without SwiftUI's tick marks (dozens of ticks look cluttered).
            Slider(value: Binding(get: { value }, set: { v in
                value = step.map { s in min(range.upperBound, max(range.lowerBound, (v / s).rounded() * s)) } ?? v
            }), in: range)
        }
    }
}

// MARK: - Settings window (⌘,): only app-wide things

struct SettingsView: View {
    @Environment(Tweaks.self) private var tweaks

    var body: some View {
        @Bindable var tweaks = tweaks
        Form {
            Section("Appearance") {
                Picker("Style", selection: $tweaks.v.theme) {
                    ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Light / dark (native style)", selection: $tweaks.v.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .disabled(tweaks.v.theme == .futuristic)
                Toggle("Show in the Dock", isOn: $tweaks.v.showDockIcon)
            }
            Section("Refresh") {
                TweakSlider(title: "Window refresh rate (fps)", value: $tweaks.v.fps, range: 10...120, step: 5, format: "%.0f")
                TweakSlider(title: "Desktop widget refresh rate (fps)", value: $tweaks.v.widgetFPS, range: 1...60, step: 1, format: "%.0f")
                TweakSlider(title: "Graph history (seconds)", value: $tweaks.v.historySeconds, range: 2...30, step: 1, format: "%.0f")
                TweakSlider(title: "Temperature & battery poll (seconds)", value: $tweaks.v.slowPollSeconds, range: 0.2...10, format: "%.1f")
                Toggle("Pause motion sensors when nothing is on screen (saves battery)", isOn: $tweaks.v.pauseWhenHidden)
            }
            Section("Units") {
                Toggle("Fahrenheit", isOn: $tweaks.v.fahrenheit)
                Picker("Acceleration", selection: $tweaks.v.accelUnits) {
                    ForEach(AccelUnits.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            Section {
                Button("Reset every setting", role: .destructive) { tweaks.reset() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 560)
        .preferredColorScheme(tweaks.v.theme == .futuristic ? .dark : tweaks.v.appearance.scheme)
    }
}

// MARK: - Per-page options (shown at the bottom of each page)

struct TrackpadOptions: View {
    @Environment(Tweaks.self) private var tweaks
    var body: some View {
        @Bindable var tweaks = tweaks
        Card("Options") {
            TweakSlider(title: "Pressure smoothing (1 = raw)", value: $tweaks.v.pressureSmoothing, range: 0.02...1)
            TweakSlider(title: "Pressure scale max", value: $tweaks.v.pressureMax, range: 200...4000, step: 50, format: "%.0f")
            TweakSlider(title: "Finger size", value: $tweaks.v.touchScale, range: 0.5...4, format: "%.1f")
            HStack(spacing: 20) {
                Toggle("Finger labels", isOn: $tweaks.v.showFingerLabels)
                Toggle("Velocity arrows", isOn: $tweaks.v.showVelocity)
                Toggle("Sensor grid", isOn: $tweaks.v.showSensorGrid)
                Toggle("Flip vertical", isOn: $tweaks.v.flipY)
            }
        }
    }
}

struct KeyboardOptions: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks
    var body: some View {
        @Bindable var tweaks = tweaks
        Card("Options") {
            Picker("Key colours", selection: $tweaks.v.keyColorMode) {
                ForEach(KeyColorMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            TweakSlider(title: "Rhythm window (seconds)", value: $tweaks.v.rhythmSeconds, range: 2...20, step: 1, format: "%.0f")
            TweakSlider(title: "Key glow after release (seconds)", value: $tweaks.v.keyFade, range: 0.05...3)
            Toggle("Silence the typing beep in this window", isOn: $tweaks.v.swallowKeys)
            Toggle("Listen system-wide (needs Input Monitoring)", isOn: $tweaks.v.globalKeys)
            HStack {
                Text(imText).font(.caption).foregroundStyle(.secondary)
                if hub.status.inputMonitoring != 0 {
                    Button("Ask macOS") { hub.requestInputMonitoring() }.controlSize(.small)
                }
            }
        }
    }
    private var imText: String {
        switch hub.status.inputMonitoring {
        case 0: return "Input Monitoring: granted."
        case 1: return "Input Monitoring: denied. Enable Sensorium in System Settings → Privacy & Security → Input Monitoring, then relaunch."
        default: return "Input Monitoring: not asked yet."
        }
    }
}

struct MotionOptions: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks
    var body: some View {
        @Bindable var tweaks = tweaks
        Card("Options") {
            TweakSlider(title: "Accelerometer range (g)", value: $tweaks.v.accelRange, range: 0.1...4, format: "%.1f")
            TweakSlider(title: "Tap threshold (mg)", value: $tweaks.v.tapThreshold, range: 2...500, step: 1, format: "%.0f")
            TweakSlider(title: "Vibration graph max (mg)", value: $tweaks.v.vibMax, range: 10...2000, step: 10, format: "%.0f")
            TweakSlider(title: "Gravity baseline smoothing", value: $tweaks.v.baselineSmoothing, range: 0.001...0.2, format: "%.3f")
            TweakSlider(title: "Gyroscope range", value: $tweaks.v.gyroRange, range: 1...500, step: 1, format: "%.0f")
            HStack {
                Toggle("Gyroscope graph", isOn: $tweaks.v.showGyro)
                Spacer()
                Button("Set level zero") {
                    if let a = hub.motion.latest {
                        tweaks.v.levelZeroX = atan2(a.x, (a.y * a.y + a.z * a.z).squareRoot()) * 180 / .pi
                        tweaks.v.levelZeroY = atan2(a.y, (a.x * a.x + a.z * a.z).squareRoot()) * 180 / .pi
                    }
                }
                Button("Clear zero") { tweaks.v.levelZeroX = 0; tweaks.v.levelZeroY = 0 }
            }
        }
    }
}

struct ThermalOptions: View {
    @Environment(Tweaks.self) private var tweaks
    var body: some View {
        @Bindable var tweaks = tweaks
        Card("Options") {
            HStack(spacing: 20) {
                Toggle("Fahrenheit", isOn: $tweaks.v.fahrenheit)
                Toggle("Show power rails", isOn: $tweaks.v.showPowerRails)
            }
            TweakSlider(title: "Poll every (seconds)", value: $tweaks.v.slowPollSeconds, range: 0.2...10, format: "%.1f")
        }
    }
}
