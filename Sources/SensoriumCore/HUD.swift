import AppKit

/// A small floating indicator for brightness / volume changes and arming. Plain AppKit (no SwiftUI)
/// so the background helper stays light.
public final class HUD {
    public static let shared = HUD()
    private var panel: NSPanel?
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let bar = LevelBar()
    private var token = 0

    public func show(_ target: ControlTarget, _ value: Double) {
        present(symbol: target.icon, text: "\(Int((value * 100).rounded()))%", level: value)
    }

    public func message(_ symbol: String, _ text: String) { present(symbol: symbol, text: text, level: nil) }

    private func present(symbol: String, text: String, level: Double?) {
        let p = panel ?? makePanel()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 20, weight: .semibold))
        label.stringValue = text
        label.alignment = level == nil ? .left : .right
        bar.isHidden = level == nil
        bar.level = level ?? 0
        bar.needsDisplay = true
        if let screen = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: screen.frame.midX - 140, y: screen.visibleFrame.minY + 120))
        }
        p.alphaValue = 1
        p.orderFrontRegardless()
        token += 1
        let mine = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            guard let self, mine == self.token else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.appearance = NSAppearance(named: .darkAqua)
        let fx = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 280, height: 64))
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 18
        fx.layer?.masksToBounds = true
        icon.frame = NSRect(x: 16, y: 18, width: 28, height: 28)
        icon.contentTintColor = NSColor(red: 0.30, green: 0.84, blue: 1.0, alpha: 1)
        bar.frame = NSRect(x: 56, y: 28, width: 150, height: 8)
        label.frame = NSRect(x: 56, y: 22, width: 208, height: 20)
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        [icon, bar, label].forEach(fx.addSubview)
        p.contentView = fx
        panel = p
        return p
    }
}

/// Rounded level bar with a cyan → violet fill.
final class LevelBar: NSView {
    var level = 0.0
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let fill = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(min(1, max(0, level))), height: bounds.height)
        NSGradient(starting: NSColor(red: 0.30, green: 0.84, blue: 1.0, alpha: 1),
                   ending: NSColor(red: 0.58, green: 0.40, blue: 1.0, alpha: 1))?
            .draw(in: NSBezierPath(roundedRect: fill, xRadius: r, yRadius: r), angle: 0)
    }
}
