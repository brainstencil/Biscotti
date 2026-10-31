import Foundation
import LocalLLM

/// Production `LLMRunning` backed by `LLMService.withConnection` using the
/// hosted (XPC) backend. Each `withSession` call opens a connection, loads the
/// model, runs the closure, and closes the connection. The app shares one
/// connection through `LLMBroker` and `BrokeredLLMRunner` instead; this runner
/// is for tools that have no broker.
public struct LiveLLMRunner: LLMRunning {
    /// The XPC service bundle identifier for BiscottiLLM.
    static let serviceName = "net.scosman.biscotti.BiscottiLLM"

    public init() {}

    public func withSession<T: Sendable>(
        model: URL,
        config: EngineConfig,
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T {
        try await LLMService.withConnection(
            model: model,
            backend: .hosted(serviceName: Self.serviceName),
            config: config
        ) { connection in
            try await body(LiveLLMSession(connection: connection))
        }
    }
}

/// Production `LLMConnectionOpening` for `LLMBroker`: opens a connection to
/// the hosted (XPC) backend that stays open until the broker closes it.
public struct LiveLLMConnectionOpener: LLMConnectionOpening {
    private let serviceName: String

    public init(serviceName: String = "net.scosman.biscotti.BiscottiLLM") {
        self.serviceName = serviceName
    }

    public func open(model: URL, config: EngineConfig) async throws -> any LLMOpenSession {
        let connection = try await LLMService.openConnection(
            model: model,
            backend: .hosted(serviceName: serviceName),
            config: config
        )
        return LiveLLMSession(connection: connection)
    }
}

/// Production `LLMSession` wrapping a live `LLMConnection`.
struct LiveLLMSession: LLMOpenSession, @unchecked Sendable {
    let connection: LLMConnection

    func close() async {
        await connection.close()
    }

    func countTokens(
        messages: [LLMMessage]
    ) async throws -> Int {
        try await connection.countTokens(messages: messages)
    }

    func reconfigure(contextSize: Int) async throws {
        try await connection.reconfigure(contextSize: contextSize)
    }

    func generate(
        messages: [LLMMessage], options: GenerationOptions
    ) async throws -> String {
        let result = try await connection.generate(
            messages: messages, options: options
        )
        return result.text
    }

    func generateStreaming(
        messages: [LLMMessage], options: GenerationOptions
    ) async -> AsyncThrowingStream<StreamEvent, Error> {
        await connection.generateStreaming(
            messages: messages, options: options
        )
    }
}
