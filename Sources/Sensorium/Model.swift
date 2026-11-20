import SensoriumCore
import Foundation
import CSensors

// MARK: - Samples and ring buffer

struct Sample { var t: Double; var v: Double }
struct Vec3 { var t: Double; var x: Double; var y: Double; var z: Double }

/// Fixed-capacity ring buffer; index 0 is the oldest element.
struct Ring<T> {
    private var buf: [T] = []
    private var head = 0
    let capacity: Int
    init(_ capacity: Int) { self.capacity = capacity }

    var count: Int { buf.count }
    subscript(i: Int) -> T { buf.count < capacity ? buf[i] : buf[(head + i) % capacity] }
    var last: T? { buf.isEmpty ? nil : self[buf.count - 1] }

    mutating func append(_ x: T) {
        if buf.count < capacity { buf.append(x) } else { buf[head] = x; head = (head + 1) % capacity }
    }

    /// Elements newer than `t0`, oldest first. Walks back from the newest, so cost ~ result size.
    func suffix(since t0: Double, _ time: (T) -> Double) -> [T] {
        var i = buf.count - 1
        while i >= 0 && time(self[i]) >= t0 { i -= 1 }
        return (i + 1 ..< buf.count).map { self[$0] }
    }
}

// MARK: - Snapshots (what the UI draws, rebuilt every tick)

struct TouchPoint: Identifiable {
    var id: Int32
    var state: Int32
    var x, y, vx, vy: Double
    var pressure: Double      // smoothed
    var rawPressure: Double
    var total, density, major, minor, angle: Double
}

struct TouchSnap {
    var now = 0.0
    var touches: [TouchPoint] = []
    var pressureHistory: [Sample] = []
    var peakPressure = 0.0
    var hapticFires = 0
}

struct LightReading {
    var lux: Double?
    var cct: Double?
    var channels: [UInt32] = []
}

struct MotionSnap {
    var now = 0.0
    var accel: [Vec3] = []
    var gyro: [Vec3] = []
    var vib: [Sample] = []
    var latest: Vec3?
    var latestGyro: Vec3?
    var vibNow = 0.0
    var taps = 0
    var lastTap = 0.0
    var lid = -1
    var imuTemp: Double?
    var light = LightReading()
    var alsTemp: Double?     // 0xFF00/05 value (int32/65536)
}

struct KeyStroke: Identifiable {
    var id: Int
    var code: UInt16
    var down: Double
    var up: Double?
    var lane: Int
}

struct KeySnap {
    var now = 0.0
    var pressed: Set<UInt16> = []
    var strokes: [KeyStroke] = []
    var counts: [UInt16: Int] = [:]
    var avgHold: [UInt16: Double] = [:]
    var lastUp: [UInt16: Double] = [:]
    var meanHold: Double?
    var meanGap: Double?
    var wpm = 0.0
    var total = 0
}

struct Reading: Identifiable {
    var id: Int
    var name: String
    var value: Double
}

struct TempGroup: Identifiable {
    var id: String { name }
    var name: String
    var readings: [Reading]
    var min = 0.0, avg = 0.0, max = 0.0
    var history: [Sample] = []
}

struct SlowSnap {
    var t = 0.0
    var groups: [TempGroup] = []
    var currents: [Reading] = []
    var voltages: [Reading] = []
    var alsEvent: Double?
    var alsXYZ: [Double]?
    var alsChannels: [Double]?
    var battery: SNBattery?
}

struct RawStreamInfo: Identifiable {
    var id: UInt32
    var page: Int
    var usage: Int
    var hz: Double
    var count: Int
    var bytes: [UInt8]
    var hot: [Bool]           // byte changed within the last half second
}

struct HIDEventInfo: Identifiable {
    var id: Int
    var service: String
    var type: UInt32
    var t: Double
    var bytes: [UInt8]
}

struct Status: Equatable {
    var touchDevices: Int32 = 0
    var spuDevices: Int32 = 0
    var eventServices: Int32 = 0
    var touchHz = 0.0, accelHz = 0.0, gyroHz = 0.0
    var inputMonitoring: Int32 = 2
    var globalKeysActive = false
    var globalKeysError: Int32 = 0
    var spuActive = false
    var orientationActive = false
    var devmotionFrames = 0
}

// MARK: - Byte decoders (worked out from captures on this Mac, see CLAUDE.local.md)

enum Bytes {
    // Work on arrays and on raw C buffers alike (no copy needed for the hot path).
    static func u16<C: RandomAccessCollection>(_ b: C, _ o: Int) -> Int where C.Element == UInt8, C.Index == Int {
        o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : 0
    }
    static func u32<C: RandomAccessCollection>(_ b: C, _ o: Int) -> UInt32 where C.Element == UInt8, C.Index == Int {
        guard o + 4 <= b.count else { return 0 }
        return UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }
    static func fixed<C: RandomAccessCollection>(_ b: C, _ o: Int) -> Double where C.Element == UInt8, C.Index == Int {
        Double(Int32(bitPattern: u32(b, o))) / 65536   // 16.16 fixed point
    }
    static func f32<C: RandomAccessCollection>(_ b: C, _ o: Int) -> Double where C.Element == UInt8, C.Index == Int {
        Double(Float(bitPattern: u32(b, o)))
    }
    static func u40<C: RandomAccessCollection>(_ b: C, _ o: Int) -> UInt64 where C.Element == UInt8, C.Index == Int {
        guard o + 5 <= b.count else { return 0 }
        return (0..<5).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) }
    }
}

enum SPU {
    static func key(_ page: Int, _ usage: Int) -> UInt32 { UInt32(page) << 16 | UInt32(usage) }

    static func name(_ page: Int, _ usage: Int) -> String {
        switch (page, usage) {
        case (0xFF00, 0x03): return "accel · accelerometer"
        case (0xFF00, 0x09): return "gyro · gyroscope"
        case (0x0020, 0x8A): return "las · lid angle sensor"
        case (0xFF00, 0x04): return "als · ambient light (VD6286)"
        case (0xFF00, 0x05): return "als-temp · light-sensor temperature"
        case (0xFF0C, 0x01): return "cma · motion-coprocessor records"
        case (0xFF0C, 0x05): return "devmotion6 · fused orientation"
        case (0xFF00, 0xFF): return "wakehint · sleep/wake hint"
        default: return String(format: "0x%04X/0x%02X", page, usage)
        }
    }

    /// Human-readable decoded fields for the Raw page. "?" marks unconfirmed meanings.
    static func fields(_ page: Int, _ usage: Int, _ b: [UInt8]) -> [(String, String)] {
        switch (page, usage) {
        case (0xFF00, 0x03) where b.count >= 22:
            return [("x / y / z (g)", String(format: "%+.3f  %+.3f  %+.3f", Bytes.fixed(b, 6), Bytes.fixed(b, 10), Bytes.fixed(b, 14))),
                    ("chip temp °C", String(format: "%.2f", Bytes.fixed(b, 18))),
                    ("counter", "\(Bytes.u16(b, 0))")]
        case (0xFF00, 0x09) where b.count >= 22:
            return [("x / y / z (°/s)", String(format: "%+.2f  %+.2f  %+.2f", Bytes.fixed(b, 6), Bytes.fixed(b, 10), Bytes.fixed(b, 14))),
                    ("chip temp °C", String(format: "%.2f", Bytes.fixed(b, 18))),
                    ("counter", "\(Bytes.u16(b, 0))")]
        case (0x0020, 0x8A) where b.count >= 3:
            return [("angle °", "\(Bytes.u16(b, 1))")]
        case (0xFF00, 0x04) where b.count >= 77:
            let ch = stride(from: 20, through: 36, by: 4).map { String(Bytes.u32(b, $0)) }.joined(separator: " ")
            return [("lux", String(format: "%.2f", Bytes.f32(b, 40))),
                    ("colour temp K", String(format: "%.0f", Bytes.f32(b, 69))),
                    ("5 channels", ch),
                    ("interval µs", "\(Bytes.u32(b, 73))"),
                    ("timestamp µs", "\(Bytes.u40(b, 5))")]
        case (0xFF00, 0x05) where b.count >= 11:
            return [("temperature °C", String(format: "%.3f", Bytes.fixed(b, 2))),
                    ("counter", "\(Bytes.u16(b, 0))"),
                    ("timestamp µs", "\(Bytes.u40(b, 6))")]
        default:
            return []
        }
    }
}

// MARK: - Keyboard layout (MacBook Pro 14" 2021, US/ANSI) in macOS virtual key codes

struct KeyCap {
    var label: String
    var code: UInt16?          // nil = no key event (Touch ID / power)
    var width: Double = 1
    var code2: UInt16? = nil   // stacked arrow: code = top half, code2 = bottom half
    var halfHeight = false     // left/right arrows sit in the bottom half
}

enum KeyLayout {
    static let fCodes: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]

    static let rows: [[KeyCap]] = [
        [KeyCap(label: "esc", code: 0x35, width: 1.5)]
            + (0..<12).map { KeyCap(label: "F\($0 + 1)", code: fCodes[$0]) }
            + [KeyCap(label: "Touch ID", code: nil)],
        keys("` 1 2 3 4 5 6 7 8 9 0 - =", [0x32, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D, 0x1B, 0x18])
            + [KeyCap(label: "delete", code: 0x33, width: 1.5)],
        [KeyCap(label: "tab", code: 0x30, width: 1.5)]
            + keys("Q W E R T Y U I O P [ ] \\", [0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x10, 0x20, 0x22, 0x1F, 0x23, 0x21, 0x1E, 0x2A]),
        [KeyCap(label: "caps", code: 0x39, width: 1.75)]
            + keys("A S D F G H J K L ; '", [0x00, 0x01, 0x02, 0x03, 0x05, 0x04, 0x26, 0x28, 0x25, 0x29, 0x27])
            + [KeyCap(label: "return", code: 0x24, width: 1.75)],
        [KeyCap(label: "shift", code: 0x38, width: 2.25)]
            + keys("Z X C V B N M , . /", [0x06, 0x07, 0x08, 0x09, 0x0B, 0x2D, 0x2E, 0x2B, 0x2F, 0x2C])
            + [KeyCap(label: "shift", code: 0x3C, width: 2.25)],
        [KeyCap(label: "fn", code: 0x3F), KeyCap(label: "ctrl", code: 0x3B), KeyCap(label: "opt", code: 0x3A),
         KeyCap(label: "cmd", code: 0x37, width: 1.25), KeyCap(label: "", code: 0x31, width: 5),
         KeyCap(label: "cmd", code: 0x36, width: 1.25), KeyCap(label: "opt", code: 0x3D),
         KeyCap(label: "←", code: 0x7B, halfHeight: true), KeyCap(label: "↑", code: 0x7E, code2: 0x7D),
         KeyCap(label: "→", code: 0x7C, halfHeight: true)],
    ]
    static let width = 14.5

    private static func keys(_ labels: String, _ codes: [UInt16]) -> [KeyCap] {
        zip(labels.split(separator: " "), codes).map { KeyCap(label: String($0), code: $1) }
    }

    static let modifiers: Set<UInt16> = [0x38, 0x3C, 0x3B, 0x3E, 0x3A, 0x3D, 0x37, 0x36, 0x39, 0x3F]

    static let labels: [UInt16: String] = {
        var d: [UInt16: String] = [0x7D: "↓", 0x31: "space"]
        for row in rows { for k in row { if let c = k.code { d[c] = d[c] ?? k.label } } }
        return d
    }()

    /// HID usage (keyboard page 0x07) -> macOS virtual key code, for system-wide listening.
    static let hidToVK: [UInt32: UInt16] = {
        var m: [UInt32: UInt16] = [:]
        let letters: [UInt16] = [0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                                 0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06]
        for (i, c) in letters.enumerated() { m[UInt32(0x04 + i)] = c }   // A..Z
        let digits: [UInt16] = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]
        for (i, c) in digits.enumerated() { m[UInt32(0x1E + i)] = c }    // 1..9, 0
        let rest: [UInt32: UInt16] = [0x28: 0x24, 0x29: 0x35, 0x2A: 0x33, 0x2B: 0x30, 0x2C: 0x31, 0x2D: 0x1B,
                                      0x2E: 0x18, 0x2F: 0x21, 0x30: 0x1E, 0x31: 0x2A, 0x33: 0x29, 0x34: 0x27,
                                      0x35: 0x32, 0x36: 0x2B, 0x37: 0x2F, 0x38: 0x2C, 0x39: 0x39,
                                      0x4F: 0x7C, 0x50: 0x7B, 0x51: 0x7D, 0x52: 0x7E,
                                      0xE0: 0x3B, 0xE1: 0x38, 0xE2: 0x3A, 0xE3: 0x37,
                                      0xE4: 0x3E, 0xE5: 0x3C, 0xE6: 0x3D, 0xE7: 0x36]
        m.merge(rest) { a, _ in a }
        for (i, c) in fCodes.enumerated() { m[UInt32(0x3A + i)] = c }    // F1..F12
        return m
    }()
}

func cName(_ r: SNReading) -> String {
    withUnsafeBytes(of: r.name) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
}
