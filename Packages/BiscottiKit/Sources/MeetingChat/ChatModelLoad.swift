import Foundation
import Synchronization

/// A model load that chat waits for, as the loading bar shows it.
public struct ChatModelLoad: Equatable, Sendable {
    let id: UUID
    /// When the broker started loading the model.
    public let startedAt: Date
    /// How long the last load of this model took on this Mac; nil before the
    /// first one.
    public let estimate: Duration?
}

/// What chat keeps in UserDefaults about the AI model: the "Keep the AI model
/// ready" setting, and how long each model file last took to load on this
/// Mac, which the loading bar fills against.
struct ChatModelRecords {
    static let keepModelReadyKey = "meetingChat.keepModelReady"
    static let loadSecondsKeyPrefix = "meetingChat.modelLoadSeconds."

    /// Nil keeps nothing: the setting starts off and no load has an estimate.
    let defaults: UserDefaults?

    var keepsModelReady: Bool {
        defaults?.bool(forKey: Self.keepModelReadyKey) ?? false
    }

    func keepModelReady(_ isOn: Bool) {
        defaults?.set(isOn, forKey: Self.keepModelReadyKey)
    }

    /// The last measured load of `model`, by its file name.
    func lastLoadDuration(of model: URL) -> Duration? {
        guard let seconds = defaults?.object(forKey: Self.loadKey(model)) as? Double, seconds > 0 else { return nil }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }

    func recordLoad(_ duration: Duration, of model: URL) {
        defaults?.set(duration / .seconds(1), forKey: Self.loadKey(model))
    }

    static func loadKey(_ model: URL) -> String {
        loadSecondsKeyPrefix + model.lastPathComponent
    }
}

/// Times one model load that a chat lease may start, on the service's clock.
/// The broker reports the start from its own actor and chat ends it on the
/// main actor, so the start is kept here rather than in main-actor state.
final class ChatLoadTimer: Sendable {
    let id = UUID()
    private let state = Mutex<(started: Duration?, ended: Bool)>((nil, false))

    var hasEnded: Bool {
        state.withLock { $0.ended }
    }

    func start(at time: Duration) {
        state.withLock { state in
            if state.started == nil, !state.ended { state.started = time }
        }
    }

    /// Ends the timer, and returns the load's start the first time, if it started.
    func end() -> Duration? {
        state.withLock { state in
            defer { state = (nil, true) }
            return state.started
        }
    }
}
