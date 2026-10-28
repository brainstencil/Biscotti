import BiscottiTestSupport
import Foundation
import Intelligence
import LocalLLM
import Testing

/// The scripted model fakes that the broker and chat tests rely on.
@Suite("Scripted LLM fakes")
struct ScriptedLLMTests {
    private enum Event: Equatable {
        case token(String)
        case done(String)
    }

    private func play(_ session: ScriptedSession) async throws -> [Event] {
        var events: [Event] = []
        let stream = await session.generateStreaming(messages: [.user("Q")], options: .default)
        for try await event in stream {
            switch event {
            case let .token(text): events.append(.token(text))
            case let .done(result): events.append(.done(result.text))
            case .reasoningToken: break
            }
        }
        return events
    }

    @Test("streams end with .done, without it, or with an error, as scripted")
    func streamEndings() async throws {
        let session = ScriptedSession(script: LLMScript(streams: [
            ScriptedStream(["a", "b"]),
            ScriptedStream(["c"], ending: .withoutDone),
            ScriptedStream(["d"], ending: .error(ScriptedLLMFailure.generationFailed))
        ]))

        #expect(try await play(session) == [.token("a"), .token("b"), .done("ab")])
        #expect(try await play(session) == [.token("c")])
        await #expect(throws: ScriptedLLMFailure.generationFailed) { try await play(session) }
        #expect(try await play(session) == [.done("")])
        #expect(session.streamingCalls.count == 4)
    }

    @Test("a consumer cancelled during a token delay gets LLMServiceError.cancelled")
    func cancelledDuringDelay() async throws {
        let session = ScriptedSession(script: LLMScript(streams: [
            ScriptedStream(["slow"], tokenDelay: .seconds(60))
        ]))
        let consumer = Task { try await play(session) }
        // The first pull takes the gate just before the delay; a consumer
        // cancelled before that pull would just see the stream end.
        try await waitUntil("the first pull") { session.isBlocked }
        consumer.cancel()

        await #expect(throws: LLMServiceError.cancelled) { try await consumer.value }
        #expect(!session.isBlocked)
    }

    @Test("a stream cancelled between pulls leaves the session blocked")
    func unfinishedStreamBlocksSession() async throws {
        let session = ScriptedSession(script: LLMScript(streams: [ScriptedStream(["a", "b"])]))
        let stream = await session.generateStreaming(messages: [], options: .default)
        let pulled = Latch()
        let resume = Latch()
        let consumer = Task {
            var events = stream.makeAsyncIterator()
            _ = try await events.next()
            pulled.open()
            await resume.wait()
            return try await events.next()
        }
        try await waitUntil("the first token") { pulled.isOpen }
        consumer.cancel()
        resume.open()

        #expect(try await consumer.value == nil)
        #expect(session.isBlocked)
        await #expect(throws: ScriptedLLMFailure.sessionBlocked) {
            _ = try await session.countTokens(messages: [])
        }
    }

    @Test("token and open delays wait on the injected clock")
    func delaysFollowTheClock() async throws {
        let clock = TestClock()
        let opener = ScriptedLLMOpener(script: LLMScript(streams: [
            ScriptedStream(["slow"], tokenDelay: .seconds(5), clock: clock)
        ]))
        opener.clock = clock
        opener.openDelay = .seconds(5)
        let opening = Task { try await opener.open(model: URL(fileURLWithPath: "/models/a.gguf"), config: .modelOnly) }
        try await waitUntil("the open to wait") { clock.pendingSleepCount == 1 }
        #expect(opener.openCount == 0)

        clock.advance(by: .seconds(5))
        let session = try #require(try await opening.value as? ScriptedSession)
        let playing = Task { try await play(session) }
        try await waitUntil("the token to wait") { clock.pendingSleepCount == 1 }
        clock.advance(by: .seconds(5))

        #expect(try await playing.value == [.token("slow"), .done("slow")])
    }

    @Test("a fast-forward clock runs sleeps at once and moves its time")
    func fastForwardClock() async throws {
        let clock = FastForwardClock()
        let start = clock.now

        for _ in 0 ..< 200 {
            try await clock.sleep(for: .microseconds(500))
        }

        #expect(start.duration(to: clock.now) == .milliseconds(100))
    }

    @Test("sessions from one opener share the script, and open errors fail one open each")
    func openerSharesScript() async throws {
        let opener = ScriptedLLMOpener(script: LLMScript(replies: ["first", "second"]))
        opener.openErrors = [ScriptedLLMFailure.openFailed]
        let model = URL(fileURLWithPath: "/models/a.gguf")

        await #expect(throws: ScriptedLLMFailure.openFailed) {
            _ = try await opener.open(model: model, config: .modelOnly)
        }
        let first = try await opener.open(model: model, config: .modelOnly)
        let second = try await opener.open(model: model, config: .modelOnly)

        #expect(try await first.generate(messages: [], options: .default) == "first")
        #expect(try await second.generate(messages: [], options: .default) == "second")
        #expect(try await second.generate(messages: [], options: .default) == "")
        #expect(opener.requests.count == 3)
        #expect(opener.openCount == 2)

        await first.close()
        #expect(opener.closeCount == 1)
    }
}
