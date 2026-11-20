import SensoriumCore
import AppKit
import CSensors
import SwiftUI

/// Self-snapshots for checking the UI without Screen Recording permission:
///   SENSORIUM_SNAPSHOT_DIR=/tmp/shots build/Sensorium.app/Contents/MacOS/Sensorium
/// Renders every page of the main window, every popover tab and three sample desktop
/// widgets to PNG files. Settings changes made during the run are not saved.
enum DebugSnapshots {
    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["SENSORIUM_SNAPSHOT_DIR"] else { return }
        Tweaks.persist = false
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let pages = Page.allCases
        var t = 3.0
        for (i, page) in pages.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { UIState.shared.page = page }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.9) {
                saveWindow(to: "\(dir)/page-\(String(format: "%02d", i))-\(page.icon).png")
            }
            t += 1.2
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t) {
            for tab in MenuTab.allCases { saveMenu(tab, to: "\(dir)/menu-\(tab.rawValue).png") }
            for kind in [MenuWidget.temps, .vibration, .lid] { DesktopWidgetManager.add(kind) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 2) {
            for (i, w) in NSApp.windows.filter(DesktopWidgetManager.isWidget).enumerated() {
                save(view: w.contentView, to: "\(dir)/widget-\(i).png")
            }
            UIState.shared.page = .trackpad
            FileManager.default.createFile(atPath: "\(dir)/done", contents: nil)
        }
    }

    private static func saveWindow(to path: String) {
        save(view: NSApp.windows.first { $0.isVisible && !DesktopWidgetManager.isWidget($0) && $0.frame.width > 600 }?.contentView, to: path)
    }

    private static func save(view: NSView?, to path: String) {
        guard let view, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    @MainActor private static func saveMenu(_ tab: MenuTab, to path: String) {
        Tweaks.shared.v.menuTab = tab
        let renderer = ImageRenderer(content: MenuPanel()
            .environment(SensorHub.shared)
            .environment(Tweaks.shared)
            .background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Load test: SENSORIUM_PERF=/tmp/perf.md <app binary>
/// Visits every page, then window-closed states, measuring CPU and memory in each,
/// and writes a Markdown table. Settings changes made during the run are not saved.
enum PerfHarness {
    static var forceVisible = false

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        // Profiling aid: SENSORIUM_HOLD_PAGE="Motion" keeps that page "visible" so `sample` can be run on it.
        if let hold = env["SENSORIUM_HOLD_PAGE"], let page = Page(rawValue: hold) {
            Tweaks.persist = false
            forceVisible = true
            if let fps = env["SENSORIUM_PERF_FPS"].flatMap(Double.init) { Tweaks.shared.v.fps = fps }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { UIState.shared.page = page }
            if let dump = env["SENSORIUM_DUMP"] {   // debug: what the hub holds after 4 s on that page
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    let h = SensorHub.shared
                    let text = "needed(.light)=\(h.needed(.light)) needed(.spu)=\(h.needed(.spu))\nlightLive=\(String(describing: h.lightLive))\nluxHistory=\(h.luxHistory.count) samples\n"
                    try? text.write(toFile: dump, atomically: true, encoding: .utf8)
                    exit(0)
                }
            }
            return
        }
        guard let out = env["SENSORIUM_PERF"] else { return }
        Tweaks.persist = false
        forceVisible = true
        if let fps = env["SENSORIUM_PERF_FPS"].flatMap(Double.init) { Tweaks.shared.v.fps = fps }
        var rows = ["| state | CPU % (100 = 1 core) | memory MB | threads | tick fps | sensor streams | windows on screen |", "|---|---:|---:|---:|---:|---|---|"]
        var states: [(String, Double, () -> Void)] = Page.allCases.map { p in ("\(p.rawValue) page", 2.0, { UIState.shared.page = p }) }
        states.append(("window closed (menu bar only)", 5, {
            forceVisible = false
            UIState.shared.page = .trackpad
            NSApp.windows.filter { !DesktopWidgetManager.isWidget($0) && $0.frame.width > 600 }.forEach { $0.orderOut(nil) }
        }))
        states.append(("window closed + 3 desktop widgets", 3, {
            forceVisible = true   // widgets on the desktop count as visible for this measurement
            for k in [MenuWidget.temps, .vibration, .lid] { DesktopWidgetManager.add(k) }
        }))
        func step(_ i: Int) {
            guard i < states.count else {
                try? rows.joined(separator: "\n").appending("\n").write(toFile: out, atomically: true, encoding: .utf8)
                FileManager.default.createFile(atPath: out + ".done", contents: nil)
                return
            }
            states[i].2()
            DispatchQueue.main.asyncAfter(deadline: .now() + states[i].1) {
                let c0 = PerfMeter.cpuSeconds(), t0 = sn_now()
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    let cpu = (PerfMeter.cpuSeconds() - c0) / (sn_now() - t0) * 100
                    let hub = SensorHub.shared
                    let streams = [hub.status.spuActive ? "SPU" : nil, hub.status.orientationActive ? "orientation" : nil].compactMap { $0 }
                    rows.append("| \(states[i].0) | \(fmt(cpu, 1)) | \(fmt(PerfMeter.footprintMB(), 1)) | \(PerfMeter.threadCount()) | \(fmt(hub.debugFPS, 0)) | \(streams.isEmpty ? "none" : streams.joined(separator: "+")) | \(hub.debugVisibleWindows.joined(separator: ", ")) |")
                    step(i + 1)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { step(0) }
    }
}

/// Recognizer self-test with synthetic frames: SENSORIUM_GESTURE_SELFTEST=/tmp/out.txt <binary>
/// Touches nothing on the system (its own engine; control deltas are only summed).
enum GestureSelfTest {
    static var engine: GestureEngine?   // kept alive so the double-tap timer can fire

    static func runIfRequested() {
        guard let out = ProcessInfo.processInfo.environment["SENSORIUM_GESTURE_SELFTEST"] else { return }
        let e = GestureEngine()
        engine = e
        var cfg = GestureConfig()
        cfg.armMode = .always
        e.update(cfg)
        var lines: [String] = []
        var deltas: [String: Double] = [:]
        var current = ""
        var strokes: [[CGPoint]] = []
        e.onControl = { t, d in deltas["\(current) → \(t.rawValue)", default: 0] += d }
        e.onEvent = { ev in
            switch ev {
            case .pattern(let p): lines.append(p.text)
            case .stroke(let pts, _): strokes.append(pts)
            case .arm(let on): lines.append(on ? "ARMED" : "DISARMED")
            }
        }
        var t = 100.0
        func touch(_ id: Int32, _ x: Double, _ y: Double, pressure: Double = 20, major: Float = 8, minor: Float = 7) -> SNTouch {
            SNTouch(id: id, state: 4, x: Float(x), y: Float(y), vx: 0, vy: 0, pressure: Float(pressure), total: 1,
                    density: 1, majorAxis: major, minorAxis: minor, angle: 1.57)
        }
        func gesture(_ name: String, frames n: Int, gap: Double = 0.5, _ make: (Int) -> [SNTouch]) {
            current = name
            for i in 0..<n { e.process(make(i), t: t); t += 0.01 }
            e.process([SNTouch](), t: t)
            t += gap
        }
        // trackpad y is 0 at the bottom, so "slide up" = y increasing; display y = 1 - y
        gesture("left edge slide up", frames: 40) { i in [touch(1, 0.05, 0.3 + 0.01 * Double(i))] }
        gesture("right edge slide down", frames: 30) { i in [touch(1, 0.95, 0.7 - 0.01 * Double(i))] }
        gesture("3-finger tap", frames: 8) { _ in (0..<3).map { touch(Int32($0), 0.4 + 0.05 * Double($0), 0.5) } }
        gesture("4-finger tap 1", frames: 8, gap: 0.15) { _ in (0..<4).map { touch(Int32($0), 0.35 + 0.05 * Double($0), 0.5) } }
        gesture("4-finger tap 2", frames: 8) { _ in (0..<4).map { touch(Int32($0), 0.35 + 0.05 * Double($0), 0.5) } }
        gesture("2-finger swipe left", frames: 30) { i in (0..<2).map { touch(Int32($0), 0.7 - 0.01 * Double(i) + 0.05 * Double($0), 0.5) } }
        gesture("hard press", frames: 50) { i in [touch(1, 0.5, 0.5, pressure: Double(i) * 30)] }
        gesture("palm slide (ignored)", frames: 40) { i in [touch(1, 0.05, 0.3 + 0.01 * Double(i), major: 20)] }
        gesture("hold", frames: 100) { _ in [touch(1, 0.5, 0.5)] }
        gesture("flat-finger tap", frames: 8) { _ in [touch(1, 0.5, 0.5, major: 12, minor: 6)] }
        // letters: an "L" drawn twice, then a "Z"
        func drawL(_ i: Int, _ wobble: Double) -> [SNTouch] {   // down the left side, then right along the bottom
            let k = Double(i) / 39
            let (x, yDisp) = k < 0.6 ? (0.4 + wobble, 0.3 + k / 0.6 * 0.4) : (0.4 + (k - 0.6) / 0.4 * 0.25, 0.7 + wobble)
            return [touch(1, x, 1 - yDisp)]
        }
        func drawZ(_ i: Int) -> [SNTouch] {
            let k = Double(i) / 39
            let p: (Double, Double) = k < 0.33 ? (0.4 + k / 0.33 * 0.25, 0.3)
                : k < 0.66 ? (0.65 - (k - 0.33) / 0.33 * 0.25, 0.3 + (k - 0.33) / 0.33 * 0.4)
                : (0.4 + (k - 0.66) / 0.34 * 0.25, 0.7)
            return [touch(1, p.0, 1 - p.1)]
        }
        e.recording = true
        gesture("record L", frames: 40) { drawL($0, 0) }
        gesture("draw L again (wobbly)", frames: 40) { drawL($0, 0.01) }
        gesture("draw Z", frames: 40) { drawZ($0) }
        e.recording = false
        // arming: arm mode on, hold the top-right corner (display y small = trackpad y near 1)
        cfg.armMode = .armed
        cfg.slidersAlwaysOn = true
        e.update(cfg)
        gesture("tap while not armed (ignored)", frames: 8) { _ in [touch(1, 0.5, 0.5)] }
        gesture("hold top-right corner", frames: 80) { _ in [touch(1, 0.95, 0.95)] }
        gesture("3-finger tap while armed", frames: 8) { _ in (0..<3).map { touch(Int32($0), 0.4 + 0.05 * Double($0), 0.5) } }
        // rhythm: a binding makes the engine listen for rhythms: tap tap (pause) tap
        cfg.bindings = [GestureBinding(pattern: GesturePattern(kind: .rhythm, fingers: 2, rhythm: "SL"))]
        e.update(cfg)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            gesture("rhythm tap 1", frames: 8, gap: 0.15) { _ in (0..<2).map { touch(Int32($0), 0.45 + 0.05 * Double($0), 0.5) } }
            gesture("rhythm tap 2", frames: 8, gap: 0.5) { _ in (0..<2).map { touch(Int32($0), 0.45 + 0.05 * Double($0), 0.5) } }
            gesture("rhythm tap 3", frames: 8) { _ in (0..<2).map { touch(Int32($0), 0.45 + 0.05 * Double($0), 0.5) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let expected = ["3-finger tap (fingertip) in B1", "4-finger double tap (fingertip) in B1", "2-finger swipe left in B1",
                            "1-finger hard press (fingertip) in B1", "1-finger hold (fingertip) in B1", "1-finger tap (flat finger) in B1",
                            "ARMED", "2-finger tap rhythm • •  —  • (fingertip) in B1"]
            var report = ["Events (order of arrival):"] + lines.map { "  " + $0 + (expected.contains($0) ? "   ✓" : "   ✗ unexpected") }
                + expected.filter { !lines.contains($0) }.map { "  MISSING: " + $0 }
            if strokes.count >= 3, let t = LetterRecognizer.template(name: "L", from: strokes[0]) {
                let again = LetterRecognizer.recognize(strokes[1], [t]), z = LetterRecognizer.recognize(strokes[2], [t])
                report.append(String(format: "Letters: recorded L; wobbly L scores %.2f (match ≥ %.2f); Z scores %.2f",
                                     again?.1 ?? -1, cfg.letterThreshold, z?.1 ?? -1))
            } else {
                report.append("Letters: only \(strokes.count) strokes captured")
            }
            report += ["Slider changes (1.0 = full range):"] + deltas.sorted { $0.key < $1.key }.map { "  \($0.key): \(String(format: "%+.2f", $0.value))" }
            try? report.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}

/// Cost of one trackpad frame on the background path: SENSORIUM_TOUCH_BENCH=/tmp/out.txt <binary>
enum TouchBench {
    static func runIfRequested() {
        guard let out = ProcessInfo.processInfo.environment["SENSORIUM_TOUCH_BENCH"] else { return }
        let hub = SensorHub.shared
        var frame = (0..<2).map { i in
            SNTouch(id: Int32(i), state: 4, x: 0.4 + 0.1 * Float(i), y: 0.5, vx: 0, vy: 0, pressure: 25, total: 1,
                    density: 1, majorAxis: 8, minorAxis: 7, angle: 1.57)
        }
        func run(_ label: String, ui: Bool) -> String {
            hub.store.lock.lock(); hub.store.touchUIWanted = ui; hub.store.lock.unlock()
            let n = 200_000
            let c0 = PerfMeter.cpuSeconds(), t0 = sn_now()
            for i in 0..<n {
                frame[0].x = 0.4 + Float(i % 100) * 0.001   // a moving finger
                if i % 50 == 49 { _ = [SNTouch]().withUnsafeBufferPointer { hub.ingestTouches($0) } }   // lift now and then
                else { frame.withUnsafeBufferPointer { hub.ingestTouches($0) } }
            }
            let cpu = PerfMeter.cpuSeconds() - c0, wall = sn_now() - t0
            let us = cpu / Double(n) * 1e6
            return String(format: "%@: %.2f µs CPU per frame → at 120 frames/s while touching = %.3f%% of one core (wall %.2f s)",
                          label, us, us * 120 / 1e4, wall)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let report = [run("background path (no trackpad view open)", ui: false),
                          run("full path (trackpad view open)", ui: true)]
            try? report.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            exit(0)
        }
    }
}
