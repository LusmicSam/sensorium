import SensoriumCore
import SwiftUI

struct PerformancePage: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        let p = hub.proc, h = hub.procHistory, sys = hub.system
        let t1 = h.last?.t ?? 0
        VStack(spacing: 14) {
            Card("Sensorium's own load", subtitle: "sampled once a second · 100% CPU = one full core") {
                HStack(spacing: 28) {
                    Stat(label: "CPU now", value: fmt(p.cpu, 1, " %"))
                    Stat(label: "CPU average (last 60 s)", value: fmt(avg(h.suffix(60).map(\.cpu)), 1, " %"))
                    Stat(label: "memory", value: fmt(p.footprintMB, 1, " MB"))
                    Stat(label: "threads", value: "\(p.threads)")
                }
                Text("CPU %").font(.caption).foregroundStyle(.secondary)
                LineGraph(series: [Series(color: .orange, points: h.map { GPoint(t: $0.t, v: $0.cpu) })],
                          tMin: t1 - 120, tMax: t1, vMin: 0, vMax: max(10, (h.map(\.cpu).max() ?? 0) * 1.2))
                    .frame(height: 90)
                Text("Memory MB").font(.caption).foregroundStyle(.secondary)
                LineGraph(series: [Series(color: Neon.z, points: h.map { GPoint(t: $0.t, v: $0.footprintMB) })],
                          tMin: t1 - 120, tMax: t1, vMin: 0, vMax: max(50, (h.map(\.footprintMB).max() ?? 0) * 1.3))
                    .frame(height: 70)
            }
            Card("Whole Mac", subtitle: "\(sys.cores.count) cores") {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(sys.cores.enumerated()), id: \.offset) { i, load in
                        VStack(spacing: 3) {
                            GeometryReader { g in
                                VStack { Spacer(minLength: 0)
                                    RoundedRectangle(cornerRadius: 3).fill(heatColor(load / 100))
                                        .frame(height: max(2, g.size.height * load / 100))
                                }
                            }
                            .frame(width: 26, height: 80)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
                            Text("\(Int(load))%").font(.caption2.monospacedDigit())
                            Text(i < 2 ? "E\(i + 1)" : "P\(i - 1)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 8) {
                        Stat(label: "memory used", value: "\(fmt(sys.memUsedGB, 1)) of \(fmt(sys.memTotalGB, 0)) GB")
                        Stat(label: "compressed", value: fmt(sys.compressedGB, 2, " GB"))
                    }
                }
            }
        }
        .needs(.perf)
    }

    private func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
}
