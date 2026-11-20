import SensoriumCore
import SwiftUI

struct KeyboardCard: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks

    var body: some View {
        let k = hub.keys, cfg = tweaks.v
        Card("Keyboard", subtitle: source) {
            KeyboardCanvas(snap: k, cfg: cfg, now: k.now)
                .aspectRatio(KeyLayout.width / 6, contentMode: .fit)
                .frame(maxHeight: 280)
            HStack {
                Text("Rhythm: last \(Int(cfg.rhythmSeconds)) s. Bar length = hold time, space between bars = gap.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            RhythmCanvas(strokes: k.strokes, now: k.now, window: cfg.rhythmSeconds)
                .frame(height: 84)
            HStack(spacing: 18) {
                Stat(label: "avg hold", value: fmt(k.meanHold.map { $0 * 1000 }, 0, " ms"))
                Stat(label: "avg gap", value: fmt(k.meanGap.map { $0 * 1000 }, 0, " ms"))
                Stat(label: "speed (10 s)", value: "\(Int(k.wpm)) wpm")
                Stat(label: "held now", value: k.pressed.compactMap { KeyLayout.labels[$0] }.sorted().joined(separator: " ").ifEmpty("—"))
                Stat(label: "keystrokes", value: "\(k.counts.values.reduce(0, +))")
                Spacer()
            }
            Text("The keyboard only reports which key and when (on/off switches, no pressure). F-keys may act as media keys and not show here.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .needs(.keys)
    }

    private var source: String {
        if hub.status.globalKeysActive { return "system-wide (Input Monitoring granted)" }
        if tweaks.v.globalKeys {
            return "system-wide requested but blocked (error \(String(format: "0x%08X", UInt32(bitPattern: hub.status.globalKeysError)))). Type in this window."
        }
        return "keys typed in this window"
    }
}

extension String {
    func ifEmpty(_ s: String) -> String { isEmpty ? s : self }
}

struct KeyboardCanvas: View {
    var snap: KeySnap
    var cfg: TweakValues
    var now: Double

    var body: some View {
        Canvas { ctx, size in
            let u = size.width / KeyLayout.width
            let rowH = size.height / 6
            let maxCount = Double(snap.counts.values.max() ?? 1)
            for (r, row) in KeyLayout.rows.enumerated() {
                var x: CGFloat = 0
                for cap in row {
                    let w = CGFloat(cap.width) * u
                    let rect = CGRect(x: x, y: CGFloat(r) * rowH, width: w, height: rowH).insetBy(dx: 2, dy: 2)
                    if let c2 = cap.code2, let c1 = cap.code {   // stacked up/down arrows
                        let top = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2 - 1)
                        let bottom = CGRect(x: rect.minX, y: rect.midY + 1, width: rect.width, height: rect.height / 2 - 1)
                        drawKey(ctx, top, label: "↑", code: c1, u: u, maxCount: maxCount)
                        drawKey(ctx, bottom, label: "↓", code: c2, u: u, maxCount: maxCount)
                    } else if cap.halfHeight {
                        let half = CGRect(x: rect.minX, y: rect.midY + 1, width: rect.width, height: rect.height / 2 - 1)
                        drawKey(ctx, half, label: cap.label, code: cap.code, u: u, maxCount: maxCount)
                    } else {
                        drawKey(ctx, rect, label: cap.label, code: cap.code, u: u, maxCount: maxCount)
                    }
                    x += w
                }
            }
        }
    }

    private func drawKey(_ ctx: GraphicsContext, _ rect: CGRect, label: String, code: UInt16?, u: CGFloat, maxCount: Double) {
        let shape = Path(roundedRect: rect, cornerRadius: max(3, u * 0.12))
        var fill = Color.gray.opacity(0.18)
        if let code {
            let pressed = snap.pressed.contains(code)
            switch cfg.keyColorMode {
            case .live:
                if pressed {
                    fill = .orange
                } else if let up = snap.lastUp[code], now - up < cfg.keyFade {
                    fill = Color.orange.opacity(0.85 * (1 - (now - up) / cfg.keyFade) + 0.1)
                }
            case .heat:
                if let n = snap.counts[code] { fill = heatColor(Double(n) / maxCount).opacity(0.85) }
                if pressed { fill = .white }
            case .hold:
                if let h = snap.avgHold[code] { fill = heatColor(h / 0.25).opacity(0.85) }   // 0..250 ms
                if pressed { fill = .white }
            }
        } else {
            fill = Color.gray.opacity(0.08)
        }
        ctx.fill(shape, with: .color(fill))
        ctx.stroke(shape, with: .color(Color.primary.opacity(0.15)), lineWidth: 0.5)
        var text = label
        if cfg.keyColorMode == .heat, let code, let n = snap.counts[code] { text += "\n\(n)" }
        if cfg.keyColorMode == .hold, let code, let h = snap.avgHold[code] { text += "\n\(Int(h * 1000))ms" }
        ctx.draw(Text(text).font(.system(size: max(8, u * 0.24))).foregroundColor(.primary),
                 at: CGPoint(x: rect.midX, y: rect.midY))
    }
}

/// Piano-roll of recent keystrokes. Up to 3 lanes so overlapping keys (rollover) stay visible.
struct RhythmCanvas: View {
    var strokes: [KeyStroke]
    var now: Double
    var window: Double

    var body: some View {
        Canvas { ctx, size in
            let t0 = now - window
            let laneH = (size.height - 14) / 3
            for s in strokes {
                let end = s.up ?? now
                guard end >= t0 else { continue }
                let x1 = CGFloat((max(s.down, t0) - t0) / window) * size.width
                let x2 = max(x1 + 2, CGFloat((end - t0) / window) * size.width)
                let rect = CGRect(x: x1, y: 14 + CGFloat(s.lane) * laneH, width: x2 - x1, height: laneH - 3)
                let held = s.up == nil
                ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(held ? .orange : .teal.opacity(0.75)))
                let label = KeyLayout.labels[s.code] ?? "?"
                ctx.draw(Text(label).font(.system(size: 9)).foregroundColor(.primary),
                         at: CGPoint(x: x1 + 1, y: 6), anchor: .leading)
                if let up = s.up, rect.width > 26 {
                    ctx.draw(Text("\(Int((up - s.down) * 1000))").font(.system(size: 8).monospacedDigit()).foregroundColor(.black),
                             at: CGPoint(x: rect.midX, y: rect.midY))
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
