import SensoriumCore
import AppKit
import SwiftUI

/// Icon (and optional live value) in the menu bar.
struct MenuBarLabel: View {
    @Environment(SensorHub.self) private var hub
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: hub.gesturesArmed ? "hand.draw.fill" : hub.noSleep ? "cup.and.saucer.fill" : "waveform.path.ecg")
            if !hub.menuTitle.isEmpty { Text(hub.menuTitle).monospacedDigit() }
        }
    }
}

/// The popover under the menu bar icon: No Sleep on top, tabs, then the chosen view.
struct MenuPanel: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var tweaks = tweaks
        let cfg = tweaks.v
        VStack(alignment: .leading, spacing: 10) {
            NoSleepBar()
            Picker("", selection: $tweaks.v.menuTab) {
                ForEach(MenuTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                switch cfg.menuTab {
                case .mine: grid(cfg.menuWidgets, columns: cfg.menuColumns)
                case .touch: grid([.trackpad, .pressure], columns: 1)
                case .motion: grid([.vibration, .accel, .level, .lid, .light], columns: 2)
                case .temps: TempsTab()
                case .power: grid([.battery, .temps], columns: 1)
                }
            }
            HStack {
                Button("Open Sensorium") { open(.trackpad) }
                Button("Customize…") { open(.menuBar) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: cfg.menuWidth)
        .background { if Neon.isOn { SpaceBackground() } }
        .modifier(ForceDark(on: Neon.isOn))
        .tint(Neon.accent)
        .preferredColorScheme(cfg.theme == .futuristic ? .dark : cfg.appearance.scheme)
    }

    @ViewBuilder private func grid(_ widgets: [MenuWidget], columns: Int) -> some View {
        if widgets.isEmpty {
            Text("No widgets in this tab yet. Press Customize… to add some.").font(.caption).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: max(1, columns)),
                      spacing: 8) {
                ForEach(widgets) { MenuWidgetView(kind: $0) }
            }
        }
    }

    private func open(_ page: Page) {
        UIState.shared.page = page
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct TempsTab: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks
    var body: some View {
        let f = tweaks.v.fahrenheit
        VStack(alignment: .leading, spacing: 6) {
            ForEach(hub.slow.groups) { g in
                HStack {
                    Text(g.name)
                    Text("\(g.readings.count)").foregroundStyle(.secondary).font(.caption)
                    Spacer()
                    Text(f ? fmt(g.avg * 9 / 5 + 32, 0, "°F avg") : fmt(g.avg, 1, "° avg")).foregroundStyle(.secondary).font(.caption.monospacedDigit())
                    Text(f ? fmt(g.max * 9 / 5 + 32, 0, "°F") : fmt(g.max, 1, "°C"))
                        .monospacedDigit().bold().foregroundStyle(heatColor((g.max - 25) / 60))
                        .frame(width: 64, alignment: .trailing)
                }
            }
            if let t = hub.motion.imuTemp {
                HStack { Text("Motion chip"); Spacer(); Text(fmt(t, 1, "°C")).monospacedDigit().bold().frame(width: 64, alignment: .trailing) }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .needs(.temps, .spu)
    }
}

struct NoSleepBar: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks

    var body: some View {
        HStack(spacing: 10) {
            Button {
                hub.setNoSleep(!hub.noSleep)
            } label: {
                Label(hub.noSleep ? "No Sleep: ON" : "No Sleep", systemImage: hub.noSleep ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(hub.noSleep ? .orange : .accentColor)
            .controlSize(.large)
            VStack(alignment: .leading, spacing: 1) {
                if hub.noSleep {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(caption(at: ctx.date)).font(.caption.monospacedDigit())
                    }
                    Text(hub.noSleepCommand).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                } else {
                    Text(planned).font(.caption).foregroundStyle(.secondary)
                }
                if let e = hub.noSleepError { Text(e).font(.caption2).foregroundStyle(.red) }
            }
            .frame(width: 190, alignment: .leading)
        }
    }

    private func caption(at date: Date) -> String {
        let on = Int(date.timeIntervalSince(hub.noSleepSince ?? date))
        var s = "awake for \(clock(on))"
        if let until = hub.noSleepUntil { s += " · \(clock(max(0, Int(until.timeIntervalSince(date))))) left" }
        return s
    }

    private var planned: String {
        let c = tweaks.v
        var parts: [String] = []
        if c.caffDisplay { parts.append("screen on") }
        if c.caffIdle || (!c.caffDisplay && !c.caffSystem) { parts.append("no idle sleep") }
        if c.caffSystem { parts.append("no sleep on AC") }
        return parts.joined(separator: ", ") + (c.caffMinutes > 0 ? " for \(Int(c.caffMinutes)) min" : ", until turned off")
    }
}

func clock(_ seconds: Int) -> String {
    seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                    : String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// One compact widget, used in the popover and (plain, on blur) as a desktop widget.
struct MenuWidgetView: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks
    var kind: MenuWidget
    var plain = false

    var body: some View {
        let cfg = tweaks.v, m = hub.motion
        let tn: Double = kind == .pressure || kind == .trackpad ? hub.touch.now : kind == .keys ? hub.keys.now : m.now
        let tMin = tn - cfg.historySeconds
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.rawValue.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            switch kind {
            case .battery:
                if let b = hub.slow.battery {
                    let w = Double(b.voltage_mV) * Double(b.amperage_mA) / 1e6
                    Text("\(b.percent)%  \(fmt(w, 1, " W"))").font(.title2.monospacedDigit()).bold()
                    Text("\(b.charging ? "charging" : b.external ? "plugged in" : "on battery") · \(fmt(b.temperature_C, 1, "°C")) · \(b.cycles) cycles")
                        .font(.caption2)
                } else { Text("—") }
            case .temps:
                ForEach(hub.slow.groups.prefix(4)) { g in
                    HStack {
                        Text(g.name).font(.caption)
                        Spacer()
                        Text(cfg.fahrenheit ? fmt(g.max * 9 / 5 + 32, 0, "°F") : fmt(g.max, 1, "°C"))
                            .font(.caption.monospacedDigit()).bold().foregroundStyle(heatColor((g.max - 25) / 60))
                    }
                }
            case .pressure:
                Text("\(Int(hub.touch.touches.map(\.pressure).max() ?? 0))").font(.title2.monospacedDigit()).bold()
                LineGraph(series: [Series(color: .orange, points: hub.touch.pressureHistory.graph)],
                          tMin: tMin, tMax: tn, vMin: 0, vMax: cfg.pressureMax).frame(height: 44)
            case .trackpad:
                TrackpadCanvas(touches: hub.touch.touches, cfg: cfg).aspectRatio(12480.0 / 7680.0, contentMode: .fit)
            case .vibration:
                HStack {
                    Circle().fill(m.now - m.lastTap < 0.3 ? Color.orange : Color.secondary.opacity(0.3)).frame(width: 9, height: 9)
                    Text("taps \(m.taps) · \(Int(m.vibNow)) mg").font(.caption.monospacedDigit())
                }
                LineGraph(series: [Series(color: .orange, points: m.vib.graph)], tMin: tMin, tMax: tn,
                          vMin: 0, vMax: cfg.vibMax, guides: [Guide(value: cfg.tapThreshold, color: .red)]).frame(height: 40)
            case .accel:
                LineGraph(series: [
                    Series(color: Neon.x, points: m.accel.map { GPoint(t: $0.t, v: $0.x) }),
                    Series(color: Neon.y, points: m.accel.map { GPoint(t: $0.t, v: $0.y) }),
                    Series(color: Neon.z, points: m.accel.map { GPoint(t: $0.t, v: $0.z) }),
                ], tMin: tMin, tMax: tn, vMin: -cfg.accelRange, vMax: cfg.accelRange).frame(height: 50)
            case .gyro:
                LineGraph(series: [
                    Series(color: Neon.x, points: m.gyro.map { GPoint(t: $0.t, v: $0.x) }),
                    Series(color: Neon.y, points: m.gyro.map { GPoint(t: $0.t, v: $0.y) }),
                    Series(color: Neon.z, points: m.gyro.map { GPoint(t: $0.t, v: $0.z) }),
                ], tMin: tMin, tMax: tn, vMin: -cfg.gyroRange, vMax: cfg.gyroRange).frame(height: 50)
            case .level:
                LevelView(accel: m.latest, zeroX: cfg.levelZeroX, zeroY: cfg.levelZeroY).frame(height: 80)
            case .lid:
                LidGauge(angle: m.lid).frame(height: 70)
            case .light:
                Text(fmt(m.light.lux, 1, " lux")).font(.title2.monospacedDigit()).bold()
                Text("colour \(fmt(m.light.cct, 0, " K"))").font(.caption2.monospacedDigit())
            case .keys:
                RhythmCanvas(strokes: hub.keys.strokes, now: hub.keys.now, window: cfg.rhythmSeconds).frame(height: 50)
                Text("\(Int(hub.keys.wpm)) wpm · hold \(fmt(hub.keys.meanHold.map { $0 * 1000 }, 0, " ms"))").font(.caption2)
            case .haptic:
                HStack {
                    ForEach([3, 4, 6], id: \.self) { id in Button("Tap \(id)") { hub.fireHaptic(id: id) } }
                }
                .controlSize(.small)
            case .touchID:
                Text(hub.biometryReady ? "ready" : "unavailable").font(.caption)
                Button(hub.authRunning ? "waiting…" : "Test fingerprint") { hub.testTouchID() }
                    .controlSize(.small).disabled(!hub.biometryReady || hub.authRunning)
                if let a = hub.authAttempts.first {
                    Text(a.ok ? "✓ matched" : "✗ \(a.message)").font(.caption2)
                }
            }
        }
        .padding(plain ? 0 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(plain ? nil : RoundedRectangle(cornerRadius: 10).fill(Neon.isOn ? Neon.glass : Color.primary.opacity(0.06)))
        .overlay(plain || !Neon.isOn ? nil : RoundedRectangle(cornerRadius: 10).strokeBorder(Neon.cyan.opacity(0.18)))
        .modifier(NeedsModifier(needs: kind.needs))
    }
}

// MARK: - App pages: No Sleep and Menu Bar

struct NoSleepPage: View {
    @Environment(Tweaks.self) private var tweaks
    var body: some View {
        @Bindable var tweaks = tweaks
        VStack(spacing: 14) {
            Card("No Sleep", subtitle: "keeps your Mac awake using macOS's own caffeinate tool") {
                NoSleepBar()
                Toggle("Coffee cup in the menu bar: one click turns No Sleep on / off", isOn: $tweaks.v.coffeeInMenuBar)
                Text("It stops automatically if Sensorium quits, so your Mac can't get stuck awake.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card("Options", subtitle: "applied the next time you turn it on") {
                Toggle("Keep the screen on (-d)", isOn: $tweaks.v.caffDisplay)
                Toggle("Stop idle sleep (-i)", isOn: $tweaks.v.caffIdle)
                Toggle("Stop system sleep, on power adapter only (-s)", isOn: $tweaks.v.caffSystem)
                TweakSlider(title: "Timer in minutes (0 = until turned off)", value: $tweaks.v.caffMinutes, range: 0...480, step: 5, format: "%.0f")
            }
        }
    }
}

struct MenuBarPage: View {
    @Environment(Tweaks.self) private var tweaks
    var body: some View {
        @Bindable var tweaks = tweaks
        let chosen = tweaks.v.menuWidgets
        VStack(spacing: 14) {
            Card("Menu bar", subtitle: "the icon right of the camera notch; ⌘-drag it to move it along the bar") {
                Picker("Next to the icon", selection: $tweaks.v.menuBarText) {
                    ForEach(MenuBarText.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Tab when opened", selection: $tweaks.v.menuTab) {
                    ForEach(MenuTab.allCases) { Text($0.rawValue).tag($0) }
                }
                TweakSlider(title: "Popover width", value: $tweaks.v.menuWidth, range: 300...800, step: 10, format: "%.0f")
            }
            Card("“Mine” tab", subtitle: "tick to show, arrows to reorder") {
                Stepper("Columns: \(tweaks.v.menuColumns)", value: $tweaks.v.menuColumns, in: 1...3)
                ForEach(chosen + MenuWidget.allCases.filter { !chosen.contains($0) }) { w in
                    HStack {
                        Toggle(w.rawValue, isOn: Binding(
                            get: { tweaks.v.menuWidgets.contains(w) },
                            set: { on in
                                if on { tweaks.v.menuWidgets.append(w) } else { tweaks.v.menuWidgets.removeAll { $0 == w } }
                            }))
                        Spacer()
                        if let i = chosen.firstIndex(of: w) {
                            Button { move(i, -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                            Button { move(i, 1) } label: { Image(systemName: "chevron.down") }.disabled(i == chosen.count - 1)
                        }
                    }
                }
            }
        }
    }

    private func move(_ i: Int, _ d: Int) {
        var list = tweaks.v.menuWidgets
        guard list.indices.contains(i), list.indices.contains(i + d) else { return }
        list.swapAt(i, i + d)
        tweaks.v.menuWidgets = list
    }
}

extension MenuWidget {
    var needs: [Need] {
        switch self {
        case .accel, .gyro, .vibration: return [.motion]
        case .level, .lid, .light: return [.spu]
        case .keys: return [.keys]
        case .temps: return [.temps]
        case .battery: return [.battery]
        case .pressure, .trackpad: return [.touch]
        default: return []
        }
    }
}
