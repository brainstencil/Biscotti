import ArgumentParser
import Foundation
import LiveTranscription
import LiveTranscriptModel

/// `live-bench cost`: how long one live decode takes for windows of 2, 10 and 30 s.
struct CostCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cost",
        abstract: "Time live decodes of 2, 10 and 30 s windows with the session's decode options.",
        discussion: """
        Loads the model once, warms up with three decodes, then times ten decodes
        per length over the clip's summed tracks. Each decode is prompted with the
        reference text before its window, as the session prompts with settled
        text. Writes cost.json and manifest.json.
        """
    )
    static let lengths: [TimeInterval] = [2, 10, 30]
    static let warmUpDecodes = 3
    static let timedDecodes = 10

    @OptionGroup var paths: BenchPaths

    @Option(help: "The Whisper model folder name.")
    var model: String

    @Option(help: "The clip whose audio is decoded; it must be at least 30 s long.")
    var clip = "smoke"

    // TODO(live_transcript): default to WhisperKitLiveDecoder.defaultPrompt (.none) so live-bench measures what the app ships.
    @Option(help: "What each decode is prompted with, as `run --whisper-prompt`.")
    var whisperPrompt: BenchPrompt = .settledText

    @Option(help: "Timed decodes per window length (default 10; fewer only for dry runs).")
    var decodes = Self.timedDecodes

    func validate() throws {
        if decodes < 1 {
            throw ValidationError("--decodes must be at least 1.")
        }
    }

    func run() async throws {
        let resolved = try paths.resolve()
        let location = try WhisperModelLocation.locate(name: model, in: resolved.models)
        let audio = try ClipAudio.load(id: clip, fixtures: resolved.fixtures)
        let longest = Self.lengths.reduce(0, max)
        guard audio.duration >= longest else { throw BenchError.clipTooShort(id: clip, seconds: audio.duration, needed: longest) }
        let suffix = whisperPrompt == .settledText ? "" : "-prompt-\(whisperPrompt.rawValue)"
        let folder = try makeResultsFolder(in: resolved.out, named: "\(folderTimestamp())-cost-\(model)\(suffix)")
        progress("Results: \(folder.path)")
        var manifest = try BenchManifest.make(kind: "cost", options: OptionsRecord(model: model, clips: [clip], whisperPrompt: whisperPrompt, decodes: decodes), model: location, fixtures: resolved.fixtures)
        try manifest.write(to: folder)

        let loadStart = ContinuousClock.now
        let decoder = try await WhisperKitLiveDecoder(
            whisperKit: location.load(restoringTimestampRules: whisperPrompt.restoresTimestampRules),
            prompt: whisperPrompt.decoderPrompt
        )
        let loadSeconds = loadStart.duration(to: .now).seconds
        manifest.model?.loadSeconds = loadSeconds
        try manifest.write(to: folder)

        let reference = try ReferenceText.load(clip: clip, fixtures: resolved.fixtures)
        let timer = DecodeTimer(decoder: decoder, samples: audio.mixed, reference: reference)
        progress("Warming up…")
        let warmUp = try await timer.time(length: Self.lengths[0], count: min(Self.warmUpDecodes, decodes))
        var lengths: [CostLength] = []
        for length in Self.lengths {
            progress("Timing \(decodes) decodes of \(Int(length)) s…")
            try await lengths.append(CostLength(seconds: length, decodeMilliseconds: timer.time(length: length, count: decodes)))
        }
        let report = CostReport(
            model: model,
            clip: clip,
            loadSeconds: loadSeconds,
            contextCharacters: LocalAgreementReducer.promptCharacterLimit,
            warmUpMilliseconds: warmUp,
            lengths: lengths
        )
        try BenchJSON.write(report, to: folder.appending(path: "cost.json"))
        for length in lengths {
            print("\(Int(length.seconds)) s: median \(Int(length.medianMilliseconds)) ms, p95 \(Int(length.p95Milliseconds)) ms")
        }
    }
}

/// Times decodes of windows spread evenly over one stretch of audio.
struct DecodeTimer {
    let decoder: any LiveDecoder
    let samples: [Float]
    let reference: ReferenceText

    /// The live session's options for an English track without vocabulary
    /// (as gated runs), prompted with the text before the window. Whisper runs
    /// one decoder pass per prompt token, so an empty prompt would time low.
    func options(before windowStart: TimeInterval) -> LiveDecodeOptions {
        LiveDecodeOptions(
            language: "en",
            vocabularyPrompt: nil,
            settledContext: reference.context(before: windowStart, limit: LocalAgreementReducer.promptCharacterLimit)
        )
    }

    func time(length: TimeInterval, count: Int) async throws -> [Double] {
        let window = Int(length * LiveAudioChunk.sampleRate)
        var milliseconds: [Double] = []
        for offset in CostStatistics.windowOffsets(sampleCount: samples.count, windowSamples: window, count: count) {
            let startTime = Double(offset) / LiveAudioChunk.sampleRate
            let options = options(before: startTime)
            let start = ContinuousClock.now
            _ = try await decoder.decode(Array(samples[offset ..< offset + window]), startTime: startTime, options: options)
            milliseconds.append(start.duration(to: .now).seconds * 1000)
        }
        return milliseconds
    }
}

/// The clip's reference words, for prompt context.
struct ReferenceText {
    struct Word: Decodable {
        var text: String
        var start: TimeInterval
        var end: TimeInterval
    }

    private struct File: Decodable {
        var words: [Word]
    }

    let words: [Word]

    static func load(clip: String, fixtures: URL) throws -> ReferenceText {
        let url = try ClipAudio.folder(of: clip, in: fixtures).appending(path: "reference.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw BenchError.missingClip(id: clip, folder: url.deletingLastPathComponent().path) }
        let words = try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).words
        return ReferenceText(words: words.sorted { $0.start < $1.start })
    }

    /// Whole words that end by `time`, newest kept, within `limit` characters
    /// counting each word's leading space, as `LocalAgreementReducer.settledText(before:)` cuts them.
    func context(before time: TimeInterval, limit: Int) -> String {
        var kept: [String] = []
        var characters = 0
        for word in words.filter({ $0.end <= time }).reversed() {
            let spelled = " " + word.text
            guard characters + spelled.count <= limit else { break }
            kept.append(spelled)
            characters += spelled.count
        }
        return kept.reversed().joined().trimmingCharacters(in: .whitespaces)
    }
}

struct CostReport: Encodable {
    var model: String
    var clip: String
    var loadSeconds: Double
    /// The most prompt context each decode had.
    var contextCharacters: Int
    var warmUpMilliseconds: [Double]
    var lengths: [CostLength]
}

struct CostLength: Encodable {
    var seconds: TimeInterval
    var decodeMilliseconds: [Double]

    var medianMilliseconds: Double {
        CostStatistics.median(decodeMilliseconds)
    }

    var p95Milliseconds: Double {
        CostStatistics.percentile(decodeMilliseconds, 95)
    }

    private enum CodingKeys: String, CodingKey {
        case seconds, decodeMilliseconds, medianMilliseconds, p95Milliseconds
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seconds, forKey: .seconds)
        try container.encode(decodeMilliseconds, forKey: .decodeMilliseconds)
        try container.encode(medianMilliseconds, forKey: .medianMilliseconds)
        try container.encode(p95Milliseconds, forKey: .p95Milliseconds)
    }
}

enum CostStatistics {
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// Nearest rank: the smallest value with at least `percent`% of values at
    /// or below it. With ten decodes, p95 is the slowest.
    static func percentile(_ values: [Double], _ percent: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((percent / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    /// `count` window starts spread evenly from the start of the audio to the
    /// last start that still fits a whole window.
    static func windowOffsets(sampleCount: Int, windowSamples: Int, count: Int) -> [Int] {
        let lastStart = max(0, sampleCount - windowSamples)
        guard count > 1 else { return [0] }
        return (0 ..< count).map { lastStart * $0 / (count - 1) }
    }
}
