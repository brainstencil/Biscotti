import Foundation
import WhisperKit

/// A Whisper model and its tokenizer inside the `--models` folder, laid out
/// as the app's model cache: `argmaxinc/whisperkit-coreml/<name>` and
/// `openai/whisper-<size>/tokenizer.json`.
///
/// The harness loads models only from here. It never calls `ModelStorage`,
/// which would point at the production cache, and never downloads.
struct WhisperModelLocation: Equatable {
    static let repository = "argmaxinc/whisperkit-coreml"
    static let requiredModels = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    let name: String
    let folder: URL
    let tokenizerFolder: URL

    /// Checks that the model files and a tokenizer are present. Loads nothing.
    static func locate(name: String, in models: URL) throws -> Self {
        try PathGuard.checkName(name, flag: "--model")
        let folder = models.appending(path: repository, directoryHint: .isDirectory).appending(path: name, directoryHint: .isDirectory)
        guard directoryExists(folder) else { throw BenchError.missingModelFolder(folder.path) }
        for model in requiredModels where !["mlmodelc", "mlpackage"].contains(where: { directoryExists(folder.appending(path: "\(model).\($0)")) }) {
            throw BenchError.missingModelFile(file: model, folder: folder.path)
        }
        return try Self(name: name, folder: folder, tokenizerFolder: tokenizerFolder(for: name, folder: folder, models: models))
    }

    /// The Hugging Face repository of the tokenizer WhisperKit would pick for
    /// this model, from its folder name (e.g. `openai_whisper-small.en`).
    static func tokenizerRepository(forModel name: String) -> String? {
        let lowered = name.lowercased()
        let sizes = ["large-v3", "large-v2", "large", "medium", "small", "base", "tiny"]
        guard let size = sizes.first(where: { lowered.contains($0) }) else { return nil }
        let englishOnly = !size.hasPrefix("large") && lowered.contains("\(size).en")
        return "openai/whisper-\(size)\(englishOnly ? ".en" : "")"
    }

    /// Loads the model with WhisperKit, from these folders only.
    /// - Parameter restoringTimestampRules: Adds `PromptedTimestampRules`, a
    ///   diagnostic for prompted decodes.
    func load(restoringTimestampRules: Bool = false) async throws -> WhisperKit {
        let whisperKit = try await WhisperKit(WhisperKitConfig(
            modelFolder: folder.path,
            tokenizerFolder: tokenizerFolder,
            verbose: false,
            prewarm: false,
            load: true,
            download: false
        ))
        if restoringTimestampRules, let tokenizer = whisperKit.tokenizer {
            whisperKit.textDecoder.logitsFilters = [PromptedTimestampRules(specialTokens: tokenizer.specialTokens, isModelMultilingual: whisperKit.textDecoder.isModelMultilingual)]
        }
        return whisperKit
    }

    /// WhisperKit searches a model folder that bundles `tokenizer.json`, then
    /// the folder it is given; if both miss it downloads, so this checks first.
    private static func tokenizerFolder(for name: String, folder: URL, models: URL) throws -> URL {
        if hasTokenizer(folder) {
            return folder
        }
        guard let repository = tokenizerRepository(forModel: name) else { throw BenchError.unknownTokenizer(model: name) }
        let shared = models.appending(path: repository, directoryHint: .isDirectory)
        guard hasTokenizer(shared) else { throw BenchError.missingTokenizer(searched: [folder.path, shared.path]) }
        return shared
    }

    private static func hasTokenizer(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: "tokenizer.json").path)
    }

    private static func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
