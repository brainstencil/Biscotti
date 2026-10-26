import Foundation
import LiveTranscription
import LiveTranscriptModel

/// The live engine a `run` replays through, checked before anything is measured.
enum ReplayEngine {
    case whisper(WhisperModelLocation, BenchPrompt)
    /// SpeechAnalyzer's model is the system's, so there is nothing to load.
    case speechAnalyzer(ReplaySessions)

    /// The fixtures are English meetings.
    static let speechAnalyzerLocale = "en-US"

    /// Finds the Whisper model, or checks that SpeechAnalyzer runs here and
    /// its model is installed for live-bench.
    static func locate(option: BenchEngine, model: String?, fastResults: Bool, prompt: BenchPrompt, in models: URL) async throws -> ReplayEngine {
        guard option == .speechAnalyzer else {
            let name = model ?? option.defaultWhisperModel ?? ""
            return try .whisper(WhisperModelLocation.locate(name: name, in: models), prompt)
        }
        guard #available(macOS 26, *) else {
            throw BenchError.speechAnalyzerNeedsMacOS26(found: ProcessInfo.processInfo.operatingSystemVersionString)
        }
        let locale = speechAnalyzerLocale
        switch await SpeechAnalyzerAssets.status(locale: locale) {
        case .installed:
            return .speechAnalyzer(ReplaySessions(engine: .speechAnalyzer, whisperModel: nil, language: .locale(locale)) { _ in
                let session = SpeechAnalyzerLiveSession(fastResults: fastResults)
                return (session, session.replayControl())
            })
        case .unsupported:
            throw BenchError.speechLocaleUnsupported(locale)
        case .notInstalled, .downloading:
            throw BenchError.speechAssetNotInstalled(locale)
        }
    }

    /// The Whisper model folder; nil for SpeechAnalyzer.
    var whisperLocation: WhisperModelLocation? {
        if case let .whisper(location, _) = self { location } else { nil }
    }

    /// Loads what every clip's session shares: the Whisper model.
    func load() async throws -> ReplaySessions {
        switch self {
        case let .whisper(location, prompt):
            let decoder = try await WhisperKitLiveDecoder(whisperKit: location.load(restoringTimestampRules: prompt.restoresTimestampRules), prompt: prompt.decoderPrompt)
            return ReplaySessions(engine: .whisper, whisperModel: location.name, language: .english) { virtualClock in
                let session = virtualClock.map { WhisperLiveSession(decoder: decoder, clock: $0, scheduling: .manual) } ?? WhisperLiveSession(decoder: decoder)
                return (session, session.replayControl(virtualClock: virtualClock))
            }
        case let .speechAnalyzer(sessions):
            return sessions
        }
    }
}

/// Makes a fresh session for each clip, with what its config needs.
struct ReplaySessions {
    let engine: LiveEngineKind
    let whisperModel: String?
    let language: LiveLanguage
    /// - Parameter virtualClock: The clock a `--virtual-clock` session reads; Whisper only.
    let make: @Sendable (_ virtualClock: VirtualClock?) -> (session: any LiveTranscriptionSession, control: SessionControl)

    func config(tracks: [LiveTrack], interval: TimeInterval, vocabulary: [String]) -> LiveSessionConfig {
        LiveSessionConfig(
            sessionID: UUID(),
            generation: 1,
            engine: engine,
            whisperModel: whisperModel,
            tracks: tracks,
            updateInterval: interval,
            language: language,
            vocabulary: vocabulary
        )
    }
}

extension WhisperLiveSession {
    /// - Parameter virtualClock: The clock a `.manual` session reads, for `--virtual-clock` runs.
    nonisolated func replayControl(virtualClock: VirtualClock?) -> SessionControl {
        SessionControl(
            runPass: { await self.runScheduledWork() },
            latestRevision: { await self.latestRevision },
            hasEnded: { await self.hasEnded },
            expireFinishDeadline: { virtualClock?.advance(by: $0) }
        )
    }
}

extension SpeechAnalyzerLiveSession {
    /// SpeechAnalyzer runs on its own time: there is no pass to run and no
    /// virtual deadline to move.
    nonisolated func replayControl() -> SessionControl {
        SessionControl(
            runPass: {},
            latestRevision: { await self.latestRevision },
            hasEnded: { await self.hasEnded },
            expireFinishDeadline: { _ in }
        )
    }
}
