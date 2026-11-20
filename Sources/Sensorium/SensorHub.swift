import SensoriumCore
import AppKit
import CSensors
import Foundation
import LocalAuthentication
import Observation

/// Everything the background callbacks write. Guarded by `lock`; never observed by SwiftUI.
final class RawStore {
    let lock = NSLock()
    var cfg = TweakValues()

    // trackpad
    var touches: [SNTouch] = []
    var smoothed: [Int32: Double] = [:]
    var touchTime = 0.0
    var touchFrames = 0
    var hapticArmed = true
    var hapticFires = 0

    // motion / SPU
    var accel = Ring<Vec3>(6000)
    var gyro = Ring<Vec3>(6000)
    var vib = Ring<Sample>(6000)
    var baseline = 0.0
    var taps = 0
    var lastTap = 0.0
    var lid = -1
    var imuTemp: Double?
    var light = LightReading()
    var alsTemp: Double?
    var accelFrames = 0
    var gyroFrames = 0
    var raw: [UInt32: RawStream] = [:]
    var rawWanted = false          // per-byte bookkeeping only while the Raw page is open
    var touchUIWanted = false      // a trackpad view is on screen (else touches go straight to gestures)

    // devmotion6: fused orientation (hidden 100/s stream)
    var quat: (x: Double, y: Double, z: Double, w: Double)?
    var rotRate: (Double, Double, Double)?
    var userAccel: (Double, Double, Double)?
    var attitude = Ring<Vec3>(6000)    // x = roll, y = pitch, z = yaw, degrees
    var devFrames = 0
    var cma: [HIDEventInfo] = []
    var cmaCount = 0

    // HID events (Touch ID sensor, buttons)
    var events: [HIDEventInfo] = []
    var eventCount = 0

    // keyboard
    var pressed: Set<UInt16> = []
    var strokes: [KeyStroke] = []
    var counts: [UInt16: Int] = [:]
    var holdSum: [UInt16: Double] = [:]
    var holdN: [UInt16: Int] = [:]
    var lastUp: [UInt16: Double] = [:]
    var strokeID = 0
}

struct RawStream {
    var page = 0, usage = 0
    var count = 0
    var last: [UInt8] = []
    var changedAt: [Double] = []
    var lastT = 0.0
    var interval = 0.0
}

struct AuthAttempt: Identifiable {
    var id = UUID()
    var at = Date()
    var ok: Bool
    var seconds: Double
    var message: String
}

// MARK: - C callbacks (no captures allowed; the hub comes back through ctx)

private func hub(_ ctx: UnsafeMutableRawPointer?) -> SensorHub? {
    ctx.map { Unmanaged<SensorHub>.fromOpaque($0).takeUnretainedValue() }
}

private let touchCallback: SNTouchCallback = { touches, count, _, ctx in
    let buf = (touches != nil && count > 0)
        ? UnsafeBufferPointer(start: touches, count: Int(count)) : UnsafeBufferPointer<SNTouch>(start: nil, count: 0)
    hub(ctx)?.ingestTouches(buf)
}

private let reportCallback: SNReportCallback = { page, usage, report, length, _, ctx in
    guard let report, length > 0 else { return }
    hub(ctx)?.ingestReport(page: Int(page), usage: Int(usage), bytes: UnsafeBufferPointer(start: report, count: Int(length)))
}

private let vendorCallback: SNReportCallback = { page, usage, data, length, ts, ctx in
    guard let data, length > 0 else { return }
    hub(ctx)?.ingestVendor(usage: Int(usage), bytes: UnsafeBufferPointer(start: data, count: Int(length)), t: ts)
}

private let eventCallback: SNEventCallback = { cls, type, data, length, ts, ctx in
    let name = cls.map { String(cString: $0) } ?? "?"
    let bytes = (data != nil && length > 0) ? Array(UnsafeBufferPointer(start: data, count: Int(length))) : []
    hub(ctx)?.ingestEvent(service: name, type: type, bytes: bytes, t: ts)
}

private let keyCallback: SNKeyCallback = { page, usage, down, ts, ctx in
    let code: UInt16? = page == 0xFF && usage == 0x03 ? 0x3F : KeyLayout.hidToVK[usage]
    guard let code else { return }
    hub(ctx)?.ingestKey(code: code, down: down != 0, t: ts)
}

// MARK: - Hub

@Observable final class SensorHub {
    static let shared = SensorHub()

    @ObservationIgnored let tweaks = Tweaks.shared
    @ObservationIgnored let store = RawStore()

    // Published every tick.
    var now = 0.0
    var touch = TouchSnap()
    var motion = MotionSnap()
    var keys = KeySnap()
    var slow = SlowSnap()
    var raw: [RawStreamInfo] = []
    var orientation = OrientationSnap()
    var cma: [HIDEventInfo] = []
    var cmaCount = 0
    var events: [HIDEventInfo] = []
    var eventCount = 0
    var status = Status()

    // Click calibration (from macOS's own Force Touch stages, only inside our window).
    var clickStage = 0
    var stagePressure: [Int: Double] = [:]

    // Haptics page state.
    var lastHapticResult: Int32?
    var metronomeOn = false { didSet { updateMetronome() } }
    var metronomeBPM = 120.0 { didSet { updateMetronome() } }

    // Sensorium's own load + the whole Mac's, sampled once a second.
    var proc = ProcSample(t: 0, cpu: 0, footprintMB: 0, threads: 0)
    var procHistory: [ProcSample] = []
    var system = SystemSample()
    @ObservationIgnored let perfMeter = PerfMeter()

    // Light sensor detail (only while its card is open).
    var lightLive: LightLive?
    var luxHistory: [Sample] = []
    @ObservationIgnored private var lastLightPoll = 0.0
    @ObservationIgnored private var luxRing = Ring<Sample>(700)

    // Trackpad gestures.
    @ObservationIgnored let gestureEngine = GestureEngine()
    @ObservationIgnored private var appliedGestures: GestureConfig?
    var recordingGesture = false { didSet { recordingChanged() } }
    var recordedPattern: GesturePattern?
    var recordingLetter: String? { didSet { recordingChanged() } }
    var lastStroke: [CGPoint] = []
    var lastLetterScore: (String, Double)?
    var gesturesArmed = false
    var serviceRunning = false                 // the background helper does gestures; the app only shows them
    var serviceStats: (cpu: Double, mb: Double)?
    @ObservationIgnored private var lastServiceCPU: (Double, Double)?
    @ObservationIgnored private var touchRunning = true
    @ObservationIgnored private var armTimer: Timer?
    var recentGestures: [RecentGesture] = []
    var taskLog: [String] = []

    // Menu bar.
    var menuTitle = ""
    var anythingVisible = true

    // No Sleep (caffeinate).
    var noSleep = false
    var noSleepSince: Date?
    var noSleepUntil: Date?
    var noSleepCommand = ""
    var noSleepError: String?

    // Touch ID.
    var biometry = "checking…"
    var biometryReady = false
    var authAttempts: [AuthAttempt] = []
    var authRunning = false

    // What the visible views need; streams and snapshots run only while needed.
    @ObservationIgnored private var needCounts: [Need: Int] = [:]
    @ObservationIgnored private var vendorRunning = false
    var debugFPS: Double { fps }
    var debugVisibleWindows: [String] {
        NSApp.windows.filter { $0.isVisible && $0.occlusionState.contains(.visible) }
            .map { "\(type(of: $0))\(DesktopWidgetManager.isWidget($0) ? "(widget)" : "")" }
    }
    func need(_ n: Need, _ on: Bool) { needCounts[n, default: 0] = max(0, needCounts[n, default: 0] + (on ? 1 : -1)) }
    func needed(_ n: Need) -> Bool { (needCounts[n] ?? 0) > 0 }

    @ObservationIgnored private var ctx: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var slowTimer: Timer?
    @ObservationIgnored private var metronome: Timer?
    @ObservationIgnored private var fps = 0.0
    @ObservationIgnored private var slowEvery = 0.0
    @ObservationIgnored private var globalWanted = false
    @ObservationIgnored private var pressureRing = Ring<Sample>(6000)
    @ObservationIgnored private var tempRings: [String: Ring<Sample>] = [:]
    @ObservationIgnored private var rateT = 0.0
    @ObservationIgnored private var rateFrames = (0, 0, 0)
    @ObservationIgnored private var clockOffset = 0.0
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var caffeinate: Process?
    @ObservationIgnored private var spuRunning = false
    @ObservationIgnored private var hiddenSince: Double?
    @ObservationIgnored private var dockShown: Bool?
    @ObservationIgnored private var effectiveFPS = 30.0
    @ObservationIgnored private var spuAllowed = true
    @ObservationIgnored private var lastTouchActive = -1e9
    @ObservationIgnored private var lastTitlePoll = -1e9
    @ObservationIgnored private var lastIMPoll = -1e9
    @ObservationIgnored private var lastRawPublish = 0.0
    @ObservationIgnored private var lastScalars: MotionScalars?
    @ObservationIgnored private var lastWidgetKey: WidgetSyncKey?
    @ObservationIgnored private let slowQueue = DispatchQueue(label: "sensorium.slow", qos: .utility)

    // MARK: lifecycle

    func start() {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Live sensor dashboard")
        clockOffset = sn_now() - ProcessInfo.processInfo.systemUptime
        status.touchDevices = sn_touch_start(touchCallback, ctx)
        status.eventServices = sn_events_start(eventCallback, ctx)
        installMonitors()
        setUpGestures()
        checkBiometry()
        tick()
        pollSlow()
    }

    func stop() {
        timer?.invalidate()
        slowTimer?.invalidate()
        metronome?.invalidate()
        caffeinate?.terminate()
        sn_touch_stop()
        sn_spu_stop()
        sn_vendor_stop()
        sn_keys_stop()
        sn_events_stop()
        sn_haptic_close()
        monitors.forEach(NSEvent.removeMonitor)
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    private func schedule(_ old: inout Timer?, every seconds: Double, _ body: @escaping () -> Void) {
        old?.invalidate()
        let t = Timer(timeInterval: seconds, repeats: true) { _ in body() }
        RunLoop.main.add(t, forMode: .common)   // keeps ticking while sliders are dragged
        old = t
    }

    // MARK: ingestion (background threads)

    func ingestTouches(_ buf: UnsafeBufferPointer<SNTouch>) {
        let now = sn_now()
        // Background fast path: no trackpad view on screen and no pressure-haptic → only the
        // gesture recognizer sees the frame (read in place, nothing copied or stored).
        store.lock.lock()
        let fast = !store.touchUIWanted && !store.cfg.hapticOnPressure
        store.lock.unlock()
        if fast {
            gestureEngine.process(buf, t: now)
            return
        }
        var fire: (Int32, Float, Float)?
        store.lock.lock()
        let cfg = store.cfg
        let alpha = max(0.01, min(1, cfg.pressureSmoothing))
        var list: [SNTouch] = []
        var smoothed: [Int32: Double] = [:]
        var maxP = 0.0
        for t in buf where t.state >= 1 && t.state <= 6 {
            list.append(t)
            let prev = store.smoothed[t.id] ?? Double(t.pressure)
            let s = prev + alpha * (Double(t.pressure) - prev)
            smoothed[t.id] = s
            maxP = max(maxP, s)
        }
        store.touches = list
        store.smoothed = smoothed
        store.touchTime = now
        store.touchFrames += 1
        if cfg.hapticOnPressure {
            if store.hapticArmed && maxP >= cfg.hapticThreshold {
                store.hapticArmed = false
                store.hapticFires += 1
                fire = (Int32(cfg.hapticID), Float(cfg.hapticArg1), Float(cfg.hapticArg2))
            } else if !store.hapticArmed && maxP < cfg.hapticThreshold * cfg.hapticRearm {
                store.hapticArmed = true
            }
        }
        store.lock.unlock()
        if let f = fire { _ = sn_haptic_fire(f.0, f.1, f.2) }
        gestureEngine.process(buf, t: now)
    }

    func ingestReport(page: Int, usage: Int, bytes b: UnsafeBufferPointer<UInt8>) {
        let now = sn_now()
        store.lock.lock()
        defer { store.lock.unlock() }
        if store.rawWanted {   // per-byte change tracking only while the Raw page is open
            let key = SPU.key(page, usage)
            var s = store.raw[key] ?? RawStream(page: page, usage: usage)
            if s.changedAt.count != b.count { s.changedAt = Array(repeating: 0, count: b.count) }
            for i in 0..<min(b.count, s.last.count) where s.last[i] != b[i] { s.changedAt[i] = now }
            if s.lastT > 0 {
                let dt = now - s.lastT
                s.interval = s.interval == 0 ? dt : s.interval * 0.95 + dt * 0.05
            }
            s.last = Array(b)
            s.lastT = now
            s.count += 1
            store.raw[key] = s
        }

        switch (page, usage) {
        case (0xFF00, 0x03) where b.count >= 22:
            let x = Bytes.fixed(b, 6), y = Bytes.fixed(b, 10), z = Bytes.fixed(b, 14)
            store.accel.append(Vec3(t: now, x: x, y: y, z: z))
            store.imuTemp = Bytes.fixed(b, 18)
            store.accelFrames += 1
            let mag = (x * x + y * y + z * z).squareRoot()
            if store.baseline == 0 { store.baseline = mag }
            store.baseline += store.cfg.baselineSmoothing * (mag - store.baseline)
            let vib = abs(mag - store.baseline) * 1000
            store.vib.append(Sample(t: now, v: vib))
            if vib >= store.cfg.tapThreshold && now - store.lastTap > 0.15 {
                store.taps += 1
                store.lastTap = now
            }
        case (0xFF00, 0x09) where b.count >= 22:
            store.gyro.append(Vec3(t: now, x: Bytes.fixed(b, 6), y: Bytes.fixed(b, 10), z: Bytes.fixed(b, 14)))
            store.gyroFrames += 1
        case (0x0020, 0x8A) where b.count >= 3:
            store.lid = Bytes.u16(b, 1)
        case (0xFF00, 0x04) where b.count >= 73:
            store.light = LightReading(lux: Bytes.f32(b, 40), cct: Bytes.f32(b, 69),
                                       channels: stride(from: 20, through: 36, by: 4).map { Bytes.u32(b, $0) })
        case (0xFF00, 0x05) where b.count >= 6:
            store.alsTemp = Bytes.fixed(b, 2)
        default:
            break
        }
    }

    /// devmotion6 (fused orientation) and cma (motion-coprocessor records).
    func ingestVendor(usage: Int, bytes b: UnsafeBufferPointer<UInt8>, t: Double) {
        store.lock.lock()
        defer { store.lock.unlock() }
        if usage == 0x05, b.count >= 52 {
            let x = Bytes.f32(b, 12), y = Bytes.f32(b, 16), z = Bytes.f32(b, 20), w = Bytes.f32(b, 24)
            store.quat = (x, y, z, w)
            store.rotRate = (Bytes.f32(b, 28), Bytes.f32(b, 32), Bytes.f32(b, 36))
            store.userAccel = (Bytes.f32(b, 40), Bytes.f32(b, 44), Bytes.f32(b, 48))
            let e = Orientation.euler(x: x, y: y, z: z, w: w)
            store.attitude.append(Vec3(t: sn_now(), x: e.roll, y: e.pitch, z: e.yaw))
            store.devFrames += 1
        } else if usage == 0x01 {
            store.cmaCount += 1
            store.cma.append(HIDEventInfo(id: store.cmaCount, service: "cma", type: UInt32(b.first ?? 0), t: t, bytes: Array(b)))
            if store.cma.count > 40 { store.cma.removeFirst(store.cma.count - 40) }
        }
    }

    func ingestEvent(service: String, type: UInt32, bytes: [UInt8], t: Double) {
        store.lock.lock()
        store.eventCount += 1
        store.events.append(HIDEventInfo(id: store.eventCount, service: service, type: type, t: t, bytes: bytes))
        if store.events.count > 60 { store.events.removeFirst(store.events.count - 60) }
        store.lock.unlock()
    }

    func ingestKey(code: UInt16, down: Bool, t: Double) {
        store.lock.lock()
        defer { store.lock.unlock() }
        if down {
            guard !store.pressed.contains(code) else { return }   // auto-repeat
            store.pressed.insert(code)
            store.strokeID += 1
            store.strokes.append(KeyStroke(id: store.strokeID, code: code, down: t, up: nil,
                                           lane: min(store.pressed.count - 1, 2)))
            if store.strokes.count > 500 { store.strokes.removeFirst(100) }
            store.counts[code, default: 0] += 1
        } else {
            guard store.pressed.remove(code) != nil else { return }
            if let i = store.strokes.lastIndex(where: { $0.code == code && $0.up == nil }) {
                store.strokes[i].up = t
                store.holdSum[code, default: 0] += t - store.strokes[i].down
                store.holdN[code, default: 0] += 1
            }
            store.lastUp[code] = t
        }
    }

    /// Releases every held key, e.g. when the window loses focus and the key-ups will never arrive.
    func releaseAll(except keep: Set<UInt16> = []) {
        let t = sn_now()
        store.lock.lock()
        let held = store.pressed.subtracting(keep)
        store.lock.unlock()
        held.forEach { ingestKey(code: $0, down: false, t: t) }
    }

    // MARK: in-window input (main thread)

    private func installMonitors() {
        let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self else { return e }
            let cfg = self.tweaks.v
            if !self.status.globalKeysActive {
                let t = e.timestamp + self.clockOffset
                switch e.type {
                case .keyDown: if !e.isARepeat { self.ingestKey(code: e.keyCode, down: true, t: t) }
                case .keyUp: self.ingestKey(code: e.keyCode, down: false, t: t)
                case .flagsChanged: self.ingestModifier(e, t: t)
                default: break
                }
            }
            if e.type == .flagsChanged || e.modifierFlags.contains(.command) { return e }
            if NSApp.keyWindow?.firstResponder is NSText { return e }   // typing in a text field
            return cfg.swallowKeys ? nil : e   // swallowing avoids the "invalid key" beep
        }
        let pressureMonitor = NSEvent.addLocalMonitorForEvents(matching: .pressure) { [weak self] e in
            guard let self else { return e }
            let stage = e.stage
            if stage > self.clickStage {
                self.store.lock.lock()
                let maxRaw = self.store.touches.map { Double($0.pressure) }.max() ?? 0
                self.store.lock.unlock()
                self.stagePressure[stage] = maxRaw
            }
            self.clickStage = stage
            return e
        }
        monitors = [keyMonitor as Any, pressureMonitor as Any]
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, !self.status.globalKeysActive else { return }
            self.releaseAll()
        }
    }

    private func ingestModifier(_ e: NSEvent, t: Double) {
        let code = e.keyCode
        if code == 0x39 {   // caps lock only reports the toggle, so draw a short tap
            ingestKey(code: code, down: true, t: t)
            ingestKey(code: code, down: false, t: t + 0.08)
            return
        }
        store.lock.lock()
        let wasDown = store.pressed.contains(code)
        store.lock.unlock()
        ingestKey(code: code, down: !wasDown, t: t)
        // macOS drops key-ups of letters released while Cmd is held; clean them up with Cmd.
        if wasDown && (code == 0x37 || code == 0x36) { releaseAll(except: KeyLayout.modifiers) }
    }

    // MARK: tick (main thread, at the chosen fps)

    func tick() {
        let cfg = tweaks.v
        manageVisibility(cfg)
        let wantFPS = effectiveFPS   // window: full rate; only widgets: widget rate; nothing: 2 fps for the menu bar title
        if wantFPS != fps { fps = wantFPS; schedule(&timer, every: 1 / max(1, fps)) { [weak self] in self?.tick() } }
        if cfg.slowPollSeconds != slowEvery {
            slowEvery = cfg.slowPollSeconds
            schedule(&slowTimer, every: max(0.2, slowEvery)) { [weak self] in self?.pollSlow() }
        }
        if cfg.globalKeys != globalWanted { globalWanted = cfg.globalKeys; updateGlobalKeys() }

        if appliedGestures != cfg.gestures {
            appliedGestures = cfg.gestures
            gestureEngine.update(cfg.gestures)
        }
        manageStreams(cfg)
        let wantMotion = needed(.motion), wantKeys = needed(.keys), wantRaw = needed(.raw), wantOrient = needed(.orientation)
        let now = sn_now()
        let t0 = now - cfg.historySeconds
        store.lock.lock()
        store.cfg = cfg
        store.rawWanted = wantRaw
        store.touchUIWanted = needed(.touch)
        let fresh = now - store.touchTime < 0.12
        let rawTouches = fresh ? store.touches : []
        let smoothed = store.smoothed
        let hapticFires = store.hapticFires
        var m = MotionSnap(accel: wantMotion ? store.accel.suffix(since: t0) { $0.t } : [],
                           gyro: wantMotion ? store.gyro.suffix(since: t0) { $0.t } : [],
                           vib: wantMotion ? store.vib.suffix(since: t0) { $0.t } : [],
                           latest: store.accel.last, latestGyro: store.gyro.last,
                           vibNow: store.vib.last?.v ?? 0, taps: store.taps, lastTap: store.lastTap,
                           lid: store.lid, imuTemp: store.imuTemp, light: store.light, alsTemp: store.alsTemp)
        let frames = (store.touchFrames, store.accelFrames, store.gyroFrames)
        let rawStreams = wantRaw ? store.raw : [:]
        let orient = wantOrient ? OrientationSnap(quat: store.quat, rotRate: store.rotRate, userAccel: store.userAccel,
                                                  history: store.attitude.suffix(since: t0) { $0.t }) : nil
        let devFrames = store.devFrames
        let cmaList = wantRaw ? store.cma : [], cmaCount = store.cmaCount
        let events = store.events, eventCount = store.eventCount
        let pressed = store.pressed, strokes = store.strokes, counts = store.counts
        let holdSum = store.holdSum, holdN = store.holdN, lastUp = store.lastUp
        store.lock.unlock()
        let lastKeyActivity = max(strokes.last?.down ?? 0, lastUp.values.max() ?? 0)

        // trackpad
        let points = rawTouches.map { t in
            TouchPoint(id: t.id, state: t.state, x: Double(t.x), y: Double(t.y), vx: Double(t.vx), vy: Double(t.vy),
                       pressure: smoothed[t.id] ?? Double(t.pressure), rawPressure: Double(t.pressure),
                       total: Double(t.total), density: Double(t.density), major: Double(t.majorAxis),
                       minor: Double(t.minorAxis), angle: Double(t.angle))
        }
        let maxP = points.map(\.pressure).max() ?? 0
        pressureRing.append(Sample(t: now, v: maxP))
        if !points.isEmpty { lastTouchActive = now }
        // Idle trackpad: stop updating once the graph has scrolled flat (no redraws at all).
        if needed(.touch) && (now - lastTouchActive <= cfg.historySeconds + 0.3 || hapticFires != touch.hapticFires || touch.now == 0) {
            let history = pressureRing.suffix(since: t0) { $0.t }
            touch = TouchSnap(now: now, touches: points, pressureHistory: history,
                              peakPressure: history.map(\.v).max() ?? 0, hapticFires: hapticFires)
        }
        if m.lastTap == 0 { m.lastTap = -100 }
        m.now = now
        // Graphs need every tick; scalar-only views (lid, light, temps) only when a value changed.
        let scalars = MotionScalars(m)
        if wantMotion || scalars != lastScalars {
            motion = m
            lastScalars = scalars
        }

        if var orient { orient.now = now; orientation = orient }
        if wantRaw { cma = cmaList; self.cmaCount = cmaCount }

        // keyboard (only while a keyboard view is on screen, and only while something is moving)
        let keysActive = !pressed.isEmpty || now - lastKeyActivity <= max(cfg.rhythmSeconds, cfg.keyFade) + 0.3
        if wantKeys && (keysActive || strokes.count != keys.total || keys.now == 0) {
        var k = KeySnap(pressed: pressed, strokes: strokes.filter { now - $0.down < max(cfg.rhythmSeconds, 10) || $0.up == nil },
                        counts: counts, lastUp: lastUp, total: strokes.count)
        k.now = now
        for (code, n) in holdN where n > 0 { k.avgHold[code] = (holdSum[code] ?? 0) / Double(n) }
        let recent = strokes.suffix(60)
        let holds = recent.compactMap { s in s.up.map { $0 - s.down } }
        k.meanHold = holds.isEmpty ? nil : holds.reduce(0, +) / Double(holds.count)
        let pairs = zip(recent.dropLast(), recent.dropFirst())
        let gaps = pairs.compactMap { a, b -> Double? in
            guard let up = a.up, b.down - a.down < 2 else { return nil }
            return b.down - up    // negative = the next key went down before this one came up
        }
        k.meanGap = gaps.isEmpty ? nil : gaps.reduce(0, +) / Double(gaps.count)
        let typed = strokes.filter { now - $0.down < 10 && !KeyLayout.modifiers.contains($0.code) }.count
        k.wpm = Double(typed) / 5 * 6
        keys = k
        }

        // raw streams (only while the Raw page is open, at most 10 updates/s: nobody reads hex faster)
        if wantRaw && now - lastRawPublish >= 0.1 { lastRawPublish = now; raw = rawStreams.values.sorted { ($0.page, $0.usage) < ($1.page, $1.usage) }.map { s in
            RawStreamInfo(id: SPU.key(s.page, s.usage), page: s.page, usage: s.usage,
                          hz: s.interval > 0 ? 1 / s.interval : 0, count: s.count, bytes: s.last,
                          hot: s.changedAt.map { now - $0 < 0.5 })
        } }
        self.events = events
        self.eventCount = eventCount

        // rates once a second
        if now - rateT >= 1 {
            let dt = now - rateT
            if rateT > 0 {
                var st = status
                st.touchHz = (Double(frames.0 - rateFrames.0) / dt).rounded()
                st.accelHz = (Double(frames.1 - rateFrames.1) / dt).rounded()
                st.gyroHz = (Double(frames.2 - rateFrames.2) / dt).rounded()
                st.devmotionFrames = devFrames
                if st != status { status = st }   // views redraw only on a real change
            }
            rateT = now
            rateFrames = frames
        }
        updateMenuTitle(cfg, pressure: maxP, lid: m.lid)
        if needed(.light) && now - lastLightPoll >= 0.2 {
            lastLightPoll = now
            slowQueue.async { [weak self] in
                var f = [Double](repeating: 0, count: 12)
                guard f.withUnsafeMutableBufferPointer({ sn_read_als($0.baseAddress, 12) }) == 12 else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    let t = sn_now()
                    self.lightLive = LightLive(xyz: [f[7], f[8], f[9]], lux: f[11], cct: f[10])
                    self.luxRing.append(Sample(t: t, v: f[11]))
                    self.luxHistory = self.luxRing.suffix(since: t - 120) { $0.t }
                }
            }
        }
    }

    /// Lower the cost when no window or popover is showing: tick at 2 fps and, after 3 s,
    /// stop the 100 Hz motion streams (unless the menu bar title needs the lid angle).
    private func manageVisibility(_ cfg: TweakValues) {
        var mainVisible = false, widgetVisible = false
        let forceVisible = PerfHarness.forceVisible   // load test only: count covered windows as visible
        for w in NSApp.windows where w.isVisible && (forceVisible || w.occlusionState.contains(.visible)) {
            if String(describing: type(of: w)).contains("StatusBar") { continue }
            if DesktopWidgetManager.isWidget(w) { widgetVisible = true } else { mainVisible = true }
        }
        let visible = mainVisible || widgetVisible
        if visible != anythingVisible { anythingVisible = visible }
        effectiveFPS = mainVisible ? cfg.fps : widgetVisible ? cfg.widgetFPS : 2
        let now = sn_now()
        hiddenSince = visible ? nil : (hiddenSince ?? now)
        let hiddenLong = hiddenSince.map { now - $0 > 3 } ?? false
        spuAllowed = !(cfg.pauseWhenHidden && hiddenLong)
        if dockShown != cfg.showDockIcon {
            dockShown = cfg.showDockIcon
            NSApp.setActivationPolicy(cfg.showDockIcon ? .regular : .accessory)
        }
        let widgetKey = WidgetSyncKey(cfg)
        if widgetKey != lastWidgetKey {
            lastWidgetKey = widgetKey
            DesktopWidgetManager.shared.sync(cfg)
        }
    }

    /// Start/stop the sensor-processor and orientation streams to match what is on screen.
    private func manageStreams(_ cfg: TweakValues) {
        // With the helper running, the app listens to the trackpad only for its own views and recordings.
        let wantTouch = !serviceRunning || needed(.touch) || recordingGesture || recordingLetter != nil || cfg.hapticOnPressure
        if wantTouch != touchRunning {
            if wantTouch { status.touchDevices = sn_touch_start(touchCallback, ctx) } else { sn_touch_stop() }
            touchRunning = wantTouch
        }
        let wantSPU = (spuAllowed && (needed(.spu) || needed(.motion) || needed(.raw))) || cfg.menuBarText == .lid
        if wantSPU != spuRunning {
            if wantSPU { status.spuDevices = sn_spu_start(reportCallback, ctx) } else { sn_spu_stop() }
            spuRunning = wantSPU
        }
        let wantVendor = spuAllowed && (needed(.orientation) || needed(.raw))
        if wantVendor != vendorRunning {
            if wantVendor { _ = sn_vendor_start(vendorCallback, ctx) } else { sn_vendor_stop() }
            vendorRunning = wantVendor
        }
        if status.spuActive != spuRunning { status.spuActive = spuRunning }
        if status.orientationActive != vendorRunning { status.orientationActive = vendorRunning }
    }

    private func updateMenuTitle(_ cfg: TweakValues, pressure: Double, lid: Int) {
        let title: String
        switch cfg.menuBarText {
        case .none: title = ""
        case .chipTemp:
            let hottest = slow.groups.filter { $0.name.hasPrefix("Chip") }.map(\.max).max()
            title = hottest.map { cfg.fahrenheit ? "\(Int($0 * 9 / 5 + 32))°F" : "\(Int($0))°" } ?? ""
        case .batteryPercent: title = slow.battery.map { "\($0.percent)%" } ?? ""
        case .batteryWatts:
            title = slow.battery.map { String(format: "%.1fW", Double($0.voltage_mV) * Double($0.amperage_mA) / 1e6) } ?? ""
        case .lid: title = lid >= 0 ? "\(lid)°" : ""
        case .pressure: title = "\(Int(pressure))"
        }
        if title != menuTitle { menuTitle = title }
    }

    // MARK: No Sleep (wraps /usr/bin/caffeinate)

    func setNoSleep(_ on: Bool) {
        if on { startCaffeinate() } else { caffeinate?.terminate() }
    }

    private func startCaffeinate() {
        caffeinate?.terminate()
        let c = tweaks.v
        var flags = (c.caffDisplay ? "d" : "") + (c.caffIdle ? "i" : "") + (c.caffSystem ? "s" : "")
        if flags.isEmpty { flags = "i" }
        // -w: caffeinate exits by itself if Sensorium quits or crashes, so the Mac can't get stuck awake.
        var args = ["-" + flags, "-w", String(ProcessInfo.processInfo.processIdentifier)]
        if c.caffMinutes > 0 { args += ["-t", String(Int(c.caffMinutes * 60))] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = args
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, self.caffeinate === proc else { return }
                self.caffeinate = nil
                self.noSleep = false
                self.noSleepSince = nil
                self.noSleepUntil = nil
            }
        }
        do {
            try p.run()
            caffeinate = p
            noSleep = true
            noSleepError = nil
            noSleepSince = Date()
            noSleepUntil = c.caffMinutes > 0 ? Date().addingTimeInterval(c.caffMinutes * 60) : nil
            noSleepCommand = "caffeinate " + args.joined(separator: " ")
        } catch {
            noSleepError = error.localizedDescription
        }
    }

    // MARK: slow sensors (background queue)

    func pollSlow() {
        now = sn_now()
        let helper = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == SharedConfig.helperBundleID }
        if (helper != nil) != serviceRunning { serviceRunning = helper != nil }
        if let pid = helper?.processIdentifier, needed(.service), let u = ServiceManager.usage(pid: pid) {
            if let last = lastServiceCPU, now > last.1 {
                serviceStats = (cpu: (u.cpuSeconds - last.0) / (now - last.1) * 100, mb: u.footprintMB)
            }
            lastServiceCPU = (u.cpuSeconds, now)
        }   // coarse clock for 1 Hz things ("2.3 s ago"); live views use their snapshot's own time
        let p = perfMeter.sampleProcess()
        proc = p
        procHistory.append(p)
        if procHistory.count > 300 { procHistory.removeFirst(procHistory.count - 300) }
        if needed(.perf) { system = perfMeter.sampleSystem() }
        // Each read is a request to the system (63 temperature sensors = 63 requests), so read
        // only what something on screen shows; the menu bar text alone refreshes every 5 s.
        let cfg = tweaks.v, t = sn_now()
        let titleDue = t - lastTitlePoll >= 5
        let wantTemps = needed(.temps) || (cfg.menuBarText == .chipTemp && titleDue)
        let wantBattery = needed(.battery) || ([.batteryPercent, .batteryWatts].contains(cfg.menuBarText) && titleDue)
        let wantRails = needed(.battery) && cfg.showPowerRails
        let wantLight = needed(.spu)
        let wantIM = needed(.keys) && t - lastIMPoll >= 5
        if titleDue { lastTitlePoll = t }
        if wantIM { lastIMPoll = t }
        guard wantTemps || wantBattery || wantLight || wantIM else { return }
        let previous = slow
        slowQueue.async { [weak self] in
            let temps: [Reading]? = wantTemps ? Self.read(0xFF00, 5, 15) : nil
            let currents = wantRails ? Self.read(0xFF08, 2, 25) : previous.currents
            let voltages = wantRails ? Self.read(0xFF08, 3, 25) : previous.voltages
            var als: [Double]?
            if wantLight {
                var f = [Double](repeating: 0, count: 12)
                als = f.withUnsafeMutableBufferPointer { sn_read_als($0.baseAddress, 12) } == 12 ? f : nil
            }
            let battery: SNBattery? = wantBattery ? sn_battery() : nil
            let im: Int32? = wantIM ? sn_input_monitoring_status() : nil
            DispatchQueue.main.async { self?.applySlow(temps, currents, voltages, als, battery, im) }
        }
    }

    private static func read(_ page: Int32, _ usage: Int32, _ type: Int64) -> [Reading] {
        var buf = [SNReading](repeating: SNReading(), count: 256)
        let n = buf.withUnsafeMutableBufferPointer { sn_read_sensors(page, usage, type, $0.baseAddress, 256) }
        return (0..<Int(n)).map { Reading(id: $0, name: cName(buf[$0]), value: buf[$0].value) }
    }

    static func groupName(_ sensor: String) -> String {
        if sensor.hasPrefix("PMU tdie") { return "Chip die" }
        if sensor.hasPrefix("PMU tdev") { return "Chip devices" }
        if sensor.hasPrefix("PMU TP") { return "Power stages" }
        if sensor.hasPrefix("PMU tcal") { return "PMU calibration" }
        if sensor.lowercased().contains("battery") { return "Battery" }
        if sensor.contains("NAND") { return "SSD (NAND)" }
        return "Other"
    }

    private func applySlow(_ tempsIn: [Reading]?, _ currents: [Reading], _ voltages: [Reading],
                           _ alsIn: [Double]?, _ batteryIn: SNBattery?, _ im: Int32?) {
        // Keep the last values for anything not read this round.
        let als = alsIn
        let battery = batteryIn.map { $0.valid ? $0 : nil } ?? slow.battery
        guard let temps = tempsIn else {
            var s2 = slow
            s2.t = sn_now()
            if let alsIn { s2.alsEvent = alsIn[11]; s2.alsXYZ = [alsIn[7], alsIn[8], alsIn[9]]; s2.alsChannels = Array(alsIn[1...4]) }
            s2.battery = battery
            s2.currents = currents
            s2.voltages = voltages
            slow = s2
            if let im, status.inputMonitoring != im { status.inputMonitoring = im }
            return
        }
        let now = sn_now()
        let window = max(60, tweaks.v.historySeconds * 10)
        var groups: [TempGroup] = []
        for (name, rs) in Dictionary(grouping: temps.filter { $0.value > -50 && $0.value < 150 }, by: { Self.groupName($0.name) }) {
            let vals = rs.map(\.value)
            var g = TempGroup(name: name, readings: rs.sorted { $0.value > $1.value },
                              min: vals.min() ?? 0, avg: vals.reduce(0, +) / Double(max(1, vals.count)), max: vals.max() ?? 0)
            var ring = tempRings[name] ?? Ring<Sample>(600)
            ring.append(Sample(t: now, v: g.max))
            tempRings[name] = ring
            g.history = ring.suffix(since: now - window) { $0.t }
            groups.append(g)
        }
        slow = SlowSnap(t: now, groups: groups.sorted { $0.max > $1.max },
                        currents: currents.sorted { $0.value > $1.value },
                        voltages: voltages.sorted { $0.value > $1.value },
                        alsEvent: als?[11] ?? slow.alsEvent, alsXYZ: als.map { [$0[7], $0[8], $0[9]] } ?? slow.alsXYZ,
                        alsChannels: als.map { Array($0[1...4]) } ?? slow.alsChannels, battery: battery)
        if let im, status.inputMonitoring != im { status.inputMonitoring = im }
    }

    // MARK: trackpad gestures

    private func setUpGestures() {
        gestureEngine.update(tweaks.v.gestures)
        appliedGestures = tweaks.v.gestures
        gestureEngine.onControl = { [weak self] target, delta in
            guard self?.serviceRunning != true else { return }   // the helper is doing it
            SystemControls.nudge(target, by: delta, hud: Tweaks.shared.v.gestures.showHUD)
        }
        gestureEngine.onEvent = { [weak self] e in self?.handle(e) }
        TaskRunner.toggleNoSleep = { [weak self] in guard let self else { return }; self.setNoSleep(!self.noSleep) }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: SharedConfig.gestureEvent, object: nil, queue: .main) { [weak self] n in
            guard let self, let info = n.userInfo else { return }
            if let text = info["text"] as? String {
                let task = (info["task"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                self.recentGestures.insert(RecentGesture(pattern: GesturePattern(kind: .tap, fingers: 0), task: task, label: text), at: 0)
                if self.recentGestures.count > 10 { self.recentGestures.removeLast() }
            }
            if let result = info["result"] as? String {
                self.taskLog.insert("\(Date().formatted(date: .omitted, time: .standard))  \(result)", at: 0)
                if self.taskLog.count > 12 { self.taskLog.removeLast() }
            }
        }
        dnc.addObserver(forName: SharedConfig.armedChanged, object: nil, queue: .main) { [weak self] n in
            self?.gesturesArmed = (n.userInfo?["armed"] as? Bool) ?? false
        }
        seedFinderClaude()
    }

    private func recordingChanged() {
        let on = recordingGesture || recordingLetter != nil
        gestureEngine.recording = on
        SharedConfig.post(SharedConfig.pauseHelper, ["paused": on])   // the helper must not act on a recording
    }

    /// One-time: "draw C in Finder → Terminal in that folder running cc". Two synthetic C samples
    /// (record your own C on the Gestures page to make it match your handwriting even better).
    private func seedFinderClaude() {
        let flag = "sensorium.seeded.finderC"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        var g = tweaks.v.gestures
        let task = UserTask(name: "Claude Code here", actions: [TaskAction(kind: .terminalHere, text: "cc")])
        g.tasks.append(task)
        for (from, to, width) in [(45.0, 315.0, 0.8), (60.0, 300.0, 0.7)] {
            let pts = stride(from: from, through: to, by: 5).map { deg -> CGPoint in
                let a = deg * .pi / 180
                return CGPoint(x: cos(a) * width, y: -sin(a))   // display coords (y down): starts top right, counter-clockwise
            }
            if let t = LetterRecognizer.template(name: "C", from: pts) { g.letters.append(t) }
        }
        g.bindings.append(GestureBinding(pattern: GesturePattern(kind: .letter, fingers: 1, letter: "C"),
                                         taskID: task.id, onlyInApp: "Finder", noArming: true))
        tweaks.v.gestures = g
        UserDefaults.standard.set(true, forKey: flag)
    }

    private func handle(_ e: GestureEvent) {
        switch e {
        case .arm(let on):
            if serviceRunning { return }   // the helper shows its own indicator and tells us
            gesturesArmed = on
            if on {
                HUD.shared.message("hand.draw.fill", "Gestures armed")
                _ = sn_haptic_fire(3, 0, 0)
                armTimer?.invalidate()
                let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.gestureEngine.checkTimeout(now: sn_now()) }
                RunLoop.main.add(t, forMode: .common)
                armTimer = t
            } else {
                HUD.shared.message("hand.raised.slash", "Gestures off")
                armTimer?.invalidate()
                armTimer = nil
            }
        case .stroke(let pts, let fallback):
            lastStroke = pts
            if let name = recordingLetter {
                if let t = LetterRecognizer.template(name: name, from: pts) { tweaks.v.gestures.letters.append(t) }
                recordingLetter = nil
                return
            }
            if let (name, score) = LetterRecognizer.recognize(pts, tweaks.v.gestures.letters) {
                lastLetterScore = (name, score)
                if score >= tweaks.v.gestures.letterThreshold(armed: gestureEngine.armed) || recordingGesture {
                    handle(.pattern(GesturePattern(kind: .letter, fingers: 1, letter: name)))
                    return
                }
            }
            if let fallback { handle(.pattern(fallback)) }
        case .pattern(let p):
            if recordingGesture {
                recordedPattern = p
                recordingGesture = false
                return
            }
            guard !serviceRunning else { return }   // the background helper runs tasks and reports them
            let task = tweaks.v.gestures.task(for: p, armed: gestureEngine.armed,
                                              frontApp: NSWorkspace.shared.frontmostApplication?.localizedName)
            recentGestures.insert(RecentGesture(pattern: p, task: task?.name), at: 0)
            if recentGestures.count > 10 { recentGestures.removeLast() }
            if let task { runTask(task) }
        }
    }

    func setGesturesArmed(_ on: Bool) {
        gestureEngine.setArmed(on, now: sn_now())
        handle(.arm(on))
    }

    func runTask(_ task: UserTask) {
        if tweaks.v.gestures.hapticOnTask { _ = sn_haptic_fire(3, 0, 0) }
        TaskRunner.run(task) { [weak self] result in
            guard let self else { return }
            self.taskLog.insert("\(Date().formatted(date: .omitted, time: .standard))  \(result)", at: 0)
            if self.taskLog.count > 12 { self.taskLog.removeLast() }
        }
    }

    // MARK: system-wide keys

    private func updateGlobalKeys() {
        releaseAll()
        if globalWanted {
            let r = sn_keys_start(keyCallback, ctx)
            status.globalKeysActive = r == 0
            status.globalKeysError = r
        } else {
            sn_keys_stop()
            status.globalKeysActive = false
            status.globalKeysError = 0
        }
    }

    func requestInputMonitoring() {
        _ = sn_input_monitoring_request()
        status.inputMonitoring = sn_input_monitoring_status()
    }

    // MARK: haptics

    func fireHaptic(id: Int? = nil) {
        let c = tweaks.v
        lastHapticResult = sn_haptic_fire(Int32(id ?? c.hapticID), Float(c.hapticArg1), Float(c.hapticArg2))
    }

    private func updateMetronome() {
        metronome?.invalidate()
        metronome = nil
        guard metronomeOn else { return }
        schedule(&metronome, every: 60 / max(20, metronomeBPM)) { [weak self] in self?.fireHaptic() }
    }

    // MARK: Touch ID (public LocalAuthentication; no fingerprint data is ever exposed)

    func checkBiometry() {
        let ctx = LAContext()
        var err: NSError?
        let can = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        let kind: String
        switch ctx.biometryType {
        case .touchID: kind = "Touch ID"
        case .faceID: kind = "Face ID"
        case .opticID: kind = "Optic ID"
        default: kind = "none"
        }
        biometryReady = can
        biometry = can ? "\(kind) ready (at least one finger enrolled)"
                       : "\(kind): \(err?.localizedDescription ?? "not available")"
    }

    func testTouchID() {
        guard !authRunning else { return }
        authRunning = true
        let started = Date()
        LAContext().evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                   localizedReason: "test the fingerprint sensor") { ok, err in
            DispatchQueue.main.async {
                self.authRunning = false
                let msg = ok ? "matched an enrolled finger" : (err?.localizedDescription ?? "failed")
                self.authAttempts.insert(AuthAttempt(ok: ok, seconds: Date().timeIntervalSince(started), message: msg), at: 0)
                if self.authAttempts.count > 12 { self.authAttempts.removeLast() }
            }
        }
    }
}

/// The widget-related settings; the panels are re-synced only when these change.
struct WidgetSyncKey: Equatable {
    var widgets: [DesktopWidgetConfig], shown: Bool, level: WidgetLevel, opacity: Double, locked: Bool, clickThrough: Bool
    init(_ c: TweakValues) {
        widgets = c.desktopWidgets; shown = c.widgetsShown; level = c.widgetLevel
        opacity = c.widgetOpacity; locked = c.widgetsLocked; clickThrough = c.widgetsClickThrough
    }
}

enum Need: Hashable { case touch, spu, motion, orientation, keys, raw, perf, temps, battery, light, service }

struct OrientationSnap {
    var now = 0.0
    var quat: (x: Double, y: Double, z: Double, w: Double)?
    var rotRate: (Double, Double, Double)?
    var userAccel: (Double, Double, Double)?
    var history: [Vec3] = []
}

enum Orientation {
    /// Roll / pitch / yaw in degrees from a unit quaternion (ZYX convention).
    static func euler(x: Double, y: Double, z: Double, w: Double) -> (roll: Double, pitch: Double, yaw: Double) {
        let roll = atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))
        let pitch = asin(max(-1, min(1, 2 * (w * y - z * x))))
        let yaw = atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
        return (roll * 180 / .pi, pitch * 180 / .pi, yaw * 180 / .pi)
    }
}

/// The slow-changing motion values; scalar-only views redraw only when one of these changes.
struct MotionScalars: Equatable {
    var lid: Int, lux: Int, cct: Int, imuTemp: Int, alsTemp: Int, taps: Int
    init(_ m: MotionSnap) {
        lid = m.lid
        lux = Int((m.light.lux ?? -1) * 10)
        cct = Int(m.light.cct ?? -1)
        imuTemp = Int((m.imuTemp ?? -100) * 10)
        alsTemp = Int((m.alsTemp ?? -100) * 10)
        taps = m.taps
    }
}

struct RecentGesture: Identifiable {
    var id = UUID()
    var at = Date()
    var pattern: GesturePattern
    var task: String?
    var label: String?          // text sent by the background helper
    var text: String { label ?? pattern.text }
}

struct LightLive {
    var xyz: [Double]
    var lux: Double
    var cct: Double
}
