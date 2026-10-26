import Foundation
import Testing
@testable import live_bench

@Suite("Paced source")
struct PacedSourceTests {
    @Test("a real-time source releases only the steps whose time has come")
    func pacedSourceReleasesOnlyArrivedSamples() async throws {
        let clock = VirtualClock()
        let source = PacedSource(sampleCount: 16000, pacing: .realTime(clock))
        let releasing = Task {
            while try await source.releaseNextStep() {}
        }

        #expect(await eventually { clock.sleeperCount == 1 })
        #expect(source.releasedSamples == 0)

        clock.advance(by: .milliseconds(250))
        #expect(await eventually { source.releasedSamples == 3200 && clock.sleeperCount == 1 })
        #expect(source.releasedSamples == 3200)
        #expect(source.releasedThrough == 0.2)

        clock.advance(by: .seconds(1))
        try await releasing.value
        #expect(source.releasedSamples == 16000)
        #expect(!source.isSimulated)
    }

    @Test("a simulated source runs through its steps without waiting and moves the shared clock")
    func virtualClockAdvancesWithoutWaiting() async throws {
        let clock = VirtualClock()
        let source = PacedSource(sampleCount: 60 * 16000, pacing: .simulated(clock))
        let wallStart = ContinuousClock.now

        var steps = 0
        while try await source.releaseNextStep() {
            steps += 1
            #expect(clock.now.offset == PacedSource.step * steps)
        }

        #expect(ContinuousClock.now - wallStart < .seconds(1))
        #expect(steps == 600)
        #expect(clock.now.offset == .seconds(60))
        #expect(source.releasedThrough == 60)
        #expect(source.isSimulated)
    }

    @Test("a virtual-clock sleep cancelled before it registers still ends", .timeLimit(.minutes(1)))
    func sleepCancelledBeforeItStartsEnds() async {
        let clock = VirtualClock()
        let sleeping = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await clock.sleep(for: .seconds(1))
        }

        let result = await sleeping.result

        #expect(throws: CancellationError.self) { try result.get() }
        #expect(clock.sleeperCount == 0)
    }

    @Test("the last step releases a partial step and then the source is done")
    func lastStepReleasesTheRemainder() async throws {
        let source = PacedSource(sampleCount: 2000, pacing: .simulated(VirtualClock()))

        #expect(try await source.releaseNextStep())
        #expect(source.releasedSamples == 1600)
        #expect(try await source.releaseNextStep())
        #expect(source.releasedSamples == 2000)
        #expect(try await !source.releaseNextStep())
    }
}
