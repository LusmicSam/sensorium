import SensoriumCore
import AppKit
import CSensors
import SwiftUI

// MARK: - Thermals & power

struct ThermalsView: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks

    var body: some View {
        let s = hub.slow, cfg = tweaks.v
        VStack(spacing: 14) {
            Card("Temperatures", subtitle: "\(s.groups.reduce(0) { $0 + $1.readings.count }) sensors, every \(fmt(cfg.slowPollSeconds, 1)) s") {
                ForEach(s.groups) { g in
                    DisclosureGroup {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 2) {
                            ForEach(g.readings) { r in
                                GridRow { Text(r.name); Text(temp(r.value, cfg)).monospacedDigit() }
                            }
                        }
                        .font(.caption)
                    } label: {
                        HStack {
                            Text(g.name).frame(width: 130, alignment: .leading)
                            Text("\(g.readings.count)").foregroundStyle(.secondary).frame(width: 30)
                            Text("min \(temp(g.min, cfg))  avg \(temp(g.avg, cfg))  max \(temp(g.max, cfg))")
                                .monospacedDigit().frame(width: 300, alignment: .leading)
                            LineGraph(series: [Series(color: heatColor((g.max - 25) / 60), points: g.history.graph)],
                                      tMin: s.t - max(60, cfg.historySeconds * 10), tMax: s.t, vMin: 20, vMax: 100)
                                .frame(height: 22)
                        }
                        .font(.callout)
                    }
                }
            }
            ThermalOptions()
        }
        .needs(.temps)
    }

    private func temp(_ c: Double, _ cfg: TweakValues) -> String {
        cfg.fahrenheit ? fmt(c * 9 / 5 + 32, 1, "°F") : fmt(c, 1, "°C")
    }
}

struct BatteryCard: View {
    var battery: SNBattery?
    var fahrenheit: Bool
    var body: some View {
        Card("Battery") {
            if let b = battery {
                let watts = Double(b.voltage_mV) / 1000 * Double(b.amperage_mA) / 1000
                HStack(spacing: 22) {
                    Stat(label: "charge", value: "\(b.percent)%")
                    Stat(label: "state", value: b.charging ? "charging" : b.external ? "plugged, not charging" : "on battery")
                    Stat(label: "voltage", value: fmt(Double(b.voltage_mV) / 1000, 2, " V"))
                    Stat(label: "current", value: fmt(Double(b.amperage_mA) / 1000, 2, " A"))
                    Stat(label: "power", value: fmt(watts, 1, " W"))
                    Stat(label: "temp", value: fahrenheit ? fmt(b.temperature_C * 9 / 5 + 32, 1, "°F") : fmt(b.temperature_C, 1, "°C"))
                    Stat(label: "cycles", value: "\(b.cycles)")
                    Stat(label: "health", value: b.design_mAh > 0 ? fmt(Double(b.rawMax_mAh) / Double(b.design_mAh) * 100, 0, "%") : "—")
                    Stat(label: "capacity", value: "\(b.rawCurrent_mAh) / \(b.rawMax_mAh) mAh")
                }
            } else {
                Text("No battery data").foregroundStyle(.secondary)
            }
        }
    }
}

struct RailList: View {
    var title: String
    var readings: [Reading]
    var body: some View {
        Card(title, subtitle: "raw units (likely mA / mV, unconfirmed)") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 1) {
                ForEach(readings) { r in GridRow { Text(r.name); Text(fmt(r.value, 1)).monospacedDigit() } }
            }
            .font(.caption)
        }
    }
}

struct BatteryPage: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks
    var body: some View {
        let s = hub.slow
        VStack(spacing: 14) {
            BatteryCard(battery: s.battery, fahrenheit: tweaks.v.fahrenheit)
            if tweaks.v.showPowerRails {
                HStack(alignment: .top, spacing: 14) {
                    RailList(title: "Rail currents", readings: s.currents)
                    RailList(title: "Rail voltages", readings: s.voltages)
                }
            } else {
                Card("Power rails") {
                    Text("\(s.currents.count) current and \(s.voltages.count) voltage sensors on the chip's power rails (raw units).")
                        .foregroundStyle(.secondary)
                    Toggle("Show them", isOn: Binding(get: { tweaks.v.showPowerRails }, set: { tweaks.v.showPowerRails = $0 }))
                }
            }
        }
        .needs(.battery)
    }
}

// MARK: - Haptics

struct HapticsView: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks

    var body: some View {
        @Bindable var hub = hub
        @Bindable var tweaks = tweaks
        VStack(spacing: 14) {
            Card("Trackpad haptic motor", subtitle: "private MultitouchSupport actuator: works without touching the pad") {
                Text("The trackpad glass never physically clicks. A small motor (Apple's Taptic Engine) fakes the feel. Actuation IDs are undocumented; try them and feel the difference.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach([1, 2, 3, 4, 5, 6, 15, 16], id: \.self) { id in
                        Button("ID \(id)") { hub.fireHaptic(id: id) }
                    }
                }
                HStack(spacing: 16) {
                    Stepper("Actuation ID: \(tweaks.v.hapticID)", value: $tweaks.v.hapticID, in: 0...64)
                    Button("Fire") { hub.fireHaptic() }.keyboardShortcut(.space, modifiers: [.command])
                    Text("last result: \(hub.lastHapticResult.map { String(format: "0x%X", UInt32(bitPattern: $0)) } ?? "—")")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                TweakSlider(title: "Unknown float argument 1", value: $tweaks.v.hapticArg1, range: 0...10, format: "%.1f")
                TweakSlider(title: "Unknown float argument 2", value: $tweaks.v.hapticArg2, range: 0...10, format: "%.1f")
            }
            Card("Public haptics (NSHapticFeedbackManager)", subtitle: "only felt while a finger is on the trackpad") {
                HStack {
                    Button("generic") { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
                    Button("alignment") { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                    Button("level change") { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
                }
            }
            Card("Pressure trigger (your own click)", subtitle: "fires the motor when pressure crosses a threshold") {
                Toggle("Fire haptic when pressure crosses the threshold", isOn: $tweaks.v.hapticOnPressure)
                TweakSlider(title: "Threshold (raw pressure)", value: $tweaks.v.hapticThreshold, range: 50...3000, step: 10, format: "%.0f")
                TweakSlider(title: "Re-arm below (fraction of threshold)", value: $tweaks.v.hapticRearm, range: 0.1...0.95, format: "%.2f")
                GeometryReader { g in
                    let p = hub.touch.touches.map(\.pressure).max() ?? 0
                    let f = min(1, p / max(1, tweaks.v.pressureMax))
                    let th = min(1, tweaks.v.hapticThreshold / max(1, tweaks.v.pressureMax))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.gray.opacity(0.2))
                        Capsule().fill(heatColor(f)).frame(width: g.size.width * CGFloat(f))
                        Rectangle().fill(Color.red).frame(width: 2).offset(x: g.size.width * CGFloat(th))
                    }
                }
                .frame(height: 12)
                Text("fired \(hub.touch.hapticFires) times").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .needs(.touch)
            Card("Haptic metronome") {
                Toggle("Tick the trackpad motor", isOn: $hub.metronomeOn)
                TweakSlider(title: "Beats per minute", value: $hub.metronomeBPM, range: 30...300, step: 1, format: "%.0f")
            }
        }
    }
}

// MARK: - Touch ID

struct TouchIDView: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        VStack(spacing: 14) {
            Card("Touch ID", subtitle: hub.biometry) {
                Text("""
                What a normal app can get from the fingerprint sensor: whether Touch ID exists and has a finger enrolled, \
                and a yes/no answer when you authenticate. The fingerprint image and templates never leave the Secure \
                Enclave chip, so no app (not even with sudo) can read or map the print itself. That's by design.
                """)
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(hub.authRunning ? "Waiting for finger…" : "Test fingerprint") { hub.testTouchID() }
                        .disabled(!hub.biometryReady || hub.authRunning)
                    Button("Re-check") { hub.checkBiometry() }
                }
                ForEach(hub.authAttempts) { a in
                    HStack {
                        Image(systemName: a.ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(a.ok ? .green : .red)
                        Text(a.at.formatted(date: .omitted, time: .standard)).monospacedDigit()
                        Text(fmt(a.seconds, 2, " s")).monospacedDigit().foregroundStyle(.secondary)
                        Text(a.message)
                    }
                    .font(.caption)
                }
            }
            Card("Touch ID chip events", subtitle: "\(hub.status.eventServices) services watched: Touch ID sensor (Mesa) + buttons") {
                Text("Raw events from the sensor's system service. Whether resting a finger produces any events is still being tested.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("events seen: \(hub.eventCount)").font(.callout.monospacedDigit())
                ForEach(hub.events.suffix(15).reversed()) { e in
                    HStack(alignment: .top) {
                        Text(String(format: "%.2f s ago", hub.now - e.t)).frame(width: 80, alignment: .leading)
                        Text(e.service).frame(width: 200, alignment: .leading)
                        Text("type \(e.type)").frame(width: 60, alignment: .leading)
                        Text(e.bytes.prefix(40).map { String(format: "%02x", $0) }.joined()).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.caption.monospaced())
                }
            }
        }
    }
}

// MARK: - Raw sensors

struct RawView: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        VStack(spacing: 14) {
            SensorMapCard()
            Card("cma · motion-coprocessor records", subtitle: "\(hub.cmaCount) received; first byte = record type") {
                Text("Record 0x1d holds 6 small floats + the motion chip's temperature (looks like a calibration record). 0x02 carries a counter, 0x03 a state value (1/2/4). Their exact meaning is not public.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(hub.cma.suffix(8).reversed()) { r in
                    HStack(alignment: .top) {
                        Text(String(format: "type 0x%02x", r.type)).frame(width: 70, alignment: .leading)
                        Text("\(r.bytes.count) B").frame(width: 44, alignment: .leading).foregroundStyle(.secondary)
                        Text(cmaDecode(r.bytes)).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.caption.monospaced())
                }
            }
            Card("Sensor processor streams", subtitle: "every byte live; orange = changed in the last 0.5 s") {
                ForEach(hub.raw) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(SPU.name(s.page, s.usage)).bold()
                            Text(String(format: "0x%04X/0x%02X", s.page, s.usage)).foregroundStyle(.secondary)
                            Text("\(fmt(s.hz, 1)) Hz · \(s.bytes.count) bytes · \(s.count) reports").foregroundStyle(.secondary)
                            Spacer()
                        }
                        .font(.callout)
                        HexRow(bytes: s.bytes, hot: s.hot)
                        let fields = SPU.fields(s.page, s.usage, s.bytes)
                        if !fields.isEmpty {
                            HStack(spacing: 16) {
                                ForEach(Array(fields.enumerated()), id: \.offset) { _, f in
                                    Text("\(f.0): ").foregroundStyle(.secondary) + Text(f.1).monospacedDigit()
                                }
                            }
                            .font(.caption)
                        }
                        Divider()
                    }
                }
                if hub.raw.isEmpty { Text("No sensor-processor reports yet.").foregroundStyle(.secondary) }
            }
        }
        .needs(.raw)
    }

    private func cmaDecode(_ b: [UInt8]) -> String {
        if b.first == 0x1d, b.count >= 32 {
            let f = stride(from: 4, through: 28, by: 4).map { String(format: "%.4g", Bytes.f32(b, $0)) }
            return "floats " + f.joined(separator: " ")
        }
        return b.prefix(40).map { String(format: "%02x", $0) }.joined()
    }
}

/// Everything the always-on sensor processor (AOP) hosts on this Mac, from the I/O registry.
struct SensorMapCard: View {
    @Environment(SensorHub.self) private var hub
    private let rows: [(String, String, String, String)] = [
        ("accel", "0xFF00/03", "Accelerometer: x/y/z in g + its chip's temperature", "decoded, verified (gravity = 1.00 g)"),
        ("gyro", "0xFF00/09", "Gyroscope: x/y/z in °/s + same chip temperature", "decoded; °/s from at-rest bias + devmotion6 match"),
        ("devmotion6", "0xFF0C/05", "Fused orientation (quaternion), rotation rate, motion without gravity", "decoded; quaternion verified (length 1.0000, gravity within 0.24°)"),
        ("las", "0x0020/8A", "Lid angle sensor (hinge), degrees", "decoded"),
        ("als", "0xFF00/04", "Ambient light VD6286: lux, colour temperature, XYZ, 5 raw channels", "decoded, verified against macOS's own values"),
        ("als-temp", "0xFF00/05", "Temperature of the light sensor", "decoded (Apple's temperature usage code)"),
        ("cma", "0xFF0C/01", "Motion-coprocessor records (4 types)", "partly: one type is a calibration-like record"),
        ("wakehint", "0xFF00/FF", "Sleep/wake hint, 1-byte events", "never fired since boot; only around sleep/wake"),
        ("aop-voicetrigger", "app", "\"Hey Siri\" listener running on the always-on chip", "not readable by apps"),
        ("aop-audio", "app", "Always-on microphone path (low-power mic input)", "not readable as a sensor"),
    ]
    var body: some View {
        Card("Sensor map", subtitle: "the always-on processor's endpoints on this Mac") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow { Text("name").bold(); Text("usage").bold(); Text("what it is").bold(); Text("status").bold() }
                ForEach(rows, id: \.0) { r in
                    GridRow {
                        Text(r.0).monospaced()
                        Text(r.1).monospaced().foregroundStyle(.secondary)
                        Text(r.2)
                        Text(r.3).foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
            Text("Also on the Mac: the Touch ID sensor (\"mesa\") wired straight to the Secure Enclave; 3 display temperature sensors not exposed to apps.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private let hexTable: [String] = (0..<256).map { String(format: "%02x ", $0) }

struct HexRow: View {
    var bytes: [UInt8]
    var hot: [Bool]
    var body: some View {
        let cols = 32
        VStack(alignment: .leading, spacing: 1) {
            ForEach(0..<((bytes.count + cols - 1) / cols), id: \.self) { row in
                Text(line(row * cols, min(bytes.count, (row + 1) * cols)))   // one Text per row, not one per byte
            }
        }
        .font(.system(size: 11, design: .monospaced))
    }

    private func line(_ a: Int, _ b: Int) -> AttributedString {
        var out = AttributedString(String(format: "%03d  ", a))
        out.foregroundColor = .secondary
        for i in a..<b {
            var part = AttributedString(hexTable[Int(bytes[i])])
            part.foregroundColor = i < hot.count && hot[i] ? .orange : (bytes[i] == 0 ? Color.secondary.opacity(0.5) : .primary)
            out += part
        }
        return out
    }
}
