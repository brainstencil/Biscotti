import Foundation
import LiveTranscription
import LiveTranscriptModel
@testable import live_bench

/// A fresh folder under the temporary directory, removed by `remove()`.
struct TemporaryFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appending(path: "LiveBenchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func folder(_ path: String) throws -> URL {
        let folder = url.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    func file(_ path: String, contents: String = "x") throws -> URL {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Answers each decode with the scripted words that lie inside the window.
struct ScriptedDecoder: LiveDecoder {
    let words: [TimedWord]

    func decode(_ samples: [Float], startTime: TimeInterval, options _: LiveDecodeOptions) async throws -> LiveDecodeResult {
        let end = startTime + Double(samples.count) / LiveAudioChunk.sampleRate
        let heard = words.filter { $0.start >= startTime && $0.end <= end }
        return LiveDecodeResult(hypothesis: Hypothesis(words: heard, windowStart: startTime, windowEnd: end), language: "en")
    }
}

struct DecodeFailure: Error {}

/// Fails every decode, which ends the session.
struct FailingDecoder: LiveDecoder {
    func decode(_: [Float], startTime _: TimeInterval, options _: LiveDecodeOptions) async throws -> LiveDecodeResult {
        throw DecodeFailure()
    }
}

/// Hears "hello" early on, then never answers the decode that reaches `end`:
/// the last decode while finishing.
struct HangingFinalDecoder: LiveDecoder {
    let end: TimeInterval

    func decode(_ samples: [Float], startTime: TimeInterval, options: LiveDecodeOptions) async throws -> LiveDecodeResult {
        let windowEnd = startTime + Double(samples.count) / LiveAudioChunk.sampleRate
        if windowEnd >= end - 1e-6 {
            try await Task.sleep(for: .seconds(3600))
        }
        let hello = TimedWord(text: " hello", start: 0.2, end: 0.5, probability: 0.9)
        return try await ScriptedDecoder(words: [hello]).decode(samples, startTime: startTime, options: options)
    }
}

/// A model folder in the app's cache layout, with every required model.
@discardableResult
func makeModel(_ name: String, in models: TemporaryFolder, tokenizer: Bool = true) throws -> URL {
    let base = "models/argmaxinc/whisperkit-coreml/\(name)"
    for model in WhisperModelLocation.requiredModels {
        try models.file("\(base)/\(model).mlmodelc/coremldata.bin", contents: model)
    }
    if tokenizer {
        try models.file("\(base)/tokenizer.json", contents: "{}")
    }
    return models.url.appending(path: base)
}

/// Lines of a JSON Lines file as dictionaries.
func jsonLines(_ url: URL) throws -> [[String: Any]] {
    try String(contentsOf: url, encoding: .utf8)
        .split(separator: "\n")
        .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:] }
}

func jsonObject(_ url: URL) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
}

/// Polls `condition` until it holds or about two seconds pass.
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 2000 {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}
