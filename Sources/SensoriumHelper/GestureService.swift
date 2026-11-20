import AppKit
import CSensors
import SensoriumCore

/// One line to stderr (the LaunchAgent sends it to ~/Library/Logs/SensoriumHelper.log). Only on events.
func log(_ s: String) {
    let t = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write("\(t) \(s)\n".data(using: .utf8)!)
}

/// The always-on part: trackpad → recognizer → brightness / volume / tasks. No UI except the HUD.
final class GestureService {
    let engine = GestureEngine()
    private var config = SharedConfig.loadGestures()
    private var showHUD = true                 // read on the touch thread; a plain Bool copy of config.showHUD
    private var paused = false                 // the app is recording a gesture
    private var armTimer: Timer?
    private var caffeinate: Process?

    func start() {
        apply()
        engine.onControl = { [weak self] target, delta in
            SystemControls.nudge(target, by: delta, hud: self?.showHUD ?? true)
        }
        engine.onEvent = { [weak self] e in self?.handle(e) }
        TaskRunner.toggleNoSleep = { [weak self] in self?.toggleNoSleep() }

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let devices = sn_touch_start({ touches, count, _, ctx in
            guard let ctx else { return }
            let service = Unmanaged<GestureService>.fromOpaque(ctx).takeUnretainedValue()
            service.engine.process(UnsafeBufferPointer(start: touches, count: Int(count)), t: sn_now())
        }, ctx)
        log("started: \(devices) trackpad(s), \(config.bindings.count) gestures, \(config.letters.count) letter samples, \(config.sliders.count) slides")

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: SharedConfig.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.config = SharedConfig.loadGestures()
            self.apply()
            log("settings reloaded: \(self.config.bindings.count) gestures, \(self.config.letters.count) letter samples, enabled=\(self.config.enabled)")
        }
        dnc.addObserver(forName: SharedConfig.pauseHelper, object: nil, queue: .main) { [weak self] n in
            self?.paused = (n.userInfo?["paused"] as? Bool) ?? false
        }
    }

    private func apply() {
        engine.update(config)
        showHUD = config.showHUD
        SystemControls.resync()
    }

    private func handle(_ e: GestureEvent) {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName
        switch e {
        case .arm(let on):
            SharedConfig.post(SharedConfig.armedChanged, ["armed": on])
            HUD.shared.message(on ? "hand.draw.fill" : "hand.raised.slash", on ? "Gestures armed" : "Gestures off")
            if on {
                _ = sn_haptic_fire(3, 0, 0)
                armTimer?.invalidate()
                armTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    self?.engine.checkTimeout(now: sn_now())
                }
            } else {
                armTimer?.invalidate()
                armTimer = nil
            }
        case .stroke(let pts, let fallback):
            guard !paused else { return }
            if let (name, score) = LetterRecognizer.recognize(pts, config.letters),
               score >= config.letterThreshold(armed: engine.armed) {
                run(GesturePattern(kind: .letter, fingers: 1, letter: name), front: front)
            } else if let fallback {
                run(fallback, front: front)
            }
        case .pattern(let p):
            guard !paused else { return }
            run(p, front: front)
        }
    }

    private func run(_ p: GesturePattern, front: String?) {
        let task = config.task(for: p, armed: engine.armed, frontApp: front)
        SharedConfig.post(SharedConfig.gestureEvent, ["text": p.text, "task": task?.name ?? ""])
        guard let task else { return }
        log("\(p.text) → \(task.name)")
        if config.hapticOnTask { _ = sn_haptic_fire(3, 0, 0) }
        TaskRunner.run(task) { result in
            log("  \(result)")
            SharedConfig.post(SharedConfig.gestureEvent, ["result": result])
        }
    }

    private func toggleNoSleep() {
        if let c = caffeinate { c.terminate(); caffeinate = nil; return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-di", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        if (try? p.run()) != nil { caffeinate = p }
    }
}
