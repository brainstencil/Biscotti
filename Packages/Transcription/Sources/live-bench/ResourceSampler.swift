import Darwin
import Foundation
import Synchronization

/// One line of `resources.jsonl`.
struct ResourceSample: Encodable {
    /// Seconds since sampling started.
    var elapsed: TimeInterval
    /// `baseline`, `load-model` or `clip:<id>`.
    var phase: String
    /// Active + wired + compressed pages: the endurance gate's figure, so a
    /// model outside the process counts the same as one inside it.
    var systemUsedBytes: UInt64
    var activeBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var processFootprintBytes: UInt64
    var processResidentBytes: UInt64
    var memoryPressure: String
    var thermalState: String
    /// The 1-minute load average: how many threads wanted a CPU. Other work
    /// on the Mac skews real-time latency, so report.py flags busy runs.
    var oneMinuteLoadAverage: Double?
    /// Share of all CPU time idle since the previous sample; nil for the first.
    var cpuIdle: Double?
}

/// The memory baseline in the manifest, taken before the model loads.
struct MemoryBaseline: Codable, Equatable {
    var seconds: Double
    var samples: Int
    var medianUsedBytes: UInt64
}

/// Samples memory, pressure, heat and system load once a second into `resources.jsonl`.
final class ResourceSampler: Sendable {
    static let interval = Duration.seconds(1)

    private struct State {
        var phase = "idle"
        var baselineValues: [UInt64] = []
        var cpuTicks: CPUTicks?
        var task: Task<Void, Never>?
    }

    private let writer: JSONLinesWriter
    private let state = Mutex(State())

    init(writer: JSONLinesWriter) {
        self.writer = writer
    }

    func start() {
        let start = ContinuousClock.now
        let task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled, let self {
                record(at: start.duration(to: .now).seconds)
                try? await Task.sleep(for: Self.interval)
            }
        }
        state.withLock { $0.task = task }
    }

    func stop() {
        state.withLock { $0.task }?.cancel()
    }

    func setPhase(_ phase: String) {
        state.withLock { $0.phase = phase }
    }

    /// Samples for `seconds` under the current load, before the model loads,
    /// and returns the median system memory in use.
    func measureBaseline(seconds: Int) async throws -> MemoryBaseline {
        setPhase("baseline")
        try await Task.sleep(for: .seconds(seconds))
        let values = state.withLock { $0.baselineValues }.sorted()
        return MemoryBaseline(seconds: Double(seconds), samples: values.count, medianUsedBytes: values.isEmpty ? 0 : values[values.count / 2])
    }

    private func record(at time: TimeInterval) {
        let memory = SystemMemory.current()
        let process = ProcessMemory.current()
        let ticks = CPUTicks.current()
        let (phase, previousTicks) = state.withLock { state in
            if state.phase == "baseline" {
                state.baselineValues.append(memory.usedBytes)
            }
            defer { state.cpuTicks = ticks }
            return (state.phase, state.cpuTicks)
        }
        let sample = ResourceSample(
            elapsed: time,
            phase: phase,
            systemUsedBytes: memory.usedBytes,
            activeBytes: memory.activeBytes,
            wiredBytes: memory.wiredBytes,
            compressedBytes: memory.compressedBytes,
            processFootprintBytes: process.footprintBytes,
            processResidentBytes: process.residentBytes,
            memoryPressure: SystemMemory.pressure(),
            thermalState: ProcessInfo.processInfo.thermalState.label,
            oneMinuteLoadAverage: SystemLoad.oneMinuteAverage(),
            cpuIdle: previousTicks.flatMap { previous in ticks.flatMap { $0.idleShare(since: previous) } }
        )
        try? writer.write(sample)
    }
}

/// System-wide memory from `host_statistics64`.
struct SystemMemory {
    var activeBytes: UInt64 = 0
    var wiredBytes: UInt64 = 0
    var compressedBytes: UInt64 = 0

    var usedBytes: UInt64 {
        activeBytes + wiredBytes + compressedBytes
    }

    static func current() -> SystemMemory {
        let host = mach_host_self()
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else { return SystemMemory() }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return SystemMemory() }
        let page = UInt64(pageSize)
        return SystemMemory(
            activeBytes: UInt64(stats.active_count) * page,
            wiredBytes: UInt64(stats.wire_count) * page,
            compressedBytes: UInt64(stats.compressor_page_count) * page
        )
    }

    /// The kernel's memory pressure level: normal, warning or critical.
    static func pressure() -> String {
        guard let level: Int32 = sysctlValue("kern.memorystatus_vm_pressure_level") else { return "unknown" }
        switch level {
        case 1: return "normal"
        case 2: return "warning"
        case 4: return "critical"
        default: return "level-\(level)"
        }
    }
}

/// How busy the whole Mac is.
enum SystemLoad {
    static func oneMinuteAverage() -> Double? {
        var averages = [Double](repeating: 0, count: 3)
        return getloadavg(&averages, 3) >= 1 ? averages[0] : nil
    }
}

/// CPU time ticks summed over all cores, from `host_statistics(HOST_CPU_LOAD_INFO)`.
struct CPUTicks: Equatable {
    var busy: UInt64
    var idle: UInt64

    static func current() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return CPUTicks(busy: UInt64(ticks.0) + UInt64(ticks.1) + UInt64(ticks.3), idle: UInt64(ticks.2))
    }

    /// The idle share of the ticks counted since `previous`, or nil when none were.
    func idleShare(since previous: CPUTicks) -> Double? {
        let busy = busy &- previous.busy
        let idle = idle &- previous.idle
        guard busy < 1 << 62, idle < 1 << 62, busy + idle > 0 else { return nil }
        return Double(idle) / Double(busy + idle)
    }
}

/// This process's memory, from `proc_pid_rusage`.
struct ProcessMemory {
    var footprintBytes: UInt64 = 0
    var residentBytes: UInt64 = 0

    static func current() -> ProcessMemory {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return ProcessMemory() }
        return ProcessMemory(footprintBytes: usage.ri_phys_footprint, residentBytes: usage.ri_resident_size)
    }
}

/// Reads a fixed-size `sysctl` value.
func sysctlValue<Value: FixedWidthInteger>(_ name: String) -> Value? {
    var value = Value.zero
    var size = MemoryLayout<Value>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
}

/// Reads a `sysctl` string such as `hw.model`.
func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
