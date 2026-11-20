import SensoriumCore
import AppKit
import SwiftUI

/// Puts each configured widget in its own borderless, blurred panel on the desktop and
/// keeps the panels in step with the settings (added/removed, level, opacity, lock, position).
final class DesktopWidgetManager: NSObject, NSWindowDelegate {
    static let shared = DesktopWidgetManager()
    static let identifier = NSUserInterfaceItemIdentifier("sensorium.widget")

    private var panels: [UUID: NSPanel] = [:]
    private var savingMove = false

    static func isWidget(_ w: NSWindow) -> Bool { w.identifier == identifier }

    /// Cheap and idempotent: called whenever widget settings change.
    func sync(_ cfg: TweakValues) {
        let wanted = cfg.widgetsShown ? cfg.desktopWidgets : []
        for (id, p) in panels where !wanted.contains(where: { $0.id == id }) {
            p.orderOut(nil)
            p.close()
            panels[id] = nil
        }
        for w in wanted {
            let p = panels[w.id] ?? makePanel(w)
            panels[w.id] = p
            apply(cfg, w, to: p)
        }
    }

    private func makePanel(_ w: DesktopWidgetConfig) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: w.x, y: w.y, width: w.width, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.identifier = Self.identifier
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.delegate = self
        // NSHostingView sizes the window to the SwiftUI content.
        p.contentView = NSHostingView(rootView: DesktopWidgetView(id: w.id)
            .environment(SensorHub.shared)
            .environment(Tweaks.shared))
        p.setFrameOrigin(NSPoint(x: w.x, y: w.y))
        p.orderFront(nil)
        return p
    }

    private func apply(_ cfg: TweakValues, _ w: DesktopWidgetConfig, to p: NSPanel) {
        let level: NSWindow.Level = cfg.widgetLevel == .desktop
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : .floating
        if p.level != level { p.level = level }
        if abs(p.alphaValue - cfg.widgetOpacity) > 0.001 { p.alphaValue = cfg.widgetOpacity }
        p.isMovableByWindowBackground = !cfg.widgetsLocked
        p.ignoresMouseEvents = cfg.widgetsClickThrough
        if !savingMove && (abs(p.frame.origin.x - w.x) > 1 || abs(p.frame.origin.y - w.y) > 1) {
            p.setFrameOrigin(NSPoint(x: w.x, y: w.y))
        }
        if !p.isVisible { p.orderFront(nil) }
    }

    /// Remember where the user dragged a widget.
    func windowDidMove(_ notification: Notification) {
        guard let p = notification.object as? NSPanel,
              let id = panels.first(where: { $0.value === p })?.key,
              let i = Tweaks.shared.v.desktopWidgets.firstIndex(where: { $0.id == id }) else { return }
        savingMove = true
        Tweaks.shared.v.desktopWidgets[i].x = p.frame.origin.x
        Tweaks.shared.v.desktopWidgets[i].y = p.frame.origin.y
        savingMove = false
    }

    /// New widgets start in a column at the top right of the screen.
    static func add(_ kind: MenuWidget) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1400, height: 900)
        let n = Tweaks.shared.v.desktopWidgets.count
        let x = screen.maxX - 290 - Double(n / 4) * 280
        let y = screen.maxY - 210 - Double(n % 4) * 200
        Tweaks.shared.v.desktopWidgets.append(DesktopWidgetConfig(kind: kind, x: x, y: y))
        Tweaks.shared.v.widgetsShown = true
    }

    static func remove(_ id: UUID) { Tweaks.shared.v.desktopWidgets.removeAll { $0.id == id } }
}

struct DesktopWidgetView: View {
    @Environment(Tweaks.self) private var tweaks
    var id: UUID

    var body: some View {
        let w = tweaks.v.desktopWidgets.first { $0.id == id }
        Group {
            if let w {
                MenuWidgetView(kind: w.kind, plain: true).frame(width: w.width)
            }
        }
        .padding(12)
        .background(VisualEffectBackground(material: .hudWindow, cornerRadius: 18))
        .contextMenu {
            Button("Remove this widget") { DesktopWidgetManager.remove(id) }
            Button(tweaks.v.widgetsLocked ? "Unlock positions" : "Lock positions") { tweaks.v.widgetsLocked.toggle() }
            Button("Open Sensorium") {
                UIState.shared.page = .widgets
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { !DesktopWidgetManager.isWidget($0) && $0.frame.width > 600 }?.makeKeyAndOrderFront(nil)
            }
        }
        .modifier(ForceDark(on: Neon.isOn))
        .preferredColorScheme(tweaks.v.theme == .futuristic ? .dark : tweaks.v.appearance.scheme)
    }
}

// MARK: - App page that manages widgets

struct WidgetsPage: View {
    @Environment(Tweaks.self) private var tweaks

    var body: some View {
        @Bindable var tweaks = tweaks
        VStack(spacing: 14) {
            Card("Desktop widgets", subtitle: "\(tweaks.v.desktopWidgets.count) placed") {
                Text("Translucent panels that live on your desktop. Drag one to move it; right-click it to remove it or lock positions.")
                    .foregroundStyle(.secondary)
                HStack {
                    Toggle("Show widgets", isOn: $tweaks.v.widgetsShown)
                    Spacer()
                    Menu("Add widget") {
                        ForEach(MenuWidget.allCases) { k in Button(k.rawValue) { DesktopWidgetManager.add(k) } }
                    }
                    .fixedSize()
                }
                if !tweaks.v.desktopWidgets.isEmpty { Divider() }
                ForEach(Array(tweaks.v.desktopWidgets.enumerated()), id: \.element.id) { i, w in
                    HStack {
                        Text(w.kind.rawValue).frame(width: 150, alignment: .leading)
                        Text("width").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { tweaks.v.desktopWidgets[i].width },
                                              set: { tweaks.v.desktopWidgets[i].width = $0 }), in: 180...520)
                        Button(role: .destructive) { DesktopWidgetManager.remove(w.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Card("Behaviour") {
                Picker("Where they sit", selection: $tweaks.v.widgetLevel) {
                    ForEach(WidgetLevel.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
                TweakSlider(title: "Opacity", value: $tweaks.v.widgetOpacity, range: 0.3...1, format: "%.2f")
                TweakSlider(title: "Refresh rate (fps)", value: $tweaks.v.widgetFPS, range: 1...60, step: 1, format: "%.0f")
                Toggle("Lock positions", isOn: $tweaks.v.widgetsLocked)
                Toggle("Click-through (widgets ignore the mouse; turn off here to move them again)", isOn: $tweaks.v.widgetsClickThrough)
            }
        }
    }
}
