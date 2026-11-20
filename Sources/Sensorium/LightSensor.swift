import SensoriumCore
import AppKit
import SwiftUI

/// What the ambient light sensor "sees": colour, where it sits among all visible colours,
/// raw channels and lux over time. All values come from the sensor itself (no camera).
struct LightSensorCard: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        let live = hub.lightLive
        let m = hub.motion
        Card("What the light sensor sees", subtitle: "VD6286 colour sensor next to the camera · 5 readings/s") {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    // measured light colour, brightness-normalized
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(live.map { CIE.swatch($0.xyz) } ?? Color.gray)
                        .frame(width: 170, height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15)))
                        .shadow(color: (live.map { CIE.swatch($0.xyz) } ?? .clear).opacity(0.6), radius: 18)
                    Text("colour of the light around you").font(.caption2).foregroundStyle(.secondary)
                    Stat(label: "illuminance", value: fmt(live?.lux ?? m.light.lux, 1, " lux"))
                    Stat(label: "colour temperature", value: fmt(live?.cct ?? m.light.cct, 0, " K"))
                    if let xy = live.flatMap({ CIE.xy($0.xyz) }) {
                        Stat(label: "chromaticity x, y", value: String(format: "%.3f, %.3f", xy.x, xy.y))
                    }
                    Stat(label: "sensor temperature", value: fmt(m.alsTemp, 1, " °C"))
                }
                ChromaticityDiagram(point: live.flatMap { CIE.xy($0.xyz) }, cct: live?.cct)
                    .frame(width: 330, height: 360)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Raw colour channels").font(.caption.bold()).foregroundStyle(.secondary)
                    ChannelBars(values: m.light.channels.map(Double.init)).frame(height: 140)
                    Text("Lux, last 2 minutes").font(.caption.bold()).foregroundStyle(.secondary)
                    let h = hub.luxHistory
                    LineGraph(series: [Series(color: Neon.amber, points: h.graph)],
                              tMin: (h.last?.t ?? 0) - 120, tMax: h.last?.t ?? 1, vMin: 0,
                              vMax: max(20, (h.map(\.v).max() ?? 0) * 1.2))
                        .frame(height: 110)
                }
                .frame(maxWidth: .infinity)
            }
            Text("Cover the sensor (next to the camera) or point a coloured light at it: the dot moves across the colour map and the swatch changes. The curve is the colour of natural light from candle (≈1,900 K) to blue sky.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .needs(.spu, .light)
    }
}

struct ChannelBars: View {
    var values: [Double]
    private let colors: [Color] = [Neon.magenta, Neon.lime, Neon.cyan, .white.opacity(0.8), Neon.violet]
    var body: some View {
        let top = max(1, values.max() ?? 1)
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                VStack(spacing: 4) {
                    Text("\(Int(v))").font(.caption2.monospacedDigit())
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [colors[i % colors.count], colors[i % colors.count].opacity(0.35)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 26, height: max(3, CGFloat(v / top) * 100))
                        .shadow(color: colors[i % colors.count].opacity(0.5), radius: 6)
                    Text("ch\(i)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// CIE 1931 xy chromaticity diagram ("the colour horseshoe") with the Planckian locus and the live point.
struct ChromaticityDiagram: View {
    var point: CGPoint?
    var cct: Double?

    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(x: 26, y: 8, width: size.width - 34, height: size.height - 34)
            func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + x / 0.8 * r.width, y: r.maxY - y / 0.9 * r.height) }
            // axes + grid
            var grid = Path()
            for k in stride(from: 0.0, through: 0.8, by: 0.1) { grid.move(to: p(k, 0)); grid.addLine(to: p(k, 0.9)) }
            for k in stride(from: 0.0, through: 0.9, by: 0.1) { grid.move(to: p(0, k)); grid.addLine(to: p(0.8, k)) }
            ctx.stroke(grid, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
            for k in stride(from: 0.0, through: 0.8, by: 0.2) {
                ctx.draw(Text(String(format: "%.1f", k)).font(.system(size: 8)).foregroundColor(.secondary), at: CGPoint(x: p(k, 0).x, y: r.maxY + 9))
            }
            for k in stride(from: 0.2, through: 0.8, by: 0.2) {
                ctx.draw(Text(String(format: "%.1f", k)).font(.system(size: 8)).foregroundColor(.secondary), at: CGPoint(x: r.minX - 12, y: p(0, k).y))
            }
            // the coloured horseshoe (computed once)
            ctx.draw(Image(decorative: CIE.horseshoe, scale: 1), in: r)
            var outline = Path()
            outline.move(to: p(CIE.locus[0].1, CIE.locus[0].2))
            for q in CIE.locus.dropFirst() { outline.addLine(to: p(q.1, q.2)) }
            outline.closeSubpath()
            ctx.stroke(outline, with: .color(.white.opacity(0.5)), lineWidth: 1)
            for q in CIE.locus where [460, 480, 500, 520, 540, 560, 580, 600, 620].contains(q.0) {
                ctx.draw(Text("\(q.0)").font(.system(size: 8)).foregroundColor(.white.opacity(0.7)), at: p(q.1 + (q.1 < 0.3 ? -0.03 : 0.03), q.2 + 0.015))
            }
            // Planckian locus (colour of glowing objects / natural light)
            var planck = Path()
            let temps = stride(from: 1700.0, through: 20000.0, by: 100.0).compactMap { CIE.planckXY($0) }
            if let f = temps.first { planck.move(to: p(f.x, f.y)) }
            for q in temps.dropFirst() { planck.addLine(to: p(q.x, q.y)) }
            ctx.stroke(planck, with: .color(.black.opacity(0.65)), lineWidth: 2)
            for t in [2000.0, 3000, 4000, 6500, 10000] {
                if let q = CIE.planckXY(t) {
                    ctx.fill(Path(ellipseIn: CGRect(x: p(q.x, q.y).x - 2, y: p(q.x, q.y).y - 2, width: 4, height: 4)), with: .color(.black))
                    ctx.draw(Text("\(Int(t))K").font(.system(size: 8, weight: .semibold)).foregroundColor(.black.opacity(0.8)),
                             at: CGPoint(x: p(q.x, q.y).x, y: p(q.x, q.y).y + 9))
                }
            }
            // live reading
            if let pt = point {
                let c = p(pt.x, pt.y)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26)), with: .color(.white.opacity(0.25)))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)), with: .color(.white), lineWidth: 2.5)
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(.black))
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.35)))
    }
}

enum CIE {
    /// CIE 1931 2° spectral locus (wavelength nm, x, y).
    static let locus: [(Int, Double, Double)] = [
        (380, 0.1741, 0.0050), (400, 0.1733, 0.0048), (420, 0.1714, 0.0051), (440, 0.1644, 0.0109), (450, 0.1566, 0.0177),
        (460, 0.1440, 0.0297), (470, 0.1241, 0.0578), (475, 0.1096, 0.0868), (480, 0.0913, 0.1327), (485, 0.0687, 0.2007),
        (490, 0.0454, 0.2950), (495, 0.0235, 0.4127), (500, 0.0082, 0.5384), (505, 0.0039, 0.6548), (510, 0.0139, 0.7502),
        (515, 0.0389, 0.8120), (520, 0.0743, 0.8338), (525, 0.1142, 0.8262), (530, 0.1547, 0.8059), (535, 0.1929, 0.7816),
        (540, 0.2296, 0.7543), (545, 0.2658, 0.7243), (550, 0.3016, 0.6923), (555, 0.3373, 0.6589), (560, 0.3731, 0.6245),
        (565, 0.4087, 0.5896), (570, 0.4441, 0.5547), (575, 0.4788, 0.5202), (580, 0.5125, 0.4866), (585, 0.5448, 0.4544),
        (590, 0.5752, 0.4242), (595, 0.6029, 0.3965), (600, 0.6270, 0.3725), (610, 0.6658, 0.3340), (620, 0.6915, 0.3083),
        (630, 0.7079, 0.2920), (640, 0.7190, 0.2809), (650, 0.7260, 0.2740), (660, 0.7300, 0.2700), (680, 0.7334, 0.2666),
        (700, 0.7347, 0.2653),
    ]

    static func xy(_ xyz: [Double]) -> CGPoint? {
        guard xyz.count == 3 else { return nil }
        let s = xyz[0] + xyz[1] + xyz[2]
        guard s > 1e-6 else { return nil }
        return CGPoint(x: xyz[0] / s, y: xyz[1] / s)
    }

    /// Planckian locus (Kim et al. cubic approximation), 1667–25000 K.
    static func planckXY(_ t: Double) -> CGPoint? {
        guard t >= 1667 && t <= 25000 else { return nil }
        let x = t <= 4000
            ? -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
            : -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390
        let y = t <= 2222 ? -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
              : t <= 4000 ? -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
              : 3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483
        return CGPoint(x: x, y: y)
    }

    /// sRGB colour for XYZ, scaled so the brightest channel is 1 (shows the hue of the light).
    static func swatch(_ xyz: [Double]) -> Color {
        guard xyz.count == 3 else { return .gray }
        let (r, g, b) = linearRGB(xyz[0], xyz[1], xyz[2])
        let m = max(r, g, b, 1e-6)
        return Color(.sRGB, red: gamma(max(0, r / m)), green: gamma(max(0, g / m)), blue: gamma(max(0, b / m)))
    }

    static func linearRGB(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
        (3.2406 * x - 1.5372 * y - 0.4986 * z, -0.9689 * x + 1.8758 * y + 0.0415 * z, 0.0557 * x - 0.2040 * y + 1.0570 * z)
    }

    static func gamma(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    /// The filled horseshoe, rendered once (x 0…0.8, y 0…0.9).
    static let horseshoe: CGImage = {
        let w = 320, h = 360
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let poly = locus.map { ($0.1, $0.2) }
        func inside(_ x: Double, _ y: Double) -> Bool {
            var c = false
            var j = poly.count - 1
            for i in 0..<poly.count {
                let (xi, yi) = poly[i], (xj, yj) = poly[j]
                if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi { c.toggle() }
                j = i
            }
            return c
        }
        for row in 0..<h {
            for col in 0..<w {
                let x = (Double(col) + 0.5) / Double(w) * 0.8, y = (1 - (Double(row) + 0.5) / Double(h)) * 0.9
                guard y > 0.001, inside(x, y) else { continue }
                let (r, g, b) = linearRGB(x / y, 1, (1 - x - y) / y)
                let m = max(r, g, b, 1e-6)
                let i = (row * w + col) * 4
                px[i] = UInt8(gamma(max(0, r / m)) * 230)       // premultiplied by alpha 230/255
                px[i + 1] = UInt8(gamma(max(0, g / m)) * 230)
                px[i + 2] = UInt8(gamma(max(0, b / m)) * 230)
                px[i + 3] = 230
            }
        }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()
}
