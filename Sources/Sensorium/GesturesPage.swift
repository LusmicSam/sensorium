import SensoriumCore
import AppKit
import SwiftUI

struct DividerRef: Equatable { var vertical: Bool; var index: Int }

struct GesturesPage: View {
    var body: some View {
        VStack(spacing: 14) {
            ServiceCard()
            ArmCard()
            RegionCard()
            SlidersCard()
            BindingsCard()
            LettersCard()
            GestureActivityCard()
            TuningCard()
        }
        .needs(.touch)
    }
}

// MARK: - Background service

struct ServiceCard: View {
    @Environment(SensorHub.self) private var hub
    @Bindable private var ui = UIState.shared

    var body: some View {
        Card("Background service", subtitle: "gestures, brightness and volume keep working with this app closed") {
            HStack(spacing: 16) {
                Circle().fill(hub.serviceRunning ? Neon.lime : Color.secondary.opacity(0.4)).frame(width: 12, height: 12)
                    .shadow(color: hub.serviceRunning ? Neon.lime.opacity(0.7) : .clear, radius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hub.serviceRunning ? "SensoriumHelper is running" : "Not running: gestures only work while this app is open")
                        .font(.callout.weight(.semibold))
                    if let st = hub.serviceStats, hub.serviceRunning {
                        Text(String(format: "CPU %.2f%% of one core · memory %.1f MB · starts at login", st.cpu, st.mb))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if !ui.serviceMessage.isEmpty { Text(ui.serviceMessage).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                if ServiceManager.installed || hub.serviceRunning {
                    Button("Stop & remove") { ui.serviceMessage = ServiceManager.uninstall(); hub.pollSlow() }
                }
                Button(hub.serviceRunning ? "Restart" : "Run in background") {
                    ui.serviceMessage = ServiceManager.install()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { hub.pollSlow() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Neon.cyan)
            }
        }
        .needs(.service)
    }
}

// MARK: - Arming

struct ArmCard: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks
    var body: some View {
        @Bindable var tweaks = tweaks
        let g = tweaks.v.gestures
        Card("Gestures", subtitle: "runs in the background at ~0.003% CPU while you touch") {
            HStack(alignment: .center, spacing: 18) {
                ZStack {
                    Circle().fill(hub.gesturesArmed || g.armMode == .always ? Neon.cyan.opacity(0.18) : Color.white.opacity(0.05))
                    Image(systemName: hub.gesturesArmed || g.armMode == .always ? "hand.draw.fill" : "hand.raised.slash")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(hub.gesturesArmed || g.armMode == .always ? Neon.cyan : .secondary)
                }
                .frame(width: 64, height: 64)
                .shadow(color: hub.gesturesArmed ? Neon.cyan.opacity(0.5) : .clear, radius: 14)
                VStack(alignment: .leading, spacing: 4) {
                    Text(!g.enabled ? "Gestures off" : g.armMode == .always ? "Always listening" : hub.gesturesArmed ? "ARMED" : "Waiting to be armed")
                        .font(.system(.title3, design: .rounded).bold())
                    Text(g.armMode == .armed
                         ? "Hold the \(g.armCorner.rawValue.lowercased()) corner of the trackpad for \(fmt(g.armHoldSeconds, 1)) s to arm or disarm. Disarms after \(Int(g.armTimeout)) s idle. The menu bar icon turns into a hand while armed."
                         : "Every recorded gesture is live all the time.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if g.armMode == .armed {
                    Button(hub.gesturesArmed ? "Disarm" : "Arm now") { hub.setGesturesArmed(!hub.gesturesArmed) }
                }
            }
            Toggle("Trackpad gestures on", isOn: $tweaks.v.gestures.enabled)
            Picker("Activation", selection: $tweaks.v.gestures.armMode) {
                ForEach(ArmMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if g.armMode == .armed {
                Picker("Arm corner", selection: $tweaks.v.gestures.armCorner) {
                    ForEach(PadCorner.allCases) { Text($0.rawValue).tag($0) }
                }
                TweakSlider(title: "Disarm after idle (seconds)", value: $tweaks.v.gestures.armTimeout, range: 3...60, step: 1, format: "%.0f")
                Toggle("Brightness / volume slides work without arming", isOn: $tweaks.v.gestures.slidersAlwaysOn)
            }
            HStack(spacing: 20) {
                Toggle("On-screen indicator", isOn: $tweaks.v.gestures.showHUD)
                Toggle("Haptic tick when a task runs", isOn: $tweaks.v.gestures.hapticOnTask)
            }
            Text("macOS still sees every touch (the cursor moves while you slide, and 3–4 finger swipes keep their system meaning). Prefer edges, corners, 4–5 fingers and taps for your own gestures.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Regions

struct RegionCard: View {
    @Environment(Tweaks.self) private var tweaks
    var body: some View {
        let g = tweaks.v.gestures
        Card("Regions", subtitle: "drag the lines to resize · \(g.regionNames.count) regions") {
            RegionEditor().frame(maxWidth: 720).frame(maxWidth: .infinity)
            HStack {
                Button { addDivider(vertical: true) } label: { Label("Column", systemImage: "plus") }
                Button { addDivider(vertical: false) } label: { Label("Row", systemImage: "plus") }
                Button { if !tweaks.v.gestures.xDividers.isEmpty { tweaks.v.gestures.xDividers.removeLast() } } label: { Label("Column", systemImage: "minus") }
                    .disabled(g.xDividers.isEmpty)
                Button { if !tweaks.v.gestures.yDividers.isEmpty { tweaks.v.gestures.yDividers.removeLast() } } label: { Label("Row", systemImage: "minus") }
                    .disabled(g.yDividers.isEmpty)
                Spacer()
                Button("Edge strips") { tweaks.v.gestures.xDividers = [0.12, 0.88]; tweaks.v.gestures.yDividers = [] }
            }
            .controlSize(.small)
            Text("Columns are lettered A, B, C… left to right; rows numbered from the top (the edge nearest the keyboard). Slides and gestures remember the region by name.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func addDivider(vertical: Bool) {
        var d = vertical ? tweaks.v.gestures.xDividers : tweaks.v.gestures.yDividers
        let edges = [0.0] + d.sorted() + [1.0]
        let widest = zip(edges, edges.dropFirst()).max { ($0.1 - $0.0) < ($1.1 - $1.0) }!
        d.append((widest.0 + widest.1) / 2)
        if vertical { tweaks.v.gestures.xDividers = d.sorted() } else { tweaks.v.gestures.yDividers = d.sorted() }
    }
}

struct RegionEditor: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks
    @Bindable private var ui = UIState.shared

    var body: some View {
        let g = tweaks.v.gestures
        let touches = hub.touch.touches
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Canvas { ctx, size in
                let pad = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 16)
                ctx.fill(pad, with: .color(Neon.isOn ? Color.black.opacity(0.4) : Color.gray.opacity(0.12)))
                // tint regions that do something
                let xs = [0.0] + g.xDividers.sorted() + [1.0], ys = [0.0] + g.yDividers.sorted() + [1.0]
                for (ci, (x0, x1)) in zip(xs, xs.dropFirst()).enumerated() {
                    for (ri, (y0, y1)) in zip(ys, ys.dropFirst()).enumerated() {
                        let name = "\(Character(UnicodeScalar(65 + min(ci, 25))!))\(ri + 1)"
                        let rect = CGRect(x: x0 * w, y: y0 * h, width: (x1 - x0) * w, height: (y1 - y0) * h).insetBy(dx: 2, dy: 2)
                        let slider = g.sliders.first { $0.enabled && $0.region == name }
                        let bound = g.bindings.contains { $0.pattern.region == name }
                        if let slider {
                            ctx.fill(Path(roundedRect: rect, cornerRadius: 10),
                                     with: .color((slider.target == .brightness ? Neon.amber : Neon.violet).opacity(0.16)))
                        } else if bound {
                            ctx.fill(Path(roundedRect: rect, cornerRadius: 10), with: .color(Neon.cyan.opacity(0.08)))
                        }
                        var label = name
                        if let slider { label += "\n\(slider.target.rawValue)" }
                        ctx.draw(Text(label).font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(slider == nil ? .secondary : .primary),
                                 at: CGPoint(x: rect.midX, y: rect.midY))
                    }
                }
                // arm corner
                if g.armMode == .armed {
                    let s = g.armCornerSize
                    let r: CGRect
                    switch g.armCorner {
                    case .topLeft: r = CGRect(x: 0, y: 0, width: s * w, height: s * h)
                    case .topRight: r = CGRect(x: (1 - s) * w, y: 0, width: s * w, height: s * h)
                    case .bottomLeft: r = CGRect(x: 0, y: (1 - s) * h, width: s * w, height: s * h)
                    case .bottomRight: r = CGRect(x: (1 - s) * w, y: (1 - s) * h, width: s * w, height: s * h)
                    }
                    ctx.fill(Path(roundedRect: r.insetBy(dx: 3, dy: 3), cornerRadius: 10),
                             with: .color((hub.gesturesArmed ? Neon.cyan : Neon.magenta).opacity(0.25)))
                    ctx.draw(Text("ARM").font(.system(size: 10, weight: .bold, design: .rounded)), at: CGPoint(x: r.midX, y: r.midY))
                }
                // dividers
                for (i, d) in g.xDividers.enumerated() {
                    var p = Path(); p.move(to: CGPoint(x: d * w, y: 6)); p.addLine(to: CGPoint(x: d * w, y: h - 6))
                    let hot = ui.dragDivider == DividerRef(vertical: true, index: i)
                    ctx.stroke(p, with: .color(Neon.cyan.opacity(hot ? 0.3 : 0.12)), lineWidth: 8)
                    ctx.stroke(p, with: .color(Neon.cyan), lineWidth: hot ? 2.5 : 1.5)
                }
                for (i, d) in g.yDividers.enumerated() {
                    var p = Path(); p.move(to: CGPoint(x: 6, y: d * h)); p.addLine(to: CGPoint(x: w - 6, y: d * h))
                    let hot = ui.dragDivider == DividerRef(vertical: false, index: i)
                    ctx.stroke(p, with: .color(Neon.violet.opacity(hot ? 0.3 : 0.12)), lineWidth: 8)
                    ctx.stroke(p, with: .color(Neon.violet), lineWidth: hot ? 2.5 : 1.5)
                }
                // live fingers
                for t in touches {
                    let c = CGPoint(x: t.x * w, y: (1 - t.y) * h)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18)), with: .color(.white.opacity(0.9)))
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 16, y: c.y - 16, width: 32, height: 32)), with: .color(Neon.cyan.opacity(0.6)), lineWidth: 2)
                }
                ctx.stroke(pad, with: .color(Neon.cyan.opacity(0.35)), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in drag(v.location, w: w, h: h) }
                .onEnded { _ in
                    ui.dragDivider = nil
                    tweaks.v.gestures.xDividers.sort()
                    tweaks.v.gestures.yDividers.sort()
                })
        }
        .aspectRatio(12480.0 / 7680.0, contentMode: .fit)
    }

    private func drag(_ p: CGPoint, w: CGFloat, h: CGFloat) {
        let g = tweaks.v.gestures
        if ui.dragDivider == nil {
            var best: (DividerRef, CGFloat)?
            for (i, d) in g.xDividers.enumerated() {
                let dist = abs(p.x - d * w)
                if dist < 16 && dist < (best?.1 ?? .infinity) { best = (DividerRef(vertical: true, index: i), dist) }
            }
            for (i, d) in g.yDividers.enumerated() {
                let dist = abs(p.y - d * h)
                if dist < 16 && dist < (best?.1 ?? .infinity) { best = (DividerRef(vertical: false, index: i), dist) }
            }
            ui.dragDivider = best?.0
        }
        guard let d = ui.dragDivider else { return }
        if d.vertical, d.index < g.xDividers.count {
            tweaks.v.gestures.xDividers[d.index] = min(0.97, max(0.03, p.x / w))
        } else if !d.vertical, d.index < g.yDividers.count {
            tweaks.v.gestures.yDividers[d.index] = min(0.97, max(0.03, p.y / h))
        }
    }
}

// MARK: - Slides (brightness / volume)

struct SlidersCard: View {
    @Environment(Tweaks.self) private var tweaks
    var body: some View {
        @Bindable var tweaks = tweaks
        let names = tweaks.v.gestures.regionNames
        Card("Slide controls", subtitle: "slide inside a region to change a level") {
            ForEach($tweaks.v.gestures.sliders) { $s in
                HStack(spacing: 10) {
                    Toggle("", isOn: $s.enabled).labelsHidden()
                    Image(systemName: s.target.icon).foregroundStyle(s.target == .brightness ? Neon.amber : Neon.violet).frame(width: 20)
                    Picker("", selection: $s.target) { ForEach(ControlTarget.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 120)
                    Picker("in", selection: $s.region) { ForEach(names, id: \.self) { Text($0).tag($0) } }.frame(width: 90)
                    Stepper("\(s.fingers) finger\(s.fingers > 1 ? "s" : "")", value: $s.fingers, in: 1...3).frame(width: 120)
                    Picker("", selection: $s.axis) { ForEach(ControlAxis.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 150)
                    Slider(value: $s.sensitivity, in: 0.5...4) { Text("speed") }.frame(width: 140)
                    Button(role: .destructive) { tweaks.v.gestures.sliders.removeAll { $0.id == s.id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                .controlSize(.small)
            }
            Button { tweaks.v.gestures.sliders.append(SliderControl(region: names.first ?? "A1", target: .volume)) } label: {
                Label("Add slide control", systemImage: "plus")
            }
        }
    }
}

// MARK: - Gesture → task

struct BindingsCard: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks
    @Bindable private var ui = UIState.shared

    var body: some View {
        @Bindable var tweaks = tweaks
        @Bindable var hub = hub
        let tasks = tweaks.v.gestures.tasks
        Card("Gestures → tasks", subtitle: "record any pattern, then choose what it runs") {
            if hub.recordingGesture {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Do the gesture on your trackpad now…").font(.callout.weight(.semibold)).foregroundStyle(Neon.cyan)
                    Spacer()
                    Button("Cancel") { hub.recordingGesture = false }
                }
            } else if let p = hub.recordedPattern {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recorded: \(pending(p).text)").font(.callout.weight(.semibold))
                    HStack(spacing: 16) {
                        if p.kind != .letter { Toggle("Anywhere on the pad", isOn: $ui.pendingAnyRegion) }
                        if p.contact != nil { Toggle("Any contact shape", isOn: $ui.pendingAnyContact) }
                    }
                    HStack {
                        Picker("Runs", selection: $ui.pendingTaskID) {
                            Text("choose a task…").tag(UUID?.none)
                            ForEach(tasks) { Text($0.name).tag(Optional($0.id)) }
                        }
                        .frame(width: 280)
                        Button("Save") {
                            tweaks.v.gestures.bindings.append(GestureBinding(pattern: pending(p), taskID: ui.pendingTaskID))
                            hub.recordedPattern = nil
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Discard") { hub.recordedPattern = nil }
                    }
                }
            } else {
                Button { hub.recordedPattern = nil; hub.recordingGesture = true } label: {
                    Label("Record a gesture", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(Neon.magenta)
            }
            if !tweaks.v.gestures.bindings.isEmpty { Divider().opacity(0.3) }
            ForEach($tweaks.v.gestures.bindings) { $b in
                HStack {
                    Toggle("", isOn: $b.enabled).labelsHidden()
                    Text(b.pattern.text).frame(maxWidth: .infinity, alignment: .leading)
                    Picker("", selection: $b.onlyInApp) {
                        Text("any app").tag(String?.none)
                        ForEach(appChoices(b.onlyInApp), id: \.self) { Text("only in \($0)").tag(Optional($0)) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    Toggle("no arming", isOn: Binding(get: { b.noArming ?? false }, set: { b.noArming = $0 }))
                    Picker("", selection: $b.taskID) {
                        Text("nothing").tag(UUID?.none)
                        ForEach(tasks) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    Button(role: .destructive) { tweaks.v.gestures.bindings.removeAll { $0.id == b.id } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
                .controlSize(.small)
            }
        }
    }

    /// Apps to offer for "only in": Finder, the running apps, and whatever is already chosen.
    private func appChoices(_ current: String?) -> [String] {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
        return Array(Set(["Finder"] + running + [current].compactMap { $0 })).sorted()
    }

    private func pending(_ p: GesturePattern) -> GesturePattern {
        var q = p
        if ui.pendingAnyRegion { q.region = nil }
        if ui.pendingAnyContact { q.contact = nil }
        return q
    }
}

// MARK: - Letters

struct LettersCard: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks
    @Bindable private var ui = UIState.shared

    var body: some View {
        @Bindable var hub = hub
        let letters = tweaks.v.gestures.letters
        let names = Array(Set(letters.map(\.name))).sorted()
        Card("Letters", subtitle: "draw with one finger · record each letter 2–3 times for best results") {
            HStack {
                TextField("Letter or name, e.g. S", text: $ui.newLetterName).frame(width: 200)
                if let rec = hub.recordingLetter {
                    ProgressView().controlSize(.small)
                    Text("Draw “\(rec)” on the trackpad now…").foregroundStyle(Neon.cyan)
                    Button("Cancel") { hub.recordingLetter = nil }
                } else {
                    Button { hub.recordingLetter = ui.newLetterName.trimmingCharacters(in: .whitespaces) } label: {
                        Label("Record", systemImage: "scribble")
                    }
                    .disabled(ui.newLetterName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Spacer()
                if let (n, score) = hub.lastLetterScore {
                    Text("last drawing looked like “\(n)” (\(Int(score * 100))%)").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(names, id: \.self) { name in
                let samples = letters.filter { $0.name == name }
                HStack(spacing: 12) {
                    LetterPreview(points: samples.first?.points ?? []).frame(width: 44, height: 44)
                    Text("“\(name)”").font(.system(.title3, design: .rounded).bold()).frame(width: 60, alignment: .leading)
                    Text("\(samples.count) sample\(samples.count == 1 ? "" : "s")").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    Picker("Runs", selection: taskBinding(for: name)) {
                        Text("nothing").tag(UUID?.none)
                        ForEach(tweaks.v.gestures.tasks) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .frame(width: 260)
                    Spacer()
                    Button(role: .destructive) {
                        tweaks.v.gestures.letters.removeAll { $0.name == name }
                        tweaks.v.gestures.bindings.removeAll { $0.pattern.kind == .letter && $0.pattern.letter == name }
                    } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                }
                .controlSize(.small)
            }
        }
    }

    /// Letter → task, kept as an ordinary gesture binding.
    private func taskBinding(for name: String) -> Binding<UUID?> {
        Binding(get: {
            tweaks.v.gestures.bindings.first { $0.pattern.kind == .letter && $0.pattern.letter == name }?.taskID
        }, set: { id in
            if let i = tweaks.v.gestures.bindings.firstIndex(where: { $0.pattern.kind == .letter && $0.pattern.letter == name }) {
                tweaks.v.gestures.bindings[i].taskID = id
            } else {
                tweaks.v.gestures.bindings.append(GestureBinding(pattern: GesturePattern(kind: .letter, fingers: 1, letter: name), taskID: id))
            }
        })
    }
}

struct LetterPreview: View {
    var points: [[Double]]
    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1 else { return }
            var p = Path()
            let m = min(size.width, size.height) * 0.8
            func pt(_ q: [Double]) -> CGPoint { CGPoint(x: size.width / 2 + q[0] * m, y: size.height / 2 + q[1] * m) }
            p.move(to: pt(points[0]))
            for q in points.dropFirst() { p.addLine(to: pt(q)) }
            ctx.stroke(p, with: .color(Neon.cyan.opacity(0.25)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            ctx.stroke(p, with: .color(Neon.cyan), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            ctx.fill(Path(ellipseIn: CGRect(origin: pt(points[0]), size: .zero).insetBy(dx: -3, dy: -3)), with: .color(Neon.magenta))
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
    }
}

// MARK: - Activity + tuning

struct GestureActivityCard: View {
    @Environment(SensorHub.self) private var hub
    var body: some View {
        Card("Activity", subtitle: "what the recognizer saw, and what ran") {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recognized").font(.caption.bold()).foregroundStyle(.secondary)
                    if hub.recentGestures.isEmpty { Text("nothing yet").foregroundStyle(.secondary) }
                    ForEach(hub.recentGestures) { g in
                        HStack {
                            Text(g.at.formatted(date: .omitted, time: .standard)).monospacedDigit().foregroundStyle(.secondary)
                            Text(g.text)
                            if let t = g.task { Text("→ \(t)").foregroundStyle(Neon.cyan) }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Task runs").font(.caption.bold()).foregroundStyle(.secondary)
                    if hub.taskLog.isEmpty { Text("nothing yet").foregroundStyle(.secondary) }
                    ForEach(hub.taskLog, id: \.self) { Text($0) }
                }
            }
            .font(.caption)
        }
    }
}

struct TuningCard: View {
    @Environment(Tweaks.self) private var tweaks
    var body: some View {
        @Bindable var tweaks = tweaks
        Card("Fine tuning") {
            Grid(horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    TweakSlider(title: "Tap: max length (s)", value: $tweaks.v.gestures.tapMaxSeconds, range: 0.1...0.6, format: "%.2f")
                    TweakSlider(title: "Double-tap gap (s)", value: $tweaks.v.gestures.multiTapGap, range: 0.15...0.8, format: "%.2f")
                }
                GridRow {
                    TweakSlider(title: "Swipe: min distance (pad)", value: $tweaks.v.gestures.swipeMinDistance, range: 0.05...0.5, format: "%.2f")
                    TweakSlider(title: "Hard press threshold", value: $tweaks.v.gestures.pressThreshold, range: 200...2000, step: 10, format: "%.0f")
                }
                GridRow {
                    TweakSlider(title: "Ignore contacts longer than (mm, palms)", value: $tweaks.v.gestures.palmMaxMM, range: 8...30, format: "%.0f")
                    TweakSlider(title: "Flat finger: length ÷ width above", value: $tweaks.v.gestures.flatRatio, range: 1.1...2.5, format: "%.2f")
                }
                GridRow {
                    TweakSlider(title: "Letter match needed", value: $tweaks.v.gestures.letterThreshold, range: 0.5...0.95, format: "%.2f")
                    TweakSlider(title: "Arm: hold time (s)", value: $tweaks.v.gestures.armHoldSeconds, range: 0.3...2, format: "%.1f")
                }
            }
        }
    }
}
