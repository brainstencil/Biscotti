import AVFoundation
import CoreMedia
import Foundation
import LiveTranscriptModel
import Speech

/// Apple's analyzers for `SpeechAnalyzerLiveSession`: one `SpeechAnalyzer`
/// with its own `SpeechTranscriber` per track. Two run side by side in one
/// process, and need no speech-recognition permission and no app bundle; the
/// locale's model must be installed for the program (`SpeechAnalyzerAssets`).
@available(macOS 26, *)
struct SystemSpeechAnalyzerFactory: SpeechTrackAnalyzerFactory {
    let fastResults: Bool

    func makeAnalyzer(for _: LiveTrack, locale identifier: String, vocabulary: [String]) async throws -> any SpeechTrackAnalyzer {
        let locale = try await SpeechAnalyzerAssets.supportedLocale(identifier)
        let transcriber = SpeechAnalyzerAssets.transcriber(for: locale, fastResults: fastResults)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw LiveSessionError.assetNotInstalled(locale.identifier(.bcp47))
        }
        // Each analyzer keeps its own resampler state.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: LiveSampleConverter.inputFormat),
              let converter = LiveSampleConverter(outputFormat: format)
        else { throw LiveSessionError.engineUnavailable }
        return try await SystemSpeechTrackAnalyzer.start(transcriber: transcriber, converter: converter, vocabulary: vocabulary)
    }
}

/// One track's `SpeechAnalyzer`, fed through a bounded input queue.
@available(macOS 26, *)
final class SystemSpeechTrackAnalyzer: SpeechTrackAnalyzer {
    /// 16 inputs of 250 ms: 4 s before audio is dropped.
    static let inputCapacity = 16
    /// Input start times in microseconds.
    static let timescale: CMTimeScale = 1_000_000

    let events: AsyncThrowingStream<SpeechAnalyzerEvent, any Error>
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    /// The session's actor converts one chunk at a time.
    private let converter: LiveSampleConverter
    private let results: Task<Void, Never>

    private init(
        events: AsyncThrowingStream<SpeechAnalyzerEvent, any Error>,
        analyzer: SpeechAnalyzer,
        input: AsyncStream<AnalyzerInput>.Continuation,
        converter: LiveSampleConverter,
        results: Task<Void, Never>
    ) {
        self.events = events
        self.analyzer = analyzer
        self.input = input
        self.converter = converter
        self.results = results
    }

    /// Loads the model and starts analyzing the input queue.
    static func start(transcriber: SpeechTranscriber, converter: LiveSampleConverter, vocabulary: [String]) async throws -> SystemSpeechTrackAnalyzer {
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: converter.outputFormat)

        let (events, eventSink) = AsyncThrowingStream.makeStream(of: SpeechAnalyzerEvent.self)
        // The volatile range ends where the analyzer's input ends. Results
        // alone would not show that progress: none come during silence.
        await analyzer.setVolatileRangeChangedHandler { range, _, changedEnd in
            if changedEnd, let end = range.end.finiteSeconds {
                eventSink.yield(.received(through: end))
            }
        }
        let results = Task {
            do {
                for try await result in transcriber.results {
                    if let mapped = SpeechResult(result) {
                        eventSink.yield(.result(mapped))
                    }
                }
                eventSink.finish()
            } catch {
                eventSink.finish(throwing: error)
            }
        }
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(inputCapacity))
        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            results.cancel()
            throw error
        }
        return SystemSpeechTrackAnalyzer(events: events, analyzer: analyzer, input: input, converter: converter, results: results)
    }

    func enqueue(_ input: SpeechInput) -> Bool {
        guard let buffer = converter.convert(input.samples) else { return false }
        let startTime = input.startTime.map { CMTime(seconds: $0, preferredTimescale: Self.timescale) }
        if case .enqueued = self.input.yield(AnalyzerInput(buffer: buffer, bufferStartTime: startTime)) {
            return true
        }
        return false
    }

    func finish() async throws {
        input.finish()
        // The spec finishes with `finalizeAndFinish(through:)` at the last
        // chunk's end. On macOS 26.6 that call, and `finalize(through:)`, never
        // return when `through` is the end of the input received; finalizing
        // through the end of the input covers the same audio.
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        results.cancel()
    }
}

/// The SpeechAnalyzer model of a locale. The system downloads and stores it,
/// and keeps it for each program that asks for it: until a program asks,
/// `status` reports `.notInstalled` even when the model is on the Mac.
@available(macOS 26, *)
public enum SpeechAnalyzerAssets {
    public enum Status: Sendable, Equatable {
        case unsupported
        case notInstalled
        case downloading
        case installed
    }

    /// The supported locale `identifier` resolves to, such as en-US for "en-US".
    public static func supportedLocale(_ identifier: String) async throws(LiveSessionError) -> Locale {
        guard SpeechTranscriber.isAvailable else { throw .engineUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw .languageUnsupported(identifier)
        }
        return locale
    }

    public static func status(locale identifier: String) async -> Status {
        guard let locale = try? await supportedLocale(identifier) else { return .unsupported }
        switch await AssetInventory.status(forModules: [transcriber(for: locale, fastResults: false)]) {
        case .installed: return .installed
        case .downloading: return .downloading
        case .supported: return .notInstalled
        case .unsupported: return .unsupported
        @unknown default: return .notInstalled
        }
    }

    /// Asks the system to download the locale's model if needed and keep it for this program.
    /// - Parameter progress: The fraction completed, as the download reports it.
    public static func install(locale identifier: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let locale = try await supportedLocale(identifier)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber(for: locale, fastResults: false)]) else { return }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { reported, _ in
            progress(reported.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }

    static func transcriber(for locale: Locale, fastResults: Bool) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: fastResults ? [.volatileResults, .fastResults] : [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }
}

@available(macOS 26, *)
extension SpeechResult {
    init?(_ result: SpeechTranscriber.Result) {
        guard let start = result.range.start.finiteSeconds, let end = result.range.end.finiteSeconds else { return nil }
        self.init(
            words: Self.words(in: result.text, start: start, end: end),
            start: start,
            end: end,
            isFinal: result.isFinal,
            finalizedThrough: result.resultsFinalizationTime.finiteSeconds ?? start
        )
    }

    /// One word per run of `text`. Final text has a time range per word;
    /// volatile text has one run for all of it. A run without a range takes
    /// the result's, and a run of spaces joins the next word.
    static func words(in text: AttributedString, start: TimeInterval, end: TimeInterval) -> [TimedWord] {
        var words: [TimedWord] = []
        var leadingSpace = ""
        for run in text.runs {
            let spelled = String(text[run.range].characters)
            guard !spelled.allSatisfy(\.isWhitespace) else {
                leadingSpace += spelled
                continue
            }
            let range = run.audioTimeRange.flatMap { range in range.start.finiteSeconds.flatMap { start in range.end.finiteSeconds.map { (start, $0) } } }
            words.append(TimedWord(text: leadingSpace + spelled, start: range?.0 ?? start, end: range?.1 ?? end))
            leadingSpace = ""
        }
        return words
    }
}

extension CMTime {
    var finiteSeconds: TimeInterval? {
        isNumeric ? seconds : nil
    }
}
