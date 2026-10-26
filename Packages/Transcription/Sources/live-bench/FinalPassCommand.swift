import ArgumentParser
import Foundation
import Transcription
import WhisperKit

/// `live-bench final-pass`: the final pass's words on each clip, for the
/// accuracy gate's "no more than 3 points worse than the final pass".
///
/// Not in the component spec, which gives no way to get that baseline: the
/// app's engine and `transcribe-cli` load models through `ModelStorage`, the
/// production cache. This command merges the tracks with `AudioMerger` and
/// decodes with the current method's options, as the final pass does, but
/// loads the model from `--models`. Diarization does not affect WER, so it is
/// left out.
struct FinalPassCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "final-pass",
        abstract: "Transcribe clips the way the final pass does, for the accuracy baseline.",
        discussion: "Writes <out>/<timestamp>-final-pass/ with manifest.json and <clip>/final_pass.json."
    )

    @OptionGroup var paths: BenchPaths

    @Option(help: "Comma-separated clip IDs.")
    var clips: String

    @Option(help: "A Whisper model folder name instead of the current method's.")
    var model: String?

    @Option(help: "Transcribe only the first SECONDS of each clip (dry runs only).")
    var clipSeconds: Double?

    func validate() throws {
        if let clipSeconds, clipSeconds <= 0 {
            throw ValidationError("--clip-seconds must be positive.")
        }
    }

    func run() async throws {
        let resolved = try paths.resolve()
        let modelName = model ?? TranscriptionMethod.current.whisperModel
        let location = try WhisperModelLocation.locate(name: modelName, in: resolved.models)
        let clipIDs = try parseClipIDs(clips)
        let audio = try clipIDs.map { try ClipAudio.load(id: $0, fixtures: resolved.fixtures).prefix(seconds: clipSeconds) }
        let folder = try makeResultsFolder(in: resolved.out, named: "\(folderTimestamp())-final-pass" + (model.map { "-\($0)" } ?? ""))
        progress("Results: \(folder.path)")
        var manifest = try BenchManifest.make(kind: "final-pass", options: OptionsRecord(model: modelName, clips: clipIDs, finalPassModel: TranscriptionMethod.current.whisperModel, clipSeconds: clipSeconds), model: location, fixtures: resolved.fixtures)
        try manifest.write(to: folder)

        let loadStart = ContinuousClock.now
        let transcriber = try await FinalPassTranscriber(location: location)
        manifest.model?.loadSeconds = loadStart.duration(to: .now).seconds
        for (index, clip) in audio.enumerated() {
            progress("Transcribing \(clip.id)…")
            var session = SessionRecord(clip: clip.id, warm: index > 0, startedAt: BenchManifest.timestamp())
            let record = try await transcriber.transcribe(clip)
            let clipFolder = folder.appending(path: clip.id, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: clipFolder, withIntermediateDirectories: false)
            try BenchJSON.write(record, to: clipFolder.appending(path: "final_pass.json"))
            session.finishSeconds = record.seconds
            manifest.sessions.append(session)
            try manifest.write(to: folder)
        }
    }
}

struct FinalPassRecord: Encodable {
    var clip: String
    var language: String?
    /// Decode time, seconds.
    var seconds: Double
    var words: [FinalPassWord]
}

struct FinalPassWord: Encodable {
    var text: String
    var start: Double
    var end: Double
    var probability: Float
}

/// Owns the loaded model, which is not `Sendable`.
actor FinalPassTranscriber {
    private let whisperKit: WhisperKit

    init(location: WhisperModelLocation) async throws {
        whisperKit = try await location.load()
    }

    func transcribe(_ clip: ClipAudio) async throws -> FinalPassRecord {
        let merged = try AudioMerger.merge(mic: clip.mic, system: clip.system)
        let start = ContinuousClock.now
        let results = try await whisperKit.transcribe(audioArray: merged.samples, decodeOptions: TranscriptionMethod.current.whisperDecodingOptions)
        // As `TranscriptSanitizer` does for segments: nothing past the end of the audio.
        let words = results.flatMap(\.segments).flatMap { $0.words ?? [] }
            .filter { Double($0.start) < merged.duration }
            .map { FinalPassWord(text: $0.word, start: Double($0.start), end: Double($0.end), probability: $0.probability) }
        return FinalPassRecord(clip: clip.id, language: results.first?.language, seconds: start.duration(to: .now).seconds, words: words)
    }
}
