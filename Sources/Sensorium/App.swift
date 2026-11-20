import SensoriumCore
import AppKit
import SwiftUI

@main
struct SensoriumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A single window (not a WindowGroup): "Open Sensorium" brings it forward instead of
        // creating another one, and macOS restores at most this one window at launch.
        Window("Sensorium", id: "main") {
            RootView()
                .environment(SensorHub.shared)
                .environment(Tweaks.shared)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 820)

        // ⌘, opens this, like every Mac app.
        Settings {
            SettingsView().environment(Tweaks.shared)
        }

        // Popover from the menu bar icon. Keeps running when the window is closed.
        MenuBarExtra {
            MenuPanel()
                .environment(SensorHub.shared)
                .environment(Tweaks.shared)
        } label: {
            MenuBarLabel().environment(SensorHub.shared)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(Tweaks.shared.v.showDockIcon ? .regular : .accessory)
        NSApp.activate(ignoringOtherApps: true)
        SensorHub.shared.start()
        DebugSnapshots.runIfRequested()
        PerfHarness.runIfRequested()
        GestureSelfTest.runIfRequested()
        CoffeeItem.shared.start()
        let env = ProcessInfo.processInfo.environment
        if let out = env["SENSORIUM_LAUNCHER_TEST"] {   // debug: write the real launcher script for an awkward folder name
            let folder = env["SENSORIUM_LAUNCHER_FOLDER"] ?? NSTemporaryDirectory()
            try? FinderTerminal.launcherScript(folder: folder, command: env["SENSORIUM_LAUNCHER_CMD"] ?? "pwd")
                .write(toFile: out, atomically: true, encoding: .utf8)
            exit(0)
        }
        if env["SENSORIUM_SERVICE"] == "install" {     // debug: same code path as the "Run in background" button
            FileHandle.standardError.write((ServiceManager.install() + "\n").data(using: .utf8)!)
            exit(0)
        }
        if let out = ProcessInfo.processInfo.environment["SENSORIUM_OPEN_TEST"] {   // debug: open the main window 3x
            for k in 1...3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(k)) {
                    NotificationCenter.default.post(name: .init("SensoriumTestOpenMain"), object: nil)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                let mains = NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue.hasPrefix("main") == true }
                try? "main windows after 3 open requests: \(mains.count)\n".write(toFile: out, atomically: true, encoding: .utf8)
                exit(0)
            }
        }
        TouchBench.runIfRequested()
    }

    func applicationWillTerminate(_ notification: Notification) { SensorHub.shared.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }  // menu bar + widgets keep running
}

enum Page: String, CaseIterable, Identifiable {
    case trackpad = "Trackpad", keyboard = "Keyboard", motion = "Motion", lidLight = "Lid & Light"
    case thermals = "Temperatures", battery = "Battery & Power", touchID = "Touch ID", performance = "Performance"
    case gestures = "Trackpad Gestures", tasks = "Tasks"
    case haptics = "Haptics", noSleep = "No Sleep", widgets = "Desktop Widgets", menuBar = "Menu Bar"
    case raw = "Raw Sensors"

    var id: String { rawValue }

    var section: String {
        switch self {
        case .trackpad, .keyboard, .motion, .lidLight: return "Sensors"
        case .thermals, .battery, .touchID, .performance: return "System"
        case .gestures, .tasks: return "Automation"
        case .haptics, .noSleep, .widgets, .menuBar: return "Control"
        case .raw: return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .trackpad: return "hand.point.up.left"
        case .keyboard: return "keyboard"
        case .motion: return "move.3d"
        case .lidLight: return "sun.max"
        case .thermals: return "thermometer.medium"
        case .battery: return "battery.75percent"
        case .touchID: return "touchid"
        case .performance: return "speedometer"
        case .gestures: return "hand.draw"
        case .tasks: return "bolt.horizontal"
        case .haptics: return "waveform"
        case .noSleep: return "cup.and.saucer"
        case .widgets: return "square.grid.2x2"
        case .menuBar: return "menubar.rectangle"
        case .raw: return "memorychip"
        }
    }

    static let sections = ["Sensors", "Automation", "System", "Control", "Advanced"]
}

/// UI-only state. (@State is a macro in this SDK whose plugin ships only with full Xcode,
/// so window state lives in a tiny @Observable object instead.)
@Observable final class UIState {
    static let shared = UIState()
    var page: Page? = .trackpad
    var dragDivider: DividerRef?
    var pendingAnyRegion = false
    var pendingAnyContact = true
    var pendingTaskID: UUID?
    var newLetterName = ""
    var serviceMessage = ""
}

struct RootView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(SensorHub.self) private var hub
    @Environment(Tweaks.self) private var tweaks
    @Bindable private var ui = UIState.shared

    var body: some View {
        let page = ui.page ?? .trackpad
        NavigationSplitView {
            List(selection: $ui.page) {
                ForEach(Page.sections, id: \.self) { section in
                    Section(section) {
                        ForEach(Page.allCases.filter { $0.section == section }) { p in
                            Label(p.rawValue, systemImage: p.icon).tag(p)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { StatusPanel().padding(12) }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ScrollView {
                VStack(spacing: 16) {
                PageHeader(page: page)
                Group {
                    switch page {
                    case .trackpad: VStack(spacing: 14) { TrackpadCard(); TrackpadOptions() }
                    case .keyboard: VStack(spacing: 14) { KeyboardCard(); KeyboardOptions() }
                    case .motion: VStack(spacing: 14) { MotionGraphsCard(); OrientationCard(); MotionOptions() }
                    case .lidLight: VStack(spacing: 14) { LightSensorCard(); LidCard(); LightCard() }
                    case .thermals: ThermalsView()
                    case .battery: BatteryPage()
                    case .touchID: TouchIDView()
                    case .performance: PerformancePage()
                    case .haptics: HapticsView()
                    case .noSleep: NoSleepPage()
                    case .widgets: WidgetsPage()
                    case .menuBar: MenuBarPage()
                    case .gestures: GesturesPage()
                    case .tasks: TasksPage()
                    case .raw: RawView()
                    }
                }
                }
                .padding(22)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .background {   // painted explicitly (also keeps self-snapshots honest)
                if Neon.isOn { SpaceBackground() } else { Color(nsColor: .windowBackgroundColor) }
            }
            .navigationTitle(page.rawValue)
        }
        .toolbar {
            ToolbarItem {
                Button { hub.setNoSleep(!hub.noSleep) } label: {
                    Label(hub.noSleep ? "No Sleep on" : "No Sleep", systemImage: hub.noSleep ? "cup.and.saucer.fill" : "cup.and.saucer")
                }
                .help(hub.noSleep ? "Mac is being kept awake: click to allow sleep" : "Keep the Mac awake")
            }
            ToolbarItem {
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
        }
        .tint(Neon.accent)
        .preferredColorScheme(tweaks.v.theme == .futuristic ? .dark : tweaks.v.appearance.scheme)
        .onReceive(NotificationCenter.default.publisher(for: .init("SensoriumTestOpenMain"))) { _ in openWindow(id: "main") }
    }
}

struct StatusPanel: View {
    @Environment(SensorHub.self) private var hub
    var body: some View {
        let s = hub.status
        VStack(alignment: .leading, spacing: 3) {
            Label("\(Int(s.touchHz)) touch frames/s", systemImage: "hand.point.up.left")
            Label("\(Int(s.accelHz)) motion samples/s", systemImage: "move.3d")
            Label(hub.noSleep ? "staying awake" : "sleep allowed", systemImage: hub.noSleep ? "cup.and.saucer.fill" : "cup.and.saucer")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
