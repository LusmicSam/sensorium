import AppKit
import CSensors
import Foundation

// MARK: - Model (saved inside TweakValues)

public enum GestureKind: String, Codable, CaseIterable { case tap, swipe, press, hold, letter, rhythm }
public enum SwipeDir: String, Codable, CaseIterable { case up, down, left, right }
public enum ContactShape: String, Codable, CaseIterable { case point = "fingertip", flat = "flat finger" }

/// A finger pattern on the trackpad. nil fields mean "any".
public struct GesturePattern: Codable, Equatable, Hashable {
    public init(kind: GestureKind, fingers: Int, taps: Int = 1, direction: SwipeDir? = nil, region: String? = nil,
                letter: String? = nil, rhythm: String? = nil, contact: ContactShape? = nil) {
        self.kind = kind; self.fingers = fingers; self.taps = taps; self.direction = direction
        self.region = region; self.letter = letter; self.rhythm = rhythm; self.contact = contact
    }
    public var kind: GestureKind
    public var fingers: Int
    public var taps = 1
    public var direction: SwipeDir?
    public var region: String?
    public var letter: String?
    public var rhythm: String?          // gaps between taps: S = short, L = long, e.g. "SLS"
    public var contact: ContactShape?

    public func matches(_ p: GesturePattern) -> Bool {
        kind == p.kind && (kind == .letter || fingers == p.fingers)
            && (kind != .tap || taps == p.taps)
            && (kind != .swipe || direction == p.direction)
            && (kind != .letter || letter == p.letter)
            && (kind != .rhythm || rhythm == p.rhythm)
            && (region == nil || region == p.region)
            && (contact == nil || contact == p.contact)
    }

    public var text: String {
        let f = "\(fingers)-finger"
        var s: String
        switch kind {
        case .tap: s = "\(f) " + ["", "tap", "double tap", "triple tap"][min(3, max(1, taps))]
        case .swipe: s = "\(f) swipe \(direction?.rawValue ?? "?")"
        case .press: s = "\(f) hard press"
        case .hold: s = "\(f) hold"
        case .letter: s = "draw “\(letter ?? "?")”"
        case .rhythm: s = "\(f) tap rhythm " + (rhythm ?? "").map { $0 == "S" ? "• " : "•  —  " }.joined() + "•"
        }
        if let contact, kind != .letter { s += " (\(contact.rawValue))" }
        return s + (region.map { " in \($0)" } ?? " anywhere")
    }
}

public enum ControlTarget: String, Codable, CaseIterable, Identifiable {
    case brightness = "Brightness", volume = "Volume"
    public var id: String { rawValue }
    public var icon: String { self == .brightness ? "sun.max.fill" : "speaker.wave.2.fill" }
}

public enum ControlAxis: String, Codable, CaseIterable, Identifiable {
    case vertical = "Slide up / down", horizontal = "Slide left / right"
    public var id: String { rawValue }
}

/// A region of the pad that works as a slider for brightness or volume.
public struct SliderControl: Codable, Equatable, Identifiable {
    public init(region: String, fingers: Int = 1, axis: ControlAxis = .vertical, target: ControlTarget, sensitivity: Double = 1.5) {
        self.region = region; self.fingers = fingers; self.axis = axis; self.target = target; self.sensitivity = sensitivity
    }
    public var id = UUID()
    public var region: String
    public var fingers = 1
    public var axis: ControlAxis = .vertical
    public var target: ControlTarget
    public var sensitivity = 1.5      // full range per (1 / sensitivity) of the pad
    public var enabled = true
}

public enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case openApp = "Open an app", open = "Open a file, folder or web address", shell = "Run a shell command"
    case brightnessUp = "Brightness up", brightnessDown = "Brightness down"
    case volumeUp = "Volume up", volumeDown = "Volume down", mute = "Mute / unmute"
    case noSleep = "Toggle No Sleep", haptic = "Haptic tap", shortcut = "Keyboard shortcut (needs Accessibility)"
    case wait = "Wait"
    case terminalHere = "Open Terminal in the front Finder folder and run…"
    public var id: String { rawValue }
    public var usesText: Bool { [.openApp, .open, .shell, .shortcut, .terminalHere].contains(self) }
    public var usesAmount: Bool { [.brightnessUp, .brightnessDown, .volumeUp, .volumeDown, .wait].contains(self) }
    public var icon: String {
        switch self {
        case .openApp: return "app.badge"
        case .open: return "folder"
        case .shell: return "terminal"
        case .brightnessUp, .brightnessDown: return "sun.max"
        case .volumeUp, .volumeDown: return "speaker.wave.2"
        case .mute: return "speaker.slash"
        case .noSleep: return "cup.and.saucer"
        case .haptic: return "waveform"
        case .shortcut: return "command"
        case .wait: return "hourglass"
        case .terminalHere: return "apple.terminal"
        }
    }
}

public struct TaskAction: Codable, Equatable, Identifiable {
    public init(kind: ActionKind, text: String = "", amount: Double = 0.1) { self.kind = kind; self.text = text; self.amount = amount }
    public var id = UUID()
    public var kind: ActionKind
    public var text = ""          // app path, file/URL, shell command or shortcut like "cmd+shift+4"
    public var amount = 0.1       // step for brightness/volume, seconds for wait
}

public struct UserTask: Codable, Equatable, Identifiable {
    public init(name: String, actions: [TaskAction] = []) { self.name = name; self.actions = actions }
    public var id = UUID()
    public var name: String
    public var actions: [TaskAction] = []
}

public struct GestureBinding: Codable, Equatable, Identifiable {
    public init(pattern: GesturePattern, taskID: UUID? = nil, onlyInApp: String? = nil, noArming: Bool? = nil) {
        self.pattern = pattern; self.taskID = taskID; self.onlyInApp = onlyInApp; self.noArming = noArming
    }
    public var id = UUID()
    public var pattern: GesturePattern
    public var taskID: UUID?
    public var enabled = true
    public var onlyInApp: String?     // e.g. "Finder": fires only while that app is in front
    public var noArming: Bool?        // true: works without arming (best combined with onlyInApp)
}

/// A user-drawn letter, stored as 48 normalized points.
public struct LetterTemplate: Codable, Equatable, Identifiable {
    public init(name: String, points: [[Double]]) { self.name = name; self.points = points }
    public var id = UUID()
    public var name: String
    public var points: [[Double]]
}

public enum ArmMode: String, Codable, CaseIterable, Identifiable {
    case always = "Always on", armed = "Arm first (hold a corner)"
    public var id: String { rawValue }
}

public enum PadCorner: String, Codable, CaseIterable, Identifiable {
    case topLeft = "Top left", topRight = "Top right", bottomLeft = "Bottom left", bottomRight = "Bottom right"
    public var id: String { rawValue }
    /// Corner rectangle in display coordinates (x right, y down).
    public func contains(x: Double, y: Double, size s: Double) -> Bool {
        switch self {
        case .topLeft: return x < s && y < s
        case .topRight: return x > 1 - s && y < s
        case .bottomLeft: return x < s && y > 1 - s
        case .bottomRight: return x > 1 - s && y > 1 - s
        }
    }
}

public struct GestureConfig: Codable, Equatable {
    public init() {}
    public var enabled = true
    public var showHUD = true
    public var hapticOnTask = true
    public var xDividers: [Double] = [0.12, 0.88]   // vertical lines (fractions of the pad width)
    public var yDividers: [Double] = []             // horizontal lines (fractions of the height, from the top)
    public var sliders: [SliderControl] = [SliderControl(region: "A1", target: .brightness),
                                    SliderControl(region: "C1", target: .volume)]
    public var bindings: [GestureBinding] = []
    public var tasks: [UserTask] = [UserTask(name: "Open Finder", actions: [TaskAction(kind: .openApp, text: "/System/Library/CoreServices/Finder.app")])]
    public var letters: [LetterTemplate] = []
    // arming
    public var armMode: ArmMode = .armed
    public var armCorner: PadCorner = .topRight
    public var armCornerSize = 0.15
    public var armHoldSeconds = 0.6
    public var armTimeout = 12.0
    public var slidersAlwaysOn = true
    // recognition tuning
    public var tapMaxSeconds = 0.25
    public var multiTapGap = 0.3
    public var swipeMinDistance = 0.15
    public var pressThreshold = 700.0
    public var palmMaxMM = 13.0
    public var flatRatio = 1.45          // contact length ÷ width above this = flat finger
    public var letterMinLength = 0.15
    public var letterThreshold = 0.78

    /// Region name for a point in display coordinates (x right, y down, 0..1): columns A, B, C…, rows 1, 2…
    public func region(x: Double, y: Double) -> String {
        var col = 0, row = 0
        for d in xDividers where x >= d { col += 1 }
        for d in yDividers where y >= d { row += 1 }
        return "\(Character(UnicodeScalar(65 + min(col, 25))!))\(row + 1)"
    }

    public var regionNames: [String] {
        let cols = xDividers.count + 1, rows = yDividers.count + 1
        return (0..<rows).flatMap { r in (0..<cols).map { c in "\(Character(UnicodeScalar(65 + min(c, 25))!))\(r + 1)" } }
    }

    public var wantsRhythm: Bool { bindings.contains { $0.pattern.kind == .rhythm } }
    public var hasUnarmedBindings: Bool { bindings.contains { $0.enabled && $0.noArming == true } }

    /// The task a recognized pattern should run, honouring arming and "only in app" conditions.
    public func task(for p: GesturePattern, armed: Bool, frontApp: String?) -> UserTask? {
        let live = armMode == .always || armed
        for b in bindings where b.enabled && b.pattern.matches(p) {
            if !live && b.noArming != true { continue }
            if let app = b.onlyInApp, app != frontApp { continue }
            if let t = tasks.first(where: { $0.id == b.taskID }) { return t }
        }
        return nil
    }

    /// Letters drawn without arming must match more closely (ordinary cursor moves are curves too).
    public func letterThreshold(armed: Bool) -> Double {
        armMode == .always || armed ? letterThreshold : max(letterThreshold, 0.86)
    }
}

public enum GestureEvent {
    case pattern(GesturePattern)
    case stroke([CGPoint], fallback: GesturePattern?)   // a one-finger drawing (letter candidate)
    case arm(Bool)
}

// MARK: - Recognizer (runs on the trackpad callback thread)

public final class GestureEngine {
    public init() {}
    private let lock = NSLock()
    private var cfg = GestureConfig()
    public var recording = false                                   // collect rhythms/letters even if nothing is bound
    public var onEvent: ((GestureEvent) -> Void)?                  // delivered on the main thread
    public var onControl: ((ControlTarget, Double) -> Void)?       // delta, called on the touch thread

    public private(set) var armed = false
    private var lastActivity = 0.0
    private var active = false
    private var consumed = false                            // this touch already did something (arming)
    private var start = (x: 0.0, y: 0.0, t: 0.0)
    private var last = (x: 0.0, y: 0.0)
    private var startRegion = ""
    private var startsInArmCorner = false
    private var maxFingers = 0
    private var maxPressure = 0.0
    private var maxElongation = 0.0
    private var pathLength = 0.0
    private var points: [CGPoint] = { var a = [CGPoint](); a.reserveCapacity(512); return a }()
    private var slider: SliderControl?
    private var sliderDecided = false
    private var tapStarts: [Double] = []
    private var tapPattern: GesturePattern?
    private var tapToken = 0

    public func update(_ c: GestureConfig) { lock.lock(); cfg = c; lock.unlock() }

    /// Disarm after the timeout. Called by the hub about once a second while armed.
    public func checkTimeout(now: Double) {
        lock.lock()
        let expire = armed && !active && now - lastActivity > cfg.armTimeout
        if expire { armed = false }
        lock.unlock()
        if expire { DispatchQueue.main.async { self.onEvent?(.arm(false)) } }
    }

    public func setArmed(_ on: Bool, now: Double) { lock.lock(); armed = on; lastActivity = now; lock.unlock() }

    /// One trackpad frame, read in place (no copies, no allocations: this runs ~100x/s while you touch).
    public func process(_ touches: UnsafeBufferPointer<SNTouch>, t: Double) {
        lock.lock()
        var event: GestureEvent?
        var control: (ControlTarget, Double)?
        defer {
            lock.unlock()
            if let control { onControl?(control.0, control.1) }
            if let event { DispatchQueue.main.async { self.onEvent?(event) } }
        }
        guard cfg.enabled else { active = false; return }
        var n = 0, sx = 0.0, sy = 0.0, maxP = 0.0, elong = 0.0
        let palm = Float(cfg.palmMaxMM)
        for f in touches where f.state >= 1 && f.state <= 6 && f.majorAxis <= palm {   // fingers, not palms
            n += 1
            sx += Double(f.x)
            sy += Double(f.y)
            maxP = max(maxP, Double(f.pressure))
            elong = max(elong, Double(f.majorAxis) / Double(max(f.minorAxis, 0.5)))
        }
        guard n > 0 else {
            if active { event = endSession(t) }
            return
        }
        let cx = sx / Double(n), cy = 1 - sy / Double(n)   // display y: down
        if !active {
            active = true
            consumed = false
            start = (cx, cy, t)
            last = (cx, cy)
            startRegion = cfg.region(x: cx, y: cy)
            startsInArmCorner = cfg.armMode == .armed && cfg.armCorner.contains(x: cx, y: cy, size: cfg.armCornerSize)
            maxFingers = 0
            maxPressure = 0
            maxElongation = 0
            pathLength = 0
            points.removeAll(keepingCapacity: true)
            slider = nil
            sliderDecided = false
        }
        maxFingers = max(maxFingers, n)
        maxPressure = max(maxPressure, maxP)
        maxElongation = max(maxElongation, elong)
        let step = ((cx - last.x) * (cx - last.x) + (cy - last.y) * (cy - last.y)).squareRoot()
        pathLength += step
        if n == 1 && points.count < 512 { points.append(CGPoint(x: cx, y: cy)) }

        // Arming: hold still in the arm corner.
        if startsInArmCorner && !consumed {
            let moved = ((cx - start.x) * (cx - start.x) + (cy - start.y) * (cy - start.y)).squareRoot()
            if moved > 0.04 {
                startsInArmCorner = false
            } else if t - start.t >= cfg.armHoldSeconds {
                consumed = true
                armed.toggle()
                lastActivity = t
                event = .arm(armed)
            }
        }

        // Sliders: decide once, after a little movement.
        let slidersLive = cfg.armMode == .always || armed || cfg.slidersAlwaysOn
        if !sliderDecided && !consumed && slidersLive {
            let dx = cx - start.x, dy = cy - start.y
            if (dx * dx + dy * dy).squareRoot() > 0.025 {
                sliderDecided = true
                let vertical = abs(dy) > abs(dx)
                for s in cfg.sliders where s.enabled && s.region == startRegion && s.fingers == n && (s.axis == .vertical) == vertical {
                    slider = s
                    break
                }
            }
        }
        if let s = slider, n == s.fingers {
            let delta = s.axis == .vertical ? -(cy - last.y) : (cx - last.x)   // up / right = more
            control = (s.target, delta * s.sensitivity)
        }
        last = (cx, cy)
    }

    public func process(_ touches: [SNTouch], t: Double) {
        touches.withUnsafeBufferPointer { process($0, t: t) }
    }

    private func endSession(_ t: Double) -> GestureEvent? {
        active = false
        if slider != nil || consumed { return nil }
        let live = cfg.armMode == .always || armed || recording || cfg.hasUnarmedBindings
        guard live else { return nil }
        lastActivity = t
        let dx = last.x - start.x, dy = last.y - start.y
        let dist = (dx * dx + dy * dy).squareRoot(), dur = t - start.t
        let fingers = min(5, maxFingers)
        let contact: ContactShape = maxElongation >= cfg.flatRatio ? .flat : .point

        var swipe: GesturePattern?
        if dist >= cfg.swipeMinDistance {
            let dir: SwipeDir = abs(dx) > abs(dy) ? (dx > 0 ? .right : .left) : (dy > 0 ? .down : .up)
            swipe = GesturePattern(kind: .swipe, fingers: fingers, direction: dir, region: startRegion)
        }
        // One-finger drawing: let the main thread try it as a letter (or fall back to the swipe).
        if fingers == 1 && pathLength >= cfg.letterMinLength && points.count >= 8 && (!cfg.letters.isEmpty || recording) {
            return .stroke(points, fallback: swipe)
        }
        if let swipe { return .pattern(swipe) }
        if maxPressure >= cfg.pressThreshold && dist < 0.05 {
            return .pattern(GesturePattern(kind: .press, fingers: fingers, region: startRegion, contact: contact))
        }
        if dur <= cfg.tapMaxSeconds && dist < 0.04 {
            collectTap(GesturePattern(kind: .tap, fingers: fingers, region: startRegion, contact: contact), at: start.t)
            return nil
        }
        if dur >= 0.6 && dist < 0.04 {
            return .pattern(GesturePattern(kind: .hold, fingers: fingers, region: startRegion, contact: contact))
        }
        return nil
    }

    /// Quick repeats become double/triple taps; with rhythms in use, longer pauses form a rhythm.
    private func collectTap(_ p: GesturePattern, at t: Double) {
        let rhythm = cfg.wantsRhythm || recording
        let window = rhythm ? 1.0 : cfg.multiTapGap + cfg.tapMaxSeconds
        if let prev = tapPattern, prev == p, let lastStart = tapStarts.last, t - lastStart <= window, tapStarts.count < 8 {
            tapStarts.append(t)
        } else {
            flushLocked()
            tapPattern = p
            tapStarts = [t]
        }
        tapToken += 1
        let token = tapToken
        DispatchQueue.main.asyncAfter(deadline: .now() + (rhythm ? 0.9 : cfg.multiTapGap)) { [weak self] in self?.flush(token) }
    }

    private func flush(_ token: Int) {
        lock.lock()
        if token == tapToken { flushLocked() }
        lock.unlock()
    }

    /// Turns the collected taps into one event and always delivers it asynchronously on the main thread
    /// (the same way whichever thread got here, so no event can be dropped).
    private func flushLocked() {
        guard var p = tapPattern, !tapStarts.isEmpty else { return }
        let gaps = zip(tapStarts, tapStarts.dropFirst()).map { $1 - $0 }
        tapPattern = nil
        tapStarts = []
        let rhythm = cfg.wantsRhythm || recording
        if rhythm && (gaps.count >= 3 || gaps.contains { $0 > 0.35 }) {
            p.kind = .rhythm
            p.rhythm = gaps.map { $0 > 0.35 ? "L" : "S" }.joined()
        } else {
            p.taps = min(3, gaps.count + 1)
        }
        let e = GestureEvent.pattern(p)
        DispatchQueue.main.async { self.onEvent?(e) }
    }
}

// MARK: - Letters ($1-style template matching, orientation kept so N ≠ Z)

public enum LetterRecognizer {
    public static let count = 48

    public static func normalize(_ pts: [CGPoint]) -> [CGPoint]? {
        guard pts.count >= 4 else { return nil }
        let r = resample(pts)
        let xs = r.map(\.x), ys = r.map(\.y)
        let size = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        guard size > 1e-6 else { return nil }
        let cx = xs.reduce(0, +) / CGFloat(r.count), cy = ys.reduce(0, +) / CGFloat(r.count)
        return r.map { CGPoint(x: ($0.x - cx) / size, y: ($0.y - cy) / size) }
    }

    public static func resample(_ pts: [CGPoint]) -> [CGPoint] {
        var length: CGFloat = 0
        for (a, b) in zip(pts, pts.dropFirst()) { length += hypot(b.x - a.x, b.y - a.y) }
        let interval = length / CGFloat(count - 1)
        guard interval > 0 else { return Array(repeating: pts[0], count: count) }
        var out = [pts[0]], d: CGFloat = 0, src = pts, i = 1
        while i < src.count {
            let a = src[i - 1], b = src[i], seg = hypot(b.x - a.x, b.y - a.y)
            if d + seg >= interval {
                let k = (interval - d) / seg
                let q = CGPoint(x: a.x + k * (b.x - a.x), y: a.y + k * (b.y - a.y))
                out.append(q)
                src.insert(q, at: i)
                d = 0
            } else {
                d += seg
            }
            i += 1
        }
        while out.count < count { out.append(src.last!) }
        return Array(out.prefix(count))
    }

    public static func distance(_ a: [CGPoint], _ b: [CGPoint]) -> CGFloat {
        zip(a, b).map { hypot($0.x - $1.x, $0.y - $1.y) }.reduce(0, +) / CGFloat(a.count)
    }

    /// Best matching letter and its score (0…1).
    public static func recognize(_ pts: [CGPoint], _ templates: [LetterTemplate]) -> (String, Double)? {
        guard let c = normalize(pts) else { return nil }
        var best: (String, CGFloat)?
        for t in templates {
            let tp = t.points.map { CGPoint(x: $0[0], y: $0[1]) }
            guard tp.count == c.count else { continue }
            let d = distance(c, tp)
            if best == nil || d < best!.1 { best = (t.name, d) }
        }
        guard let best else { return nil }
        return (best.0, Double(max(0, 1 - best.1 / 0.5)))
    }

    public static func template(name: String, from pts: [CGPoint]) -> LetterTemplate? {
        normalize(pts).map { LetterTemplate(name: name, points: $0.map { [Double($0.x), Double($0.y)] }) }
    }
}

// MARK: - Controls with an on-screen indicator

public enum SystemControls {
    private static var cache: [ControlTarget: Double] = [:]
    private static let lock = NSLock()

    public static func get(_ t: ControlTarget) -> Double {
        t == .brightness ? sn_brightness_get() : sn_volume_get()
    }

    /// Adds `delta` (−1…1) to brightness or volume. Safe from any thread.
    public static func nudge(_ t: ControlTarget, by delta: Double, hud: Bool) {
        lock.lock()
        let current = cache[t] ?? get(t)
        guard current >= 0 else { lock.unlock(); return }
        let value = min(1, max(0, current + delta))
        cache[t] = value
        lock.unlock()
        if t == .brightness { _ = sn_brightness_set(value) } else { _ = sn_volume_set(value) }
        if hud { DispatchQueue.main.async { HUD.shared.show(t, value) } }
    }

    /// Forget cached values (the user may have changed them with the keyboard keys).
    public static func resync() { lock.lock(); cache = [:]; lock.unlock() }
}

// MARK: - Task runner

public enum TaskRunner {
    private static let queue = DispatchQueue(label: "sensorium.tasks")
    /// Set by whoever owns No Sleep (the app, or the background helper).
    public static var toggleNoSleep: (() -> Void)?

    /// Runs the actions in order on a background queue; reports a one-line result on the main thread.
    public static func run(_ task: UserTask, done: @escaping (String) -> Void) {
        queue.async {
            var notes: [String] = []
            for a in task.actions { notes.append(perform(a)) }
            let failed = notes.filter { $0.hasPrefix("✗") }
            DispatchQueue.main.async { done(failed.isEmpty ? "✓ \(task.name)" : "\(task.name): " + failed.joined(separator: "; ")) }
        }
    }

    private static func perform(_ a: TaskAction) -> String {
        let text = (a.text as NSString).expandingTildeInPath
        switch a.kind {
        case .openApp:
            guard FileManager.default.fileExists(atPath: text) else { return "✗ app not found: \(a.text)" }
            DispatchQueue.main.async {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: text), configuration: NSWorkspace.OpenConfiguration())
            }
        case .open:
            let url = a.text.contains("://") ? URL(string: a.text) : URL(fileURLWithPath: text)
            guard let url else { return "✗ not a valid address: \(a.text)" }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        case .shell:
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", a.text]
            do { try p.run() } catch { return "✗ command failed to start" }
        case .brightnessUp: SystemControls.nudge(.brightness, by: a.amount, hud: true)
        case .brightnessDown: SystemControls.nudge(.brightness, by: -a.amount, hud: true)
        case .volumeUp: SystemControls.nudge(.volume, by: a.amount, hud: true)
        case .volumeDown: SystemControls.nudge(.volume, by: -a.amount, hud: true)
        case .mute: _ = sn_mute_set(sn_mute_get() != 1)
        case .noSleep: DispatchQueue.main.async { toggleNoSleep?() }
        case .terminalHere:
            // AppleScript must run on the main thread; this queue is never the main one.
            let folder = DispatchQueue.main.sync { FinderTerminal.frontFinderFolder() }
            guard let folder else { return "✗ no Finder folder in front (or Finder access not allowed)" }
            guard FinderTerminal.openTerminal(at: folder, run: a.text) else { return "✗ couldn't open Terminal" }
        case .haptic: _ = sn_haptic_fire(6, 0, 0)
        case .shortcut:
            guard let (code, flags) = Shortcut.parse(a.text) else { return "✗ can't read shortcut \"\(a.text)\"" }
            if !sn_accessibility_trusted(true) { return "✗ allow Sensorium in Accessibility settings first" }
            _ = sn_post_shortcut(code, flags)
        case .wait: Thread.sleep(forTimeInterval: min(30, max(0, a.amount)))
        }
        return "ok"
    }
}

/// "cmd+shift+4", "ctrl+opt+space", "f5" → key code + modifier flags.
public enum Shortcut {
    public static func parse(_ s: String) -> (UInt16, UInt64)? {
        var flags: CGEventFlags = []
        var key: UInt16?
        for part in s.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            default:
                key = KeyCodes.byName[part]
                    ?? (part == "space" ? 0x31 : part == "enter" ? 0x24 : part == "escape" ? 0x35 : nil)
            }
        }
        guard let key else { return nil }
        return (key, flags.rawValue)
    }
}
