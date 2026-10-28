import Foundation
import LocalLLM

/// `LLMRunning` for `Intelligence`: every `withSession` is a background lease
/// on the shared `LLMBroker`, so analysis never loads a second copy of the
/// model beside chat.
public struct BrokeredLLMRunner: LLMRunning {
    private let broker: LLMBroker
    private let purpose: String

    public init(broker: LLMBroker, purpose: String = "summary") {
        self.broker = broker
        self.purpose = purpose
    }

    /// The broker always loads the model without a context. A non-zero
    /// `config.contextSize` is applied with `reconfigure` before `body` runs;
    /// the other load-time settings are the broker's.
    public func withSession<T: Sendable>(
        model: URL,
        config: EngineConfig,
        _ body: @Sendable (any LLMSession) async throws -> T
    ) async throws -> T {
        try await broker.withLease(model: model, priority: .background, purpose: purpose) { session in
            if config.contextSize > 0 {
                try await session.reconfigure(contextSize: config.contextSize)
            }
            return try await body(session)
        }
    }
}
