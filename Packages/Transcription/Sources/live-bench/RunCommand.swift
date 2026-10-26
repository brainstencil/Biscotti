import ArgumentParser
import Foundation
import LiveTranscription
import LiveTranscriptModel

/// `live-bench run`: replays clips through the live session and logs every update.
struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Replay clips at real-time speed through a live session.",
        discussion: """
        Writes <out>/<timestamp>-<option>-i<interval>-<mode>/ with manifest.json,
        resources.jsonl and, per clip, events.jsonl and final.json. Memory is
        measured against a 30-second baseline taken before the model loads.
        speechanalyzer needs macOS 26 and its en-US model installed for
        live-bench (see speech-assets); it transcribes in English.
        """
    )
    static let baselineSeconds = 30
    static let intervals: Set<Double> = [1, 2, 4]

    @OptionGroup var paths: BenchPaths

    @Option(help: "The engine option.")
    var option: BenchEngine

    @Option(help: "A Whisper model folder name instead of the option's default.")
    var model: String?

    @Option(help: "Seconds between decodes of one track: 1, 2 or 4. SpeechAnalyzer decides when it analyzes; the value is only recorded.")
    var interval: Double

    @Option(help: "two-track (\"You\" and \"Others\") or mixed.")
    var mode: BenchMode

    @Option(help: "Comma-separated clip IDs.")
    var clips: String

    @Option(help: "none, or call for simulated call load.")
    var load: BenchLoad = .none

    @Flag(help: "Release audio as fast as the session takes it; times are simulated.")
    var virtualClock = false

    @Flag(help: "Pass no custom vocabulary (gated runs).")
    var vocabularyOff = false

    @Flag(help: "SpeechAnalyzer only: volatile text about every second (.fastResults) instead of in bursts about every 4 s.")
    var fastResults = false

    // TODO(live_transcript): default to WhisperKitLiveDecoder.defaultPrompt (.none) so live-bench measures what the app ships.
    @Option(help: "Whisper only: what each decode is prompted with. settled-text is the spec's prompt (vocabulary and settled text); settled-text-timestamp-rules also restores WhisperKit's timestamp rules, which a prompt switches off.")
    var whisperPrompt: BenchPrompt = .settledText

    @OptionGroup var dryRun: DryRunOptions

    @Option(help: "What runs alongside this replay in another process, such as \"final pass of soak\". Recorded in the manifest; report.py treats the run as a diagnostic.")
    var alongside: String?

    func validate() throws {
        if option == .speechAnalyzer {
            if model != nil {
                throw ValidationError("--model applies only to the Whisper options; SpeechAnalyzer uses the system's model.")
            }
            if virtualClock {
                throw ValidationError("--virtual-clock applies only to the Whisper options; SpeechAnalyzer runs on its own time.")
            }
            if whisperPrompt != .settledText {
                throw ValidationError("--whisper-prompt applies only to the Whisper options.")
            }
        } else if fastResults {
            throw ValidationError("--fast-results applies only to --option speechanalyzer.")
        }
        if alongside?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            throw ValidationError("--alongside needs a description of what runs alongside.")
        }
    }

    func run() async throws {
        let resolved = try paths.resolve()
        guard Self.intervals.contains(interval) else { throw BenchError.invalidInterval(interval) }
        let engine = try await ReplayEngine.locate(option: option, model: model, fastResults: fastResults, prompt: whisperPrompt, in: resolved.models)
        let clipIDs = try parseClipIDs(clips)
        let audio = try clipIDs.map { try ClipAudio.load(id: $0, fixtures: resolved.fixtures).prefix(seconds: dryRun.clipSeconds) }
        let folder = try makeResultsFolder(in: resolved.out, named: folderName)
        progress("Results: \(folder.path)")

        // The model is hashed after the replay: reading 0.6 GB of weights
        // first would put them in the file cache and into the memory baseline.
        var manifest = try BenchManifest.make(
            kind: "run",
            options: optionsRecord(clipIDs: clipIDs, model: engine.whisperLocation?.name),
            model: engine.whisperLocation,
            hashingModel: false,
            fixtures: resolved.fixtures
        )
        try manifest.write(to: folder)

        let callLoad = load == .call ? try SimulatedCallLoad.start() : nil
        defer { callLoad?.stop() }
        let resources = try JSONLinesWriter(url: folder.appending(path: "resources.jsonl"))
        let sampler = ResourceSampler(writer: resources)
        sampler.start()
        defer { sampler.stop() }

        let baselineSeconds = dryRun.baselineSeconds ?? Self.baselineSeconds
        progress("Measuring the memory baseline for \(baselineSeconds) s…")
        manifest.memoryBaseline = try await sampler.measureBaseline(seconds: baselineSeconds)
        sampler.setPhase("load-model")
        let loadStart = ContinuousClock.now
        let sessions = try await engine.load()
        manifest.model?.loadSeconds = loadStart.duration(to: .now).seconds
        try manifest.write(to: folder)

        for (index, clip) in audio.enumerated() {
            sampler.setPhase("clip:\(clip.id)")
            progress("Replaying \(clip.id) (\(Int(clip.duration)) s)…")
            var session = SessionRecord(clip: clip.id, warm: index > 0, startedAt: BenchManifest.timestamp())
            session.finishSeconds = try await replay(clip, sessions: sessions, into: folder.appending(path: clip.id, directoryHint: .isDirectory))
            manifest.sessions.append(session)
            try manifest.write(to: folder)
        }
        sampler.setPhase("done")
        if let location = engine.whisperLocation {
            let loadSeconds = manifest.model?.loadSeconds
            manifest.model = try ModelRecord.hashing(location)
            manifest.model?.loadSeconds = loadSeconds
            try manifest.write(to: folder)
        }
        progress("Done. Score with: uv run python score.py --run \(folder.path) --fixtures \(resolved.fixtures.path)")
    }

    /// `<timestamp>-<option>-i<interval>-<mode>[-<model>][-<prompt>][-fast][-load][-virtual][-alongside]`.
    var folderName: String {
        var parts = [folderTimestamp(), option.rawValue, "i\(Int(interval))", mode.rawValue]
        if let model {
            parts.append(model)
        }
        if whisperPrompt != .settledText {
            parts.append("prompt-\(whisperPrompt.rawValue)")
        }
        if fastResults {
            parts.append("fast")
        }
        if load == .call {
            parts.append("load")
        }
        if virtualClock {
            parts.append("virtual")
        }
        if alongside != nil {
            parts.append("alongside")
        }
        return parts.joined(separator: "-")
    }

    private func optionsRecord(clipIDs: [String], model: String?) -> OptionsRecord {
        OptionsRecord(
            option: option,
            model: model,
            interval: interval,
            mode: mode,
            clips: clipIDs,
            load: load.label,
            clock: virtualClock ? "simulated" : "real",
            vocabulary: !vocabularyOff,
            fastResults: option == .speechAnalyzer ? fastResults : nil,
            locale: option == .speechAnalyzer ? ReplayEngine.speechAnalyzerLocale : nil,
            alongside: alongside,
            whisperPrompt: option == .speechAnalyzer ? nil : whisperPrompt,
            clipSeconds: dryRun.clipSeconds,
            baselineSeconds: dryRun.baselineSeconds
        )
    }

    /// Runs one clip in a fresh session. - Returns: How long `finish` took.
    private func replay(_ clip: ClipAudio, sessions: ReplaySessions, into folder: URL) async throws -> Double {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let events = try JSONLinesWriter(url: folder.appending(path: "events.jsonl"))
        defer { try? events.close() }
        let clock = virtualClock ? VirtualClock() : nil
        let (session, control) = sessions.make(clock)
        try await session.start(sessions.config(tracks: mode.tracks, interval: interval, vocabulary: vocabularyOff ? [] : clip.vocabulary))
        // The source starts the clip's clock; the runner's monotonic clock starts with it.
        let source = PacedSource(sampleCount: clip.sampleCount, pacing: clock.map { .simulated($0) } ?? .realTime(ContinuousClock()))
        let runner = ReplayRunner(session: session, control: control, source: source, clip: clip, mode: mode)
        return try await runner.run(events: events, finalURL: folder.appending(path: "final.json"))
    }
}
