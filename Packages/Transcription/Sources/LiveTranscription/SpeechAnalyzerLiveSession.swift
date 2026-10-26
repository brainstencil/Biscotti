import Foundation
import LiveTranscriptModel
import os.log

/// The SpeechAnalyzer live engine: one Apple speech analyzer per track, in the
/// app's process. Final results become settled text; volatile results replace
/// the tail.
///
/// An analyzer's timeline never jumps. After a jump, SpeechAnalyzer returns the
/// first phrase it hears as one punctuation-only word ("..."), however much
/// silence comes first. Missing audio up to `silenceFillLimit` therefore
/// reaches the analyzer as silence; after a longer gap the track's analyzer
/// finishes and a fresh one starts at the new time.
///
/// Calls to `append` may overlap: while a track's analyzer is replaced, its
/// chunks wait, in order, for the fresh analyzer.
///
/// `transcribedThrough` tracks the audio the analyzer has accepted, not the
/// audio it has analyzed: the analyzer takes its input at once and reports no
/// progress of its own, so a backlog inside it does not show in the
/// watermarks. The replay harness sees one through first-display latency.
///
/// The spec marks the whole type macOS 26. Only `init(fastResults:)`, which
/// creates Apple's analyzers, needs it: the session itself runs on macOS 15,
/// so its tests run on CI.
///
/// Call `finish(timeout:)` or `cancel()` to end the session.
public actor SpeechAnalyzerLiveSession: LiveTranscriptionSession {
    enum Phase {
        case idle, starting, running, finishing, ended
    }

    struct Setup {
        let sessionID: UUID
        let generation: Int
        let tracks: [LiveTrack]
        let locale: String
        let vocabulary: [String]
    }

    struct TrackState {
        let track: LiveTrack
        var analyzer: any SpeechTrackAnalyzer
        /// Changes when the track leaves an analyzer, so its late events and the end of its events are ignored.
        var analyzerRun = 0
        var reader: Task<Void, Never>?
        /// True from a long gap until the fresh analyzer has taken the chunks held meanwhile.
        var isReplacing = false
        /// True while the analyzer being replaced finishes: the end of its events is expected.
        var isRetiring = false
        /// Chunks waiting for the fresh analyzer, starting with the one after the long gap.
        var held: [LiveAudioChunk] = []
        /// Created with the track's first chunk, where its watermarks start.
        var transcript: SpeechTrackTranscript?
        /// The end of the newest chunk, whether the analyzer took it or not.
        var audioEnd: TimeInterval?
        /// The end of the analyzer's timeline: the recording time its input
        /// reaches. Nil until the analyzer takes its first input.
        var analyzerEnd: TimeInterval?
        /// The start of the audio the full input queue is dropping.
        var overflowFrom: TimeInterval?
        /// The start of the audio not sent while paused.
        var pausedFrom: TimeInterval?
        var reportedWatermarks: SpeechTrackTranscript.Watermarks?
        /// While finishing: the track's last rows are out.
        var isDone = false

        init(track: LiveTrack, analyzer: any SpeechTrackAnalyzer) {
            self.track = track
            self.analyzer = analyzer
        }

        /// Ends the dropped stretch, if any, at `end`.
        mutating func closeOverflow(at end: TimeInterval?) -> [LiveGap] {
            guard let start = overflowFrom else { return [] }
            overflowFrom = nil
            let gaps = SpeechAnalyzerLiveSession.gap(on: track, from: start, to: end ?? start, reason: .queueOverflow)
            for gap in gaps {
                SpeechAnalyzerLiveSession.log.notice("Live audio dropped on \(gap.track.rawValue, privacy: .public): \(gap.duration, privacy: .public) s")
            }
            return gaps
        }
    }

    /// How a chunk reaches the track's analyzer.
    enum Feed: Equatable {
        case input(SpeechInput)
        /// The missing audio before the chunk is too long to send as silence.
        case freshAnalyzer
    }

    /// SpeechAnalyzer cannot identify the spoken language; English is this locale.
    static let englishLocale = "en-US"
    /// Missing audio up to this long reaches the analyzer as silence, so its
    /// timeline continues. Silence costs it little: two minutes take it under
    /// two seconds.
    static let silenceFillLimit: TimeInterval = 60
    /// How long an analyzer replaced after a long gap may take to finish.
    /// SpeechAnalyzer takes about 0.1 s.
    static let replacedAnalyzerTimeout = Duration.seconds(5)
    static let log = Logger(subsystem: "net.scosman.biscotti", category: "live")

    public nonisolated let updates: AsyncStream<LiveTrackUpdate>
    private let continuation: AsyncStream<LiveTrackUpdate>.Continuation
    private let factory: any SpeechTrackAnalyzerFactory
    private let clock: SessionClock

    private(set) var phase = Phase.idle
    private var setup: Setup?
    private var tracks: [LiveTrack: TrackState] = [:]
    private var isPaused = false
    private var revision = 0
    private var finishWaiter: CheckedContinuation<[LiveTrackUpdate], Never>?
    private var finishTasks: [Task<Void, Never>] = []
    private var finishUpdates: [LiveTrack: LiveTrackUpdate] = [:]

    /// A session on Apple's speech analyzers.
    /// - Parameter fastResults: Adds `.fastResults`: volatile text about every
    ///   second instead of in bursts about every 4 s of audio.
    @available(macOS 26, *)
    public init(fastResults: Bool = false) {
        self.init(factory: SystemSpeechAnalyzerFactory(fastResults: fastResults))
    }

    package init(factory: any SpeechTrackAnalyzerFactory, clock: some Clock<Duration> = ContinuousClock()) {
        self.factory = factory
        self.clock = SessionClock(clock)
        (updates, continuation) = AsyncStream.makeStream(of: LiveTrackUpdate.self, bufferingPolicy: .unbounded)
    }

    // MARK: - LiveTranscriptionSession

    /// - Throws: `LiveSessionError`, including `.languageUnsupported` for
    ///   Detect, `.assetNotInstalled` and `.engineUnavailable`.
    public func start(_ config: LiveSessionConfig) async throws {
        guard phase == .idle else { throw LiveSessionError.alreadyStarted }
        guard config.engine == .speechAnalyzer else { throw LiveSessionError.unsupportedEngine(config.engine) }
        guard LiveSessionRules.isSupported(config.tracks) else { throw LiveSessionError.unsupportedTracks(config.tracks) }
        guard LiveSessionRules.isValidInterval(config.updateInterval) else { throw LiveSessionError.invalidUpdateInterval }
        let locale = try Self.locale(for: config.language)

        phase = .starting
        var analyzers: [LiveTrack: any SpeechTrackAnalyzer] = [:]
        do {
            for track in config.tracks where phase == .starting {
                analyzers[track] = try await factory.makeAnalyzer(for: track, locale: locale, vocabulary: config.vocabulary)
            }
        } catch {
            for analyzer in analyzers.values {
                await analyzer.cancel()
            }
            if phase == .starting {
                phase = .idle
            }
            throw error
        }
        guard phase == .starting else {
            // Cancelled while the analyzers were made.
            for analyzer in analyzers.values {
                await analyzer.cancel()
            }
            throw CancellationError()
        }

        setup = Setup(sessionID: config.sessionID, generation: config.generation, tracks: config.tracks, locale: locale, vocabulary: config.vocabulary)
        tracks = Dictionary(uniqueKeysWithValues: config.tracks.compactMap { track in
            analyzers[track].map { (track, TrackState(track: track, analyzer: $0)) }
        })
        phase = .running
        config.tracks.forEach(startReading)
        Self.log.notice("Live speech analyzer session started: \(config.tracks.count, privacy: .public) track(s), \(locale, privacy: .public)")
    }

    public func append(_ chunk: LiveAudioChunk) async {
        guard phase == .running, var state = tracks[chunk.track] else { return }
        if state.transcript == nil {
            let transcript = SpeechTrackTranscript(track: chunk.track, startTime: chunk.startTime)
            state.transcript = transcript
            state.reportedWatermarks = transcript.watermarks
        }
        var gaps: [LiveGap] = []
        if isPaused {
            if state.pausedFrom == nil {
                gaps += state.closeOverflow(at: state.audioEnd)
                state.pausedFrom = state.audioEnd ?? chunk.startTime
            }
        } else {
            gaps += boundaryGaps(before: chunk, state: &state)
        }
        let feed = isPaused || state.isReplacing ? nil : Self.feed(for: chunk, after: state.analyzerEnd)
        if !isPaused, state.isReplacing {
            state.held.append(chunk)
        }
        state.audioEnd = chunk.endTime
        tracks[chunk.track] = state
        emit(chunk.track, gaps: gaps)

        switch feed {
        case nil:
            return
        case let .input(input):
            send(input, for: chunk)
        case .freshAnalyzer:
            await replaceAnalyzer(of: chunk.track, startingWith: chunk)
        }
    }

    // TODO: phase 8's power policy doubles the update interval in Low Power Mode; with SpeechAnalyzer the interval has no effect, so the policy needs another lever or must skip this engine.
    /// SpeechAnalyzer decides when it analyzes, so the interval has no effect.
    public func setUpdateInterval(_: TimeInterval) async {}

    public func setPaused(_ paused: Bool) async {
        guard paused != isPaused else { return }
        isPaused = paused
        Self.log.notice("Live session \(paused ? "paused" : "resumed", privacy: .public)")
    }

    public func finish(timeout: Duration) async -> [LiveTrackUpdate] {
        guard phase == .running, let setup else { return [] }
        phase = .finishing
        let sleep = clock.sleep
        return await withCheckedContinuation { waiter in
            finishWaiter = waiter
            finishTasks.append(Task {
                do { try await sleep(timeout) } catch { return }
                self.abandonFinishing()
            })
            for track in setup.tracks {
                beginFinishing(track)
            }
        }
    }

    public func cancel() async {
        guard phase != .ended else { return }
        Self.log.notice("Live session cancelled")
        let waiter = finishWaiter
        finishWaiter = nil
        end()
        waiter?.resume(returning: [])
    }

    /// The revision of the latest update sent.
    package var latestRevision: Int {
        revision
    }

    /// True once the session has ended. Before `finish` or `cancel`, that means it failed.
    package var hasEnded: Bool {
        phase == .ended
    }

    // MARK: - Configuration

    /// SpeechAnalyzer cannot identify the spoken language, so Detect is refused.
    static func locale(for language: LiveLanguage) throws(LiveSessionError) -> String {
        switch language {
        case .english: englishLocale
        case .detect: throw .languageUnsupported("detect")
        case let .locale(identifier): identifier
        }
    }

    static func gap(on track: LiveTrack, from start: TimeInterval, to end: TimeInterval, reason: LiveGap.Reason) -> [LiveGap] {
        end > start ? [LiveGap(track: track, startTime: start, duration: end - start, reason: reason)] : []
    }

    /// One gap per run of back-to-back chunks.
    static func gaps(covering chunks: [LiveAudioChunk], reason: LiveGap.Reason) -> [LiveGap] {
        var gaps: [LiveGap] = []
        for chunk in chunks where chunk.duration > 0 {
            if let last = gaps.last, abs(chunk.startTime - (last.startTime + last.duration)) < 0.5 / LiveAudioChunk.sampleRate {
                gaps[gaps.count - 1].duration = chunk.endTime - last.startTime
            } else {
                gaps.append(LiveGap(track: chunk.track, startTime: chunk.startTime, duration: chunk.duration, reason: reason))
            }
        }
        return gaps
    }
}

// MARK: - Audio

extension SpeechAnalyzerLiveSession {
    /// The spec sets the analyzer's start time on the first chunk and after
    /// every discontinuity. Here only an analyzer's first input carries a
    /// start time, so its timeline never jumps: missing audio up to
    /// `silenceFillLimit` is sent as silence before the chunk, in the same
    /// input, and longer missing audio needs a fresh analyzer.
    static func feed(for chunk: LiveAudioChunk, after analyzerEnd: TimeInterval?) -> Feed {
        guard let analyzerEnd else { return .input(SpeechInput(samples: chunk.samples, startTime: chunk.startTime)) }
        let missing = Int(((chunk.startTime - analyzerEnd) * LiveAudioChunk.sampleRate).rounded())
        guard missing > 0 else { return .input(SpeechInput(samples: chunk.samples, startTime: nil)) }
        guard Double(missing) / LiveAudioChunk.sampleRate <= silenceFillLimit else { return .freshAnalyzer }
        return .input(SpeechInput(samples: Array(repeating: 0, count: missing) + chunk.samples, startTime: nil))
    }

    /// The gaps a resumed or discontinuous chunk follows.
    private func boundaryGaps(before chunk: LiveAudioChunk, state: inout TrackState) -> [LiveGap] {
        let reason: LiveGap.Reason
        if state.pausedFrom != nil {
            reason = .paused
        } else if chunk.isDiscontinuity, state.audioEnd != nil {
            reason = .captureGap
        } else {
            return []
        }
        let start = state.pausedFrom ?? state.audioEnd ?? chunk.startTime
        state.pausedFrom = nil
        return state.closeOverflow(at: state.audioEnd) + Self.gap(on: chunk.track, from: start, to: chunk.startTime, reason: reason)
    }

    /// Queues the input. A full queue drops it, and the dropped stretch
    /// becomes one gap once the analyzer takes audio again.
    private func send(_ input: SpeechInput, for chunk: LiveAudioChunk) {
        guard phase == .running, var state = tracks[chunk.track] else { return }
        var gaps: [LiveGap] = []
        if state.analyzer.enqueue(input) {
            state.analyzerEnd = chunk.endTime
            gaps = state.closeOverflow(at: chunk.startTime)
        } else {
            state.overflowFrom = state.overflowFrom ?? chunk.startTime
        }
        tracks[chunk.track] = state
        emit(chunk.track, gaps: gaps)
    }
}

// MARK: - Replacing an analyzer

extension SpeechAnalyzerLiveSession {
    /// After a long gap: holds the track's chunks, starting with `chunk`,
    /// replaces its analyzer, then sends the held chunks to the fresh one in
    /// order. A held chunk after another long gap needs another fresh analyzer.
    private func replaceAnalyzer(of track: LiveTrack, startingWith chunk: LiveAudioChunk) async {
        tracks[track]?.isReplacing = true
        tracks[track]?.held = [chunk]
        while await startFreshAnalyzer(for: track) {
            if sendHeldChunks(of: track) {
                tracks[track]?.isReplacing = false
                return
            }
        }
    }

    /// Finishes the track's analyzer, applies its last results so the text
    /// before the gap settles, and starts a fresh one.
    /// - Returns: False when the session stopped running meanwhile, or no
    ///   fresh analyzer could start (which ends the session).
    private func startFreshAnalyzer(for track: LiveTrack) async -> Bool {
        guard let setup, let state = tracks[track] else { return false }
        tracks[track]?.isRetiring = true
        let finished = await finishReplaced(state.analyzer, reader: state.reader)
        guard var state = tracks[track] else { return false }
        // A reader cut off by the timeout may still hold the old analyzer's events; they are not applied.
        state.analyzerRun += 1
        state.isRetiring = false
        var rows: [LiveRow] = []
        if var transcript = state.transcript {
            rows = transcript.close(incomplete: !finished, through: state.analyzerEnd ?? transcript.transcribedThrough)
            state.transcript = transcript
        }
        state.analyzerEnd = nil
        tracks[track] = state
        emit(track, rows: rows)
        guard phase == .running else { return completeReplacing(track) }

        let fresh: any SpeechTrackAnalyzer
        do {
            fresh = try await factory.makeAnalyzer(for: track, locale: setup.locale, vocabulary: setup.vocabulary)
        } catch {
            Self.log.error("Live speech analyzer could not restart on \(track.rawValue, privacy: .public); ending the session: \(String(describing: error), privacy: .public)")
            if phase == .running {
                end()
            }
            return completeReplacing(track)
        }
        guard phase == .running, var state = tracks[track] else {
            await fresh.cancel()
            return completeReplacing(track)
        }
        state.analyzer = fresh
        tracks[track] = state
        startReading(track)
        Self.log.notice("Live speech analyzer restarted on \(track.rawValue, privacy: .public) after a long gap")
        return true
    }

    /// Sends the held chunks in order; the first reaches the fresh analyzer with its start time.
    /// - Returns: False when a held chunk follows another long gap and needs another fresh analyzer.
    private func sendHeldChunks(of track: LiveTrack) -> Bool {
        while let chunk = tracks[track]?.held.first {
            guard case let .input(input) = Self.feed(for: chunk, after: tracks[track]?.analyzerEnd) else { return false }
            tracks[track]?.held.removeFirst()
            send(input, for: chunk)
        }
        return true
    }

    /// Finishes an analyzer the track is leaving and waits until its last
    /// results are applied. One that fails or runs out of time is cancelled.
    /// - Returns: True when it finished.
    private func finishReplaced(_ analyzer: any SpeechTrackAnalyzer, reader: Task<Void, Never>?) async -> Bool {
        let sleep = clock.sleep
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try await analyzer.finish()
                } catch {
                    return false
                }
                await reader?.value
                return true
            }
            group.addTask {
                try? await sleep(Self.replacedAnalyzerTimeout)
                return false
            }
            let first = await group.next() ?? false
            if !first {
                await analyzer.cancel()
            }
            group.cancelAll()
            return first
        }
        if !finished {
            reader?.cancel()
        }
        return finished
    }

    /// Finishing began while the track was between analyzers: its text before
    /// the gap is already closed, and `completeTrack` reports the held chunks as a gap.
    private func completeReplacing(_ track: LiveTrack) -> Bool {
        tracks[track]?.isReplacing = false
        completeTrack(track, incomplete: false)
        return false
    }
}

// MARK: - Results

extension SpeechAnalyzerLiveSession {
    private func startReading(_ track: LiveTrack) {
        guard let state = tracks[track] else { return }
        let events = state.analyzer.events
        let run = state.analyzerRun
        tracks[track]?.reader = Task(priority: .userInitiated) { await self.read(events, of: track, run: run) }
    }

    private func read(_ events: AsyncThrowingStream<SpeechAnalyzerEvent, any Error>, of track: LiveTrack, run: Int) async {
        do {
            for try await event in events {
                handle(event, on: track, run: run)
            }
            analyzerEnded(on: track, run: run, failure: nil)
        } catch {
            analyzerEnded(on: track, run: run, failure: error)
        }
    }

    private func handle(_ event: SpeechAnalyzerEvent, on track: LiveTrack, run: Int) {
        guard phase == .running || phase == .finishing, var state = tracks[track], run == state.analyzerRun, !state.isDone,
              var transcript = state.transcript
        else { return }
        let rows = transcript.apply(event)
        state.transcript = transcript
        tracks[track] = state
        emit(track, rows: rows)
    }

    /// The analyzer's events ended: expected while finishing or while it is
    /// replaced, a failure otherwise.
    private func analyzerEnded(on track: LiveTrack, run: Int, failure: (any Error)?) {
        guard let state = tracks[track], run == state.analyzerRun, !state.isRetiring else { return }
        switch phase {
        case .running:
            let reason = failure.map { String(describing: $0) } ?? "its results ended"
            Self.log.error("Live speech analyzer stopped on \(track.rawValue, privacy: .public); ending the session: \(reason, privacy: .public)")
            end()
        case .finishing:
            completeTrack(track, incomplete: failure != nil)
        case .idle, .starting, .ended:
            break
        }
    }

    private func emit(_ track: LiveTrack, rows: [LiveRow] = [], gaps: [LiveGap] = []) {
        guard let setup, var state = tracks[track], let watermarks = state.transcript?.watermarks else { return }
        guard !rows.isEmpty || !gaps.isEmpty || watermarks != state.reportedWatermarks else { return }
        state.reportedWatermarks = watermarks
        tracks[track] = state
        revision += 1
        let update = LiveTrackUpdate(
            sessionID: setup.sessionID,
            generation: setup.generation,
            track: track,
            revision: revision,
            rows: rows,
            gaps: gaps,
            transcribedThrough: watermarks.transcribedThrough,
            settledThrough: watermarks.settledThrough
        )
        switch phase {
        case .running:
            continuation.yield(update)
        case .finishing:
            if finishUpdates[track] == nil {
                finishUpdates[track] = update
            } else {
                finishUpdates[track]?.merge(update)
            }
        case .idle, .starting, .ended:
            break
        }
    }
}

// MARK: - Finishing

extension SpeechAnalyzerLiveSession {
    /// Reports the track's pending gaps, then finalizes what the analyzer
    /// holds. A track that never sent audio has nothing to finalize, and one
    /// between analyzers is completed by `replaceAnalyzer`.
    private func beginFinishing(_ track: LiveTrack) {
        guard var state = tracks[track] else { return }
        var gaps = state.closeOverflow(at: state.held.first?.startTime ?? state.audioEnd)
        if let pausedFrom = state.pausedFrom, let end = state.audioEnd {
            gaps += Self.gap(on: track, from: pausedFrom, to: end, reason: .paused)
            state.pausedFrom = nil
        }
        tracks[track] = state
        emit(track, gaps: gaps)

        guard !state.isReplacing else { return }
        guard state.analyzerEnd != nil else {
            completeTrack(track, incomplete: false)
            return
        }
        let analyzer = state.analyzer
        let run = state.analyzerRun
        finishTasks.append(Task {
            do {
                try await analyzer.finish()
            } catch {
                self.analyzerEnded(on: track, run: run, failure: error)
            }
        })
    }

    /// The track's last rows: complete once its events ended after `finish`;
    /// otherwise the tail is settled as it is and marked incomplete. Chunks
    /// held for an analyzer that never started are reported as a gap.
    private func completeTrack(_ track: LiveTrack, incomplete: Bool) {
        guard phase == .finishing, var state = tracks[track], !state.isDone else { return }
        state.isDone = true
        let gaps = Self.gaps(covering: state.held, reason: .engineRestart)
        state.held = []
        var rows: [LiveRow] = []
        if var transcript = state.transcript {
            rows = transcript.close(incomplete: incomplete, through: state.audioEnd ?? transcript.transcribedThrough)
            state.transcript = transcript
        }
        tracks[track] = state
        emit(track, rows: rows, gaps: gaps)
        completeFinishingIfDone()
    }

    /// Out of time: every track not done returns what it has.
    private func abandonFinishing() {
        guard phase == .finishing, let setup else { return }
        Self.log.notice("Live finish stopped early; the last rows are marked incomplete")
        for track in setup.tracks {
            completeTrack(track, incomplete: true)
        }
    }

    private func completeFinishingIfDone() {
        guard phase == .finishing, let setup, let waiter = finishWaiter, setup.tracks.allSatisfy({ tracks[$0]?.isDone ?? true }) else { return }
        finishWaiter = nil
        let result = setup.tracks.compactMap { finishUpdates[$0] }
        Self.log.notice("Live session finished")
        end()
        waiter.resume(returning: result)
    }

    /// Stops all work for good and releases the analyzers.
    private func end() {
        phase = .ended
        finishTasks.forEach { $0.cancel() }
        let states = Array(tracks.values)
        states.forEach { $0.reader?.cancel() }
        tracks = [:]
        continuation.finish()
        Task {
            for state in states {
                await state.analyzer.cancel()
            }
        }
    }
}
