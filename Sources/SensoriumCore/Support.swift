import AppKit
import Foundation

/// macOS virtual key codes by name, for keyboard-shortcut task steps.
public enum KeyCodes {
    public static let byName: [String: UInt16] = {
        var m: [String: UInt16] = ["space": 0x31, "return": 0x24, "enter": 0x24, "tab": 0x30, "delete": 0x33,
                                   "esc": 0x35, "escape": 0x35, "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
                                   "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E, "\\": 0x2A, ";": 0x29, "'": 0x27,
                                   ",": 0x2B, ".": 0x2F, "/": 0x2C, "`": 0x32]
        let letters: [(String, UInt16)] = [("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05),
            ("z", 0x06), ("x", 0x07), ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C), ("w", 0x0D), ("e", 0x0E),
            ("r", 0x0F), ("y", 0x10), ("t", 0x11), ("o", 0x1F), ("u", 0x20), ("i", 0x22), ("p", 0x23), ("l", 0x25),
            ("j", 0x26), ("k", 0x28), ("n", 0x2D), ("m", 0x2E)]
        for (k, v) in letters { m[k] = v }
        let digits: [UInt16] = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
        for (i, v) in digits.enumerated() { m["\(i)"] = v }
        let f: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        for (i, v) in f.enumerated() { m["f\(i + 1)"] = v }
        return m
    }()
}

/// Finder → Terminal: open a Terminal window in the folder Finder is showing and run a command.
public enum FinderTerminal {
    /// POSIX path of the front Finder window (Desktop if no window), or nil if Finder isn't in front
    /// or macOS's Automation permission for Finder was declined. Main thread only.
    public static func frontFinderFolder() -> String? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return nil }
        let source = """
        tell application "Finder"
            if (count of Finder windows) > 0 then
                return POSIX path of (target of front Finder window as alias)
            else
                return POSIX path of (desktop as alias)
            end if
        end tell
        """
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
    }

    /// Single-quote for zsh.
    static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The launcher script: interactive shell so aliases from ~/.zshrc (like `cc`) exist, and the
    /// window stays open on a normal prompt after the command ends. It deletes itself when it starts.
    public static func launcherScript(folder: String, command: String) -> String {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let inner = cmd.isEmpty ? "exec /bin/zsh -i" : "\(cmd); exec /bin/zsh -i"
        return """
        #!/bin/zsh
        rm -f -- "$0"
        cd -- \(q(folder)) || exit 1
        exec /bin/zsh -i -c \(q(inner))

        """
    }

    /// Writes a self-deleting .command file and opens it (Terminal runs .command files). No Terminal
    /// automation permission needed this way.
    public static func openTerminal(at folder: String, run command: String) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sensorium-\(UUID().uuidString.prefix(8)).command")
        do {
            try launcherScript(folder: folder, command: command).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}

/// Settings shared between the app (writes) and the background helper (reads).
public enum SharedConfig {
    public static let suite = "local.personal.sensorium"
    public static let tweaksKey = "sensorium.tweaks.v1"
    public static let changed = Notification.Name("local.personal.sensorium.gesturesChanged")
    public static let gestureEvent = Notification.Name("local.personal.sensorium.gestureEvent")
    public static let armedChanged = Notification.Name("local.personal.sensorium.armedChanged")
    public static let pauseHelper = Notification.Name("local.personal.sensorium.pauseHelper")
    public static let helperBundleID = "local.personal.sensorium.helper"

    /// The gesture settings out of the app's saved settings blob (nil = use defaults).
    public static func loadGestures() -> GestureConfig {
        guard let defaults = UserDefaults(suiteName: suite),
              let data = defaults.data(forKey: tweaksKey),
              let all = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let g = all["gestures"],
              let gData = try? JSONSerialization.data(withJSONObject: g),
              let config = try? JSONDecoder().decode(GestureConfig.self, from: gData) else { return GestureConfig() }
        return config
    }

    public static func post(_ name: Notification.Name, _ info: [String: Any]? = nil) {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
    }
}
