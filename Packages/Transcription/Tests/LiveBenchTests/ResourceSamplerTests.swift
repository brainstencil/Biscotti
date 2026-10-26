import Foundation
import Testing
@testable import live_bench

@Suite("Resource sampling")
struct ResourceSamplerTests {
    @Test("the system and process probes read plausible values")
    func probesReadPlausibleValues() {
        let memory = SystemMemory.current()
        let process = ProcessMemory.current()

        #expect(memory.wiredBytes > 0 && memory.activeBytes > 0)
        #expect(memory.usedBytes < ProcessInfo.processInfo.physicalMemory)
        #expect(process.footprintBytes > 0 && process.residentBytes > 0)
        #expect(["normal", "warning", "critical"].contains(SystemMemory.pressure()))
        #expect(sysctlString("hw.model")?.isEmpty == false)
        #expect((sysctlValue("hw.memsize") as UInt64?) == ProcessInfo.processInfo.physicalMemory)
        #expect((SystemLoad.oneMinuteAverage() ?? -1) >= 0)
        #expect(CPUTicks.current() != nil)
    }

    @Test("the idle share counts only the ticks since the previous sample")
    func idleShareUsesTheDifference() {
        let before = CPUTicks(busy: 1000, idle: 9000)

        #expect(CPUTicks(busy: 1300, idle: 9100).idleShare(since: before) == 0.25)
        #expect(before.idleShare(since: before) == nil, "no ticks counted")
        #expect(CPUTicks(busy: 10, idle: 10).idleShare(since: before) == nil, "counters that went backwards")
    }

    @Test("the sampler writes a sample tagged with the current phase as soon as it starts")
    func samplerWritesTaggedSamples() async throws {
        let temporary = try TemporaryFolder()
        defer { temporary.remove() }
        let url = temporary.url.appending(path: "resources.jsonl")
        let sampler = try ResourceSampler(writer: JSONLinesWriter(url: url))
        sampler.setPhase("clip:smoke")

        sampler.start()
        #expect(await eventually { (try? jsonLines(url).count) ?? 0 >= 1 })
        sampler.stop()

        let sample = try #require(try jsonLines(url).first)
        #expect(sample["phase"] as? String == "clip:smoke")
        for key in ["elapsed", "system_used_bytes", "active_bytes", "wired_bytes", "compressed_bytes", "process_footprint_bytes", "process_resident_bytes", "memory_pressure", "thermal_state", "one_minute_load_average"] {
            #expect(sample[key] != nil, "\(key)")
        }
    }
}
