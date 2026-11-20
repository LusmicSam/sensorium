import SensoriumCore
import AppKit
import SwiftUI

struct Card<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        if Neon.isOn {
            // Futuristic: glass panel, gradient hairline border, faint cyan glow.
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(Neon.cyan)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.5)) }
                    Spacer()
                }
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Neon.glass))
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial).opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(
                LinearGradient(colors: [Neon.cyan.opacity(0.45), Neon.violet.opacity(0.18), .white.opacity(0.04)],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .shadow(color: Neon.cyan.opacity(0.07), radius: 18)
        } else {
            // Native: Apple's standard grouped box.
            GroupBox {
                VStack(alignment: .leading, spacing: 8) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(.bottom, 2)
            }
        }
    }
}

struct GPoint { var t: Double; var v: Double }
struct Series { var color: Color; var points: [GPoint] }
struct Guide { var value: Double; var color: Color; var label: String? = nil }

/// Fast scrolling line graph drawn with Canvas (hundreds of points at 60 fps).
struct LineGraph: View {
    var series: [Series]
    var tMin: Double, tMax: Double
    var vMin: Double, vMax: Double
    var guides: [Guide] = []

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func x(_ t: Double) -> CGFloat { CGFloat((t - tMin) / max(1e-9, tMax - tMin)) * w }
            func y(_ v: Double) -> CGFloat {
                let f = (min(vMax, max(vMin, v)) - vMin) / max(1e-9, vMax - vMin)
                return h - CGFloat(f) * h
            }
            if vMin < 0 && vMax > 0 {
                var zero = Path()
                zero.move(to: CGPoint(x: 0, y: y(0)))
                zero.addLine(to: CGPoint(x: w, y: y(0)))
                ctx.stroke(zero, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
            }
            for g in guides {
                var p = Path()
                p.move(to: CGPoint(x: 0, y: y(g.value)))
                p.addLine(to: CGPoint(x: w, y: y(g.value)))
                ctx.stroke(p, with: .color(g.color.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                if let label = g.label {
                    ctx.draw(Text(label).font(.system(size: 9)).foregroundColor(g.color),
                             at: CGPoint(x: w - 4, y: y(g.value) - 7), anchor: .trailing)
                }
            }
            for s in series where s.points.count > 1 {
                // Never draw more than ~2 points per pixel column.
                let stride = max(1, s.points.count / max(1, Int(w * 2)))
                var p = Path()
                p.move(to: CGPoint(x: x(s.points[0].t), y: y(s.points[0].v)))
                var i = stride
                while i < s.points.count {
                    p.addLine(to: CGPoint(x: x(s.points[i].t), y: y(s.points[i].v)))
                    i += stride
                }
                if Neon.isOn { ctx.stroke(p, with: .color(s.color.opacity(0.22)), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)) }
                ctx.stroke(p, with: .color(s.color), lineWidth: 1.5)
            }
        }
        .background(GraphBackground())
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Graph panel: faint fill plus quarter grid lines.
struct GraphBackground: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8),
                     with: .color(Neon.isOn ? Color.black.opacity(0.35) : Color.primary.opacity(0.06)))
            var g = Path()
            for k in 1..<4 {
                let y = size.height * CGFloat(k) / 4
                g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(g, with: .color(Neon.isOn ? Neon.cyan.opacity(0.07) : Color.primary.opacity(0.05)), lineWidth: 0.5)
        }
    }
}

struct Legend: View {
    var items: [(Color, String)]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    Circle().fill(item.0).frame(width: 7, height: 7)
                    Text(item.1)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

struct Stat: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .rounded).monospacedDigit()).bold()
                .foregroundStyle(Neon.isOn ? Color.white : Color.primary)
        }
    }
}

func fmt(_ v: Double?, _ digits: Int = 1, _ unit: String = "") -> String {
    guard let v, v.isFinite else { return "—" }
    return String(format: "%.\(digits)f", v) + unit
}

/// Blue (low) -> red (high).
func heatColor(_ fraction: Double) -> Color {
    Color(hue: 0.62 * (1 - min(1, max(0, fraction))), saturation: 0.85, brightness: 0.95)
}

extension Array where Element == Sample {
    var graph: [GPoint] { map { GPoint(t: $0.t, v: $0.v) } }
}

extension AppearanceMode {
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Real behind-window blur (what macOS widgets and HUDs use).
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var cornerRadius: CGFloat = 0
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state = .active
        updateNSView(v, context: context)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        // A stretchable rounded mask gives the blur real rounded corners (SwiftUI clipping can't reach it).
        if cornerRadius > 0 {
            let r = cornerRadius, side = 2 * r + 1
            let mask = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
            mask.resizingMode = .stretch
            v.maskImage = mask
        }
    }
}

/// A labelled row for option forms.
struct OptionRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) { self.title = title; self.content = content }
    var body: some View {
        HStack { Text(title); Spacer(); content() }
    }
}

/// Declares what live data a view needs while it is on screen; the hub runs streams only for these.
struct NeedsModifier: ViewModifier {
    var needs: [Need]
    func body(content: Content) -> some View {
        content
            .onAppear { needs.forEach { SensorHub.shared.need($0, true) } }
            .onDisappear { needs.forEach { SensorHub.shared.need($0, false) } }
    }
}

extension View {
    func needs(_ n: Need...) -> some View { modifier(NeedsModifier(needs: n)) }
}
