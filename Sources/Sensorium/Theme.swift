import SensoriumCore
import SwiftUI

/// The futuristic palette: deep-space background, neon accents.
enum Neon {
    static let cyan = Color(red: 0.30, green: 0.84, blue: 1.00)
    static let violet = Color(red: 0.58, green: 0.40, blue: 1.00)
    static let magenta = Color(red: 1.00, green: 0.38, blue: 0.72)
    static let lime = Color(red: 0.62, green: 0.95, blue: 0.40)
    static let amber = Color(red: 1.00, green: 0.72, blue: 0.28)
    static let bg0 = Color(red: 0.020, green: 0.027, blue: 0.060)
    static let bg1 = Color(red: 0.050, green: 0.055, blue: 0.125)
    static let glass = Color.white.opacity(0.045)
    static let line = Color.white.opacity(0.09)

    static var isOn: Bool { Tweaks.shared.v.theme == .futuristic }
    // Graph series colours (x / y / z) for both themes.
    static var x: Color { isOn ? magenta : .red }
    static var y: Color { isOn ? lime : .green }
    static var z: Color { isOn ? cyan : .blue }
    static var accent: Color { isOn ? cyan : .accentColor }
}

/// Deep-space backdrop: dark gradient, two soft glows and a faint grid.
struct SpaceBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Neon.bg0, Neon.bg1], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Neon.cyan.opacity(0.13), .clear], center: .topLeading, startRadius: 10, endRadius: 650)
            RadialGradient(colors: [Neon.violet.opacity(0.13), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 700)
            Canvas { ctx, size in
                var grid = Path()
                let step: CGFloat = 44
                var x: CGFloat = 0
                while x < size.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                var y: CGFloat = 0
                while y < size.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                ctx.stroke(grid, with: .color(.white.opacity(0.025)), lineWidth: 0.5)
            }
        }
        .ignoresSafeArea()
    }
}

/// Large page title with a cyan → violet gradient.
struct PageHeader: View {
    var page: Page
    var body: some View {
        if Neon.isOn {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: page.icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [Neon.cyan, Neon.violet], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Neon.glass))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Neon.line))
                    .shadow(color: Neon.cyan.opacity(0.35), radius: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.rawValue.uppercased())
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .tracking(2)
                        .foregroundStyle(LinearGradient(colors: [.white, Neon.cyan.opacity(0.9)], startPoint: .leading, endPoint: .trailing))
                    Text(page.tagline).font(.callout).foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }
            .padding(.bottom, 4)
        }
    }
}

extension Page {
    var tagline: String {
        switch self {
        case .trackpad: return "Touch and force, 100+ frames a second"
        case .keyboard: return "Which key, when, and your typing rhythm"
        case .motion: return "Accelerometer, gyroscope and fused orientation"
        case .lidLight: return "Hinge angle and what the light sensor sees"
        case .thermals: return "63 temperature sensors across the chip"
        case .battery: return "Charge, power flow and health"
        case .touchID: return "Fingerprint sensor status"
        case .performance: return "What Sensorium itself costs your Mac"
        case .gestures: return "Regions, slides, letters, rhythms → actions"
        case .tasks: return "Build the actions your gestures run"
        case .haptics: return "Drive the trackpad's motor"
        case .noSleep: return "Keep the Mac awake"
        case .widgets: return "Live panels on your desktop"
        case .menuBar: return "The popover next to the notch"
        case .raw: return "Every stream from the sensor processor"
        }
    }
}

/// Forces dark appearance inside a view tree (works in popovers, panels and offscreen renders,
/// where a window-level preferredColorScheme doesn't reach).
struct ForceDark: ViewModifier {
    var on: Bool
    func body(content: Content) -> some View {
        if on { content.environment(\.colorScheme, .dark) } else { content }
    }
}
