import ArgumentParser
import LiveTranscription
import LiveTranscriptModel
import Transcription

/// The engine options the experiment compares.
enum BenchEngine: String, CaseIterable, Codable, ExpressibleByArgument {
    case whisperCurrent = "whisper-current"
    case whisperSmall = "whisper-small"
    case speechAnalyzer = "speechanalyzer"

    /// The model each Whisper option loads unless `--model` names another.
    /// The small model is the multilingual one, so Detect language still works.
    var defaultWhisperModel: String? {
        switch self {
        case .whisperCurrent: TranscriptionMethod.current.whisperModel
        case .whisperSmall: "openai_whisper-small"
        case .speechAnalyzer: nil
        }
    }
}

/// Options that cut a command short, so a dry run of the overnight schedule
/// checks every code path in minutes. The fixtures are read whole and left
/// unchanged; a cut run is recorded as such and is never a result.
struct DryRunOptions: ParsableArguments {
    @Option(help: "Replay or transcribe only the first SECONDS of each clip (dry runs only).")
    var clipSeconds: Double?

    @Option(help: "Seconds of memory baseline before the model loads (default 30; dry runs only).")
    var baselineSeconds: Int?

    func validate() throws {
        if let clipSeconds, clipSeconds <= 0 {
            throw ValidationError("--clip-seconds must be positive.")
        }
        if let baselineSeconds, baselineSeconds < 1 {
            throw ValidationError("--baseline-seconds must be at least 1.")
        }
    }
}

/// Two tracks recognized apart ("You" and "Others"), or the fallback mix.
enum BenchMode: String, CaseIterable, Codable, ExpressibleByArgument {
    case mixed
    case twoTrack = "two-track"

    var tracks: [LiveTrack] {
        self == .mixed ? [.mixed] : [.mic, .system]
    }
}

/// What Whisper decodes are prompted with (`LiveDecoderPrompt`), plus a
/// diagnostic that keeps the prompt and restores WhisperKit's timestamp rules.
enum BenchPrompt: String, CaseIterable, Codable, ExpressibleByArgument {
    case settledText = "settled-text"
    case none
    case settledTextTimestampRules = "settled-text-timestamp-rules"

    var decoderPrompt: LiveDecoderPrompt {
        self == .none ? .none : .vocabularyAndSettledText
    }

    var restoresTimestampRules: Bool {
        self == .settledTextTimestampRules
    }
}

enum BenchLoad: String, CaseIterable, Codable, ExpressibleByArgument {
    case none
    case call

    /// How reports name it.
    var label: String {
        self == .call ? "simulated call load" : "none"
    }
}
