import AppKit
import Darwin
import SensoriumCore

/// Installs / removes the LaunchAgent that keeps SensoriumHelper running (starts at login,
/// restarted if it crashes). Everything lives in ~/Library/LaunchAgents; nothing system-wide.
enum ServiceManager {
    static let label = SharedConfig.helperBundleID
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var helperExecutable: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LoginItems/SensoriumHelper.app/Contents/MacOS/SensoriumHelper").path
    }
    static var logPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SensoriumHelper.log").path
    }
    static var installed: Bool { FileManager.default.fileExists(atPath: plistURL.path) }
    private static var domain: String { "gui/\(getuid())" }

    @discardableResult
    static func install() -> String {
        guard FileManager.default.isExecutableFile(atPath: helperExecutable) else {
            return "Helper not found in this copy of the app (run Sensorium from ~/Applications)."
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [helperExecutable],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],     // restart after a crash, not after a clean stop
            "LimitLoadToSessionType": "Aqua",
            "StandardErrorPath": logPath,
            "StandardOutPath": logPath,
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
        } catch {
            return "Couldn't write the LaunchAgent: \(error.localizedDescription)"
        }
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        let (rc, out) = launchctl(["bootstrap", domain, plistURL.path])
        return rc == 0 ? "Running in the background; starts at login." : "launchctl bootstrap failed (\(rc)): \(out)"
    }

    @discardableResult
    static func uninstall() -> String {
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        return "Background service stopped and removed."
    }

    static func launchctl(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// CPU seconds used so far and memory footprint of another of our processes.
    static func usage(pid: pid_t) -> (cpuSeconds: Double, footprintMB: Double)? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard r == 0 else { return nil }
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        let ticks = Double(info.ri_user_time + info.ri_system_time) * Double(tb.numer) / Double(tb.denom)
        return (ticks / 1e9, Double(info.ri_phys_footprint) / 1_048_576)
    }
}
