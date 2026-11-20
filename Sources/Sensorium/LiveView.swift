import SensoriumCore
import SwiftUI

// MARK: - Trackpad

struct TrackpadCard: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks

    var body: some View {
        let t = hub.touch, cfg = tweaks.v
        Card("Trackpad", subtitle: "\(t.touches.count) finger(s) · \(Int(hub.status.touchHz)) frames/s · touch + force sensors") {
            TrackpadCanvas(touches: t.touches, cfg: cfg)
                .aspectRatio(12480.0 / 7680.0, contentMode: .fit)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)   // centred, about the real pad's size on screen
            HStack {
                Text("Pressure, strongest finger (smoothed)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("now \(Int(t.touches.map(\.pressure).max() ?? 0)) · peak \(Int(t.peakPressure))")
                    .font(.caption.monospacedDigit())
            }
            LineGraph(series: [Series(color: .orange, points: t.pressureHistory.graph)],
                      tMin: t.now - cfg.historySeconds, tMax: t.now, vMin: 0, vMax: cfg.pressureMax,
                      guides: guides(cfg))
                .frame(height: 90)
            ClickCalibration()
            FingerTable(touches: t.touches)
        }
        .needs(.touch)
    }

    private func guides(_ cfg: TweakValues) -> [Guide] {
        var g: [Guide] = []
        if cfg.hapticOnPressure { g.append(Guide(value: cfg.hapticThreshold, color: .red, label: "haptic")) }
        if let s1 = hub.stagePressure[1] { g.append(Guide(value: s1, color: .green, label: "click")) }
        if let s2 = hub.stagePressure[2] { g.append(Guide(value: s2, color: .purple, label: "force click")) }
        return g
    }
}

struct TrackpadCanvas: View {
    var touches: [TouchPoint]
    var cfg: TweakValues

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let pad = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 16)
            if Neon.isOn {
                ctx.fill(pad, with: .linearGradient(Gradient(colors: [Color.black.opacity(0.55), Neon.bg1.opacity(0.8)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
                ctx.stroke(pad, with: .color(Neon.cyan.opacity(0.12)), lineWidth: 6)
                ctx.stroke(pad, with: .color(Neon.cyan.opacity(0.55)), lineWidth: 1)
            } else {
                ctx.fill(pad, with: .color(Color.gray.opacity(0.14)))
                ctx.stroke(pad, with: .color(Color.gray.opacity(0.35)), lineWidth: 1)
            }
            if cfg.showSensorGrid {   // the real 24 x 18 touch-sensing grid
                var grid = Path()
                for c in 1..<24 { let x = w * CGFloat(c) / 24; grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: h)) }
                for r in 1..<18 { let y = h * CGFloat(r) / 18; grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: w, y: y)) }
                ctx.stroke(grid, with: .color(Neon.isOn ? Neon.cyan.opacity(0.08) : Color.gray.opacity(0.12)), lineWidth: 0.5)
            }
            let pxPerMM = w / 124.8   // sensor surface is 12480 x 7680 (0.01 mm units)
            for t in touches {
                let px = CGFloat(t.x) * w
                let py = cfg.flipY ? CGFloat(t.y) * h : (1 - CGFloat(t.y)) * h
                let frac = t.pressure / max(1, cfg.pressureMax)
                let color = heatColor(frac)
                let ew = max(8, CGFloat(t.major) * pxPerMM * CGFloat(cfg.touchScale))
                let eh = max(8, CGFloat(t.minor) * pxPerMM * CGFloat(cfg.touchScale))
                var finger = ctx
                finger.translateBy(x: px, y: py)
                finger.rotate(by: .radians(-t.angle))
                finger.fill(Path(ellipseIn: CGRect(x: -ew / 2, y: -eh / 2, width: ew, height: eh)),
                            with: .color(color.opacity(0.85)))
                let ring = max(ew, eh) / 2 + 4 + CGFloat(min(1, frac)) * 46
                ctx.stroke(Path(ellipseIn: CGRect(x: px - ring, y: py - ring, width: 2 * ring, height: 2 * ring)),
                           with: .color(color.opacity(0.55)), lineWidth: 2 + CGFloat(min(1, frac)) * 4)
                if cfg.showVelocity {
                    var v = Path()
                    v.move(to: CGPoint(x: px, y: py))
                    v.addLine(to: CGPoint(x: px + CGFloat(t.vx) * w * 0.15,
                                          y: py + (cfg.flipY ? 1 : -1) * CGFloat(t.vy) * h * 0.15))
                    ctx.stroke(v, with: .color(.white.opacity(0.8)), lineWidth: 2)
                }
                if cfg.showFingerLabels {
                    ctx.draw(Text("#\(t.id)  \(Int(t.rawPressure))").font(.caption.monospacedDigit()).foregroundColor(.primary),
                             at: CGPoint(x: px, y: py - ring - 10))
                }
            }
            if touches.isEmpty {
                ctx.draw(Text("touch the trackpad").font(.callout).foregroundColor(.secondary),
                         at: CGPoint(x: w / 2, y: h / 2))
            }
        }
    }
}

struct ClickCalibration: View {
    @Environment(SensorHub.self) private var hub
    var body: some View {
        HStack(spacing: 14) {
            Stat(label: "macOS click stage", value: ["none", "click", "force click"][min(2, max(0, hub.clickStage))])
            Stat(label: "click began at", value: hub.stagePressure[1].map { "\(Int($0))" } ?? "—")
            Stat(label: "force click began at", value: hub.stagePressure[2].map { "\(Int($0))" } ?? "—")
            Stat(label: "pressure-haptic fires", value: "\(hub.touch.hapticFires)")
            Spacer()
            Text("Click inside this window to measure where macOS's click thresholds sit in raw pressure.")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: 220, alignment: .trailing)
        }
    }
}

struct FingerTable: View {
    var touches: [TouchPoint]
    var body: some View {
        if !touches.isEmpty {
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    ForEach(["finger", "state", "x", "y", "pressure", "smoothed", "contact", "density", "size mm"], id: \.self) {
                        Text($0).foregroundStyle(.secondary)
                    }
                }
                ForEach(touches) { t in
                    GridRow {
                        Text("#\(t.id)")
                        Text("\(t.state)")
                        Text(fmt(t.x, 3)); Text(fmt(t.y, 3))
                        Text("\(Int(t.rawPressure))").bold()
                        Text("\(Int(t.pressure))")
                        Text(fmt(t.total, 2)); Text(fmt(t.density, 2))
                        Text("\(fmt(t.major, 1))×\(fmt(t.minor, 1))")
                    }
                }
            }
            .font(.caption.monospacedDigit())
        }
    }
}

// MARK: - Motion

struct MotionGraphsCard: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks

    var body: some View {
        let m = hub.motion, cfg = tweaks.v
        let scale = cfg.accelUnits == .g ? 1 : 9.80665
        let tMin = m.now - cfg.historySeconds
        Card("Accelerometer & vibration", subtitle: "\(Int(hub.status.accelHz)) samples/s from the sensor processor") {
            HStack {
                Text("Acceleration (\(cfg.accelUnits.rawValue))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let a = m.latest {
                    Text(String(format: "x %+.3f   y %+.3f   z %+.3f", a.x * scale, a.y * scale, a.z * scale)).font(.caption.monospacedDigit())
                }
            }
            LineGraph(series: [
                Series(color: Neon.x, points: m.accel.map { GPoint(t: $0.t, v: $0.x * scale) }),
                Series(color: Neon.y, points: m.accel.map { GPoint(t: $0.t, v: $0.y * scale) }),
                Series(color: Neon.z, points: m.accel.map { GPoint(t: $0.t, v: $0.z * scale) }),
            ], tMin: tMin, tMax: m.now, vMin: -cfg.accelRange * scale, vMax: cfg.accelRange * scale)
            .frame(height: 110)
            Legend(items: [(Neon.x, "x"), (Neon.y, "y"), (Neon.z, "z")])
            HStack {
                Text("Vibration (mg above gravity)").font(.caption).foregroundStyle(.secondary)
                Circle().fill(m.now - m.lastTap < 0.3 ? Color.orange : Color.secondary.opacity(0.3)).frame(width: 10, height: 10)
                Text("taps: \(m.taps)").font(.caption.monospacedDigit())
                Spacer()
                Text("\(Int(m.vibNow)) mg").font(.caption.monospacedDigit())
            }
            LineGraph(series: [Series(color: .orange, points: m.vib.graph)],
                      tMin: tMin, tMax: m.now, vMin: 0, vMax: cfg.vibMax,
                      guides: [Guide(value: cfg.tapThreshold, color: .red, label: "tap")])
                .frame(height: 80)
            Text("Tap the palm rest or the desk: taps above the red line are counted.").font(.caption2).foregroundStyle(.secondary)
            if cfg.showGyro {
                Text("Gyroscope (°/s)").font(.caption).foregroundStyle(.secondary)
                LineGraph(series: [
                    Series(color: Neon.x, points: m.gyro.map { GPoint(t: $0.t, v: $0.x) }),
                    Series(color: Neon.y, points: m.gyro.map { GPoint(t: $0.t, v: $0.y) }),
                    Series(color: Neon.z, points: m.gyro.map { GPoint(t: $0.t, v: $0.z) }),
                ], tMin: tMin, tMax: m.now, vMin: -cfg.gyroRange, vMax: cfg.gyroRange)
                .frame(height: 80)
            }
        }
        .needs(.motion)
    }
}

struct OrientationCard: View {
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks

    var body: some View {
        let m = hub.motion, o = hub.orientation, cfg = tweaks.v
        let e = o.quat.map { Orientation.euler(x: $0.x, y: $0.y, z: $0.z, w: $0.w) }
        Card("Orientation", subtitle: "fused by the motion coprocessor (devmotion6, 100/s), a stream apps normally never see") {
            HStack(alignment: .top, spacing: 24) {
                LevelView(accel: m.latest, zeroX: cfg.levelZeroX, zeroY: cfg.levelZeroY).frame(width: 120, height: 120)
                CompassView(yaw: e?.yaw).frame(width: 120, height: 120)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 22) {
                        Stat(label: "roll", value: fmt(e?.roll, 1, "°"))
                        Stat(label: "pitch", value: fmt(e?.pitch, 1, "°"))
                        Stat(label: "yaw (relative)", value: fmt(e?.yaw, 1, "°"))
                    }
                    if let r = o.rotRate {
                        Text(String(format: "rotation rate  %+.3f %+.3f %+.3f rad/s", r.0, r.1, r.2)).font(.caption.monospacedDigit())
                    }
                    if let u = o.userAccel {
                        Text(String(format: "motion without gravity  %+.3f %+.3f %+.3f g (probably)", u.0, u.1, u.2)).font(.caption.monospacedDigit())
                    }
                    if let q = o.quat {
                        Text(String(format: "quaternion x %+.4f y %+.4f z %+.4f w %+.4f  (length %.4f)", q.x, q.y, q.z, q.w,
                                    (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w).squareRoot()))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            LineGraph(series: [
                Series(color: Neon.x, points: o.history.map { GPoint(t: $0.t, v: $0.x) }),
                Series(color: Neon.y, points: o.history.map { GPoint(t: $0.t, v: $0.y) }),
                Series(color: Neon.z, points: o.history.map { GPoint(t: $0.t, v: $0.z) }),
            ], tMin: o.now - cfg.historySeconds, tMax: o.now, vMin: -180, vMax: 180)
            .frame(height: 80)
            Legend(items: [(Neon.x, "roll"), (Neon.y, "pitch"), (Neon.z, "yaw")])
            HStack(spacing: 22) {
                Stat(label: "motion chip temperature", value: fmt(m.imuTemp, 2, " °C"))
                Stat(label: "light-sensor temperature", value: fmt(m.alsTemp, 2, " °C"))
            }
            TiltCompare(accel: m.latest, lid: m.lid)
        }
        .needs(.spu, .orientation)
    }
}

/// Heading dial for the fused yaw. Yaw is relative: Macs have no compass, so 0° is wherever it started.
struct CompassView: View {
    var yaw: Double?
    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2 - 4
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.secondary), lineWidth: 1)
            for k in 0..<12 {
                let a = Double(k) * .pi / 6
                var t = Path()
                t.move(to: CGPoint(x: c.x + (r - 6) * sin(a), y: c.y - (r - 6) * cos(a)))
                t.addLine(to: CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a)))
                ctx.stroke(t, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
            }
            guard let yaw else { return }
            let a = yaw * .pi / 180
            var n = Path()
            n.move(to: c)
            n.addLine(to: CGPoint(x: c.x + (r - 12) * sin(a), y: c.y - (r - 12) * cos(a)))
            ctx.stroke(n, with: .color(.orange), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            ctx.draw(Text(String(format: "%.0f°", yaw)).font(.caption.monospacedDigit()), at: CGPoint(x: c.x, y: size.height - 2))
        }
        .help("Turn the Mac on the desk and watch the needle. 0° is wherever the coprocessor started counting.")
    }
}

struct LidCard: View {
    @Environment(SensorHub.self) private var hub
    var body: some View {
        Card("Lid angle", subtitle: "hinge sensor, 10 readings/s") {
            HStack(spacing: 24) {
                LidGauge(angle: hub.motion.lid).frame(width: 220, height: 160)
                Text(hub.motion.lid >= 0 ? "\(hub.motion.lid)°" : "—")
                    .font(.system(size: 54, weight: .semibold, design: .rounded).monospacedDigit())
            }
        }
        .needs(.spu)
    }
}

struct LightCard: View {
    @Environment(SensorHub.self) private var hub
    var body: some View {
        Card("Ambient light", subtitle: "colour light sensor next to the camera (VD6286)") {
            LightView(light: hub.motion.light, eventValue: hub.slow.alsEvent)
            if let xyz = hub.slow.alsXYZ {
                let sum = max(1e-9, xyz[0] + xyz[1] + xyz[2])
                Text(String(format: "colour (CIE XYZ)  X %.2f  Y %.2f  Z %.2f   ·   chromaticity x %.3f  y %.3f", xyz[0], xyz[1], xyz[2], xyz[0] / sum, xyz[1] / sum))
                    .font(.caption.monospacedDigit())
            }
            Stat(label: "light-sensor temperature", value: fmt(hub.motion.alsTemp, 2, " °C"))
            Text("Lux, colour temperature and X/Y/Z are confirmed against macOS's own light-sensor service. Cover the area next to the camera and watch them drop.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .needs(.spu)
    }
}

struct LevelView: View {
    var accel: Vec3?
    var zeroX: Double, zeroY: Double
    var body: some View {
        Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r + 1, y: c.y - r + 1, width: 2 * r - 2, height: 2 * r - 2)),
                       with: .color(.secondary), lineWidth: 1)
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r / 3, y: c.y - r / 3, width: 2 * r / 3, height: 2 * r / 3)),
                       with: .color(.secondary.opacity(0.4)), lineWidth: 1)
            guard let a = accel else { return }
            let tx = atan2(a.x, (a.y * a.y + a.z * a.z).squareRoot()) * 180 / .pi - zeroX
            let ty = atan2(a.y, (a.x * a.x + a.z * a.z).squareRoot()) * 180 / .pi - zeroY
            let bx = c.x + CGFloat(max(-30, min(30, tx)) / 30) * (r - 10)
            let by = c.y - CGFloat(max(-30, min(30, ty)) / 30) * (r - 10)
            ctx.fill(Path(ellipseIn: CGRect(x: bx - 9, y: by - 9, width: 18, height: 18)), with: .color(.green.opacity(0.85)))
            ctx.draw(Text(String(format: "%+.0f° %+.0f°", tx, ty)).font(.system(size: 9).monospacedDigit()),
                     at: CGPoint(x: c.x, y: size.height - 6))
        }
        .help("Bubble level from the accelerometer. ±30° at the rim. Use Tweaks → Set level zero.")
    }
}

struct LidGauge: View {
    var angle: Int
    var body: some View {
        Canvas { ctx, size in
            let pivot = CGPoint(x: size.width * 0.45, y: size.height - 14)
            let len = min(size.width * 0.5, size.height - 20)
            var base = Path()
            base.move(to: pivot)
            base.addLine(to: CGPoint(x: pivot.x + len, y: pivot.y))
            ctx.stroke(base, with: .color(.secondary), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            if angle >= 0 {
                let a = Double(angle) * .pi / 180
                var lid = Path()
                lid.move(to: pivot)
                lid.addLine(to: CGPoint(x: pivot.x + len * cos(a), y: pivot.y - len * sin(a)))
                ctx.stroke(lid, with: .color(.accentColor), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
            ctx.draw(Text(angle >= 0 ? "lid \(angle)°" : "lid —").font(.caption.monospacedDigit()),
                     at: CGPoint(x: size.width / 2, y: size.height - 3))
        }
    }
}

struct LightView: View {
    var light: LightReading
    var eventValue: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ambient light").font(.caption).foregroundStyle(.secondary)
            Text(fmt(light.lux, 1, " lux")).font(.system(.title3, design: .rounded).monospacedDigit()).bold()
            GeometryReader { g in
                let f = log10(max(1, light.lux ?? 0)) / 4   // 1 .. 10,000 lux
                Capsule().fill(Color.gray.opacity(0.2))
                    .overlay(alignment: .leading) { Capsule().fill(Color.yellow).frame(width: g.size.width * CGFloat(min(1, f))) }
            }.frame(height: 6)
            Text("colour temperature \(fmt(light.cct, 0, " K"))").font(.caption2.monospacedDigit())
            Text("channels \(light.channels.map(String.init).joined(separator: " "))").font(.caption2.monospacedDigit())
            Text("macOS reads \(fmt(eventValue, 1, " lux"))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

struct TiltCompare: View {
    var accel: Vec3?
    var lid: Int
    var body: some View {
        if let a = accel, lid >= 0 {
            let tilt = atan2(a.y, -a.z) * 180 / .pi
            Text(String(format: "Accelerometer tilt %.0f° vs lid − 90° = %d°. If these move together when you tilt only the lid, the motion chip sits in the lid.", tilt, lid - 90))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
