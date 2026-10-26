import Foundation

/// A failure `live-bench` reports before it exits. Each message names the
/// flag, folder or file involved, so it can be fixed without reading code.
enum BenchError: Error, Equatable, LocalizedError, CustomStringConvertible {
    case productionPath(flag: String, path: String)
    case invalidName(flag: String, value: String)
    case duplicateClip(String)
    case invalidInterval(Double)
    case missingModelFolder(String)
    case missingModelFile(file: String, folder: String)
    case unknownTokenizer(model: String)
    case missingTokenizer(searched: [String])
    case missingClip(id: String, folder: String)
    case unreadableAudio(path: String, reason: String)
    case clipTooShort(id: String, seconds: Double, needed: Double)
    case outputExists(String)
    case noMetalDevice
    case speechAnalyzerNeedsMacOS26(found: String)
    case speechAssetNotInstalled(String)
    case speechLocaleUnsupported(String)

    var description: String {
        switch self {
        case let .productionPath(flag, path):
            "\(flag) resolves to \(path), which is production Biscotti (its data folder or the installed app). Use a folder outside it."
        case let .invalidName(flag, value):
            "\(flag) value \"\(value)\" must be a single folder name, without \"/\" or \"..\"."
        case let .duplicateClip(id):
            "--clips lists \"\(id)\" more than once; a run replays each clip once."
        case let .invalidInterval(seconds):
            "--interval must be 1, 2 or 4 seconds, not \(String(format: "%g", seconds))."
        case let .missingModelFolder(folder):
            "Model folder not found: \(folder). live-bench never downloads models; copy the model there first."
        case let .missingModelFile(file, folder):
            "\(file) (.mlmodelc or .mlpackage) is missing from the model folder \(folder)."
        case let .unknownTokenizer(model):
            "Cannot tell which Whisper tokenizer model \"\(model)\" uses; put its tokenizer.json in the model folder."
        case let .missingTokenizer(searched):
            "tokenizer.json not found in: \(searched.joined(separator: ", ")). live-bench never downloads tokenizers."
        case let .missingClip(id, folder):
            "Clip \"\(id)\" not found: \(folder) needs mic.wav, system.wav and meta.json (run make_fixtures.py)."
        case let .unreadableAudio(path, reason):
            "Cannot use \(path): \(reason)"
        case let .clipTooShort(id, seconds, needed):
            "Clip \"\(id)\" is \(String(format: "%.1f", seconds)) s long; this command needs at least \(String(format: "%.0f", needed)) s."
        case let .outputExists(path):
            "Output folder \(path) already exists; results are never overwritten."
        case .noMetalDevice:
            "--load call needs a Metal GPU, and none was found."
        case let .speechAnalyzerNeedsMacOS26(found):
            "--option speechanalyzer needs macOS 26 or later; this Mac runs \(found)."
        case let .speechAssetNotInstalled(locale):
            "SpeechAnalyzer's \(locale) model is not installed for this live-bench build. Run `speech-assets --locale \(locale) --install` once with the same build (for example make bench-live ARGS=\"speech-assets --install\"); the system downloads and keeps it."
        case let .speechLocaleUnsupported(locale):
            "SpeechAnalyzer does not support the locale \(locale) on this Mac."
        }
    }

    var errorDescription: String? {
        description
    }
}
