import SensoriumCore
import CSensors
import Darwin
import Foundation

/// Sensorium's own load: CPU (100% = one full core), memory footprint (the number
/// Activity Monitor shows as "Memory") and thread count.
struct ProcSample {
    var t: Double
    var cpu: Double
    var footprintMB: Double
    var threads: Int
}

/// Whole-Mac load: per-core CPU and memory in use.
struct SystemSample {
    var cores: [Double] = []          // 0...100 per core
    var memUsedGB = 0.0
    var memTotalGB = 0.0
    var compressedGB = 0.0
}

final class PerfMeter {
    private var lastCPU = 0.0, lastT = 0.0
    private var lastTicks: [[UInt32]] = []

    /// Total CPU seconds this process has used (user + system).
    static func cpuSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
             + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func threadCount() -> Int {
        var list: thread_act_array_t?
        var n: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &n) == KERN_SUCCESS, let list else { return 0 }
        for i in 0..<Int(n) { mach_port_deallocate(mach_task_self_, list[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(n) * MemoryLayout<thread_t>.stride))
        return Int(n)
    }

    func sampleProcess() -> ProcSample {
        let now = sn_now(), cpu = Self.cpuSeconds()
        let pct = lastT > 0 ? (cpu - lastCPU) / max(0.001, now - lastT) * 100 : 0
        lastCPU = cpu
        lastT = now
        return ProcSample(t: now, cpu: pct, footprintMB: Self.footprintMB(), threads: Self.threadCount())
    }

    func sampleSystem() -> SystemSample {
        var s = SystemSample()
        // per-core ticks (user, system, idle, nice) -> busy share since the last sample
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info {
            var ticks: [[UInt32]] = []
            for c in 0..<Int(count) {
                let base = c * Int(CPU_STATE_MAX)
                ticks.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[base + $0]) })
            }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
            if lastTicks.count == ticks.count {
                s.cores = zip(ticks, lastTicks).map { now, old in
                    let d = (0..<4).map { Double(now[$0] &- old[$0]) }
                    let busy = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_SYSTEM)] + d[Int(CPU_STATE_NICE)]
                    let total = busy + d[Int(CPU_STATE_IDLE)]
                    return total > 0 ? busy / total * 100 : 0
                }
            }
            lastTicks = ticks
        }
        // memory: app + wired + compressed, like Activity Monitor's "Memory Used"
        var vm = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        let page = Double(vm_kernel_page_size)
        s.memTotalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if kr == KERN_SUCCESS {
            let appPages = Double(vm.internal_page_count) - Double(vm.purgeable_count)
            s.memUsedGB = (appPages + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page / 1_073_741_824
            s.compressedGB = Double(vm.compressor_page_count) * page / 1_073_741_824
        }
        return s
    }
}
