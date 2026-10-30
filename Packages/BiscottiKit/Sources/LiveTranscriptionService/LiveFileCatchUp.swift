import Foundation
import LiveTranscriptModel
import os
import Synchronization

/// Where each track's audio comes from while a start mid-recording catches up
/// from 0:00: the recording's file, up to where the audio the pump holds
/// begins, then the pump. The pump's queue and the file read share it.
///
/// While a track reads its file, the pump holds every chunk of the track. When
/// it must drop the oldest beyond its retention, the file read goes on to
/// where the remaining ones begin, so a catch-up longer than the retention
/// loses nothing. Once the file read reaches the held audio, the track is live
/// and the pump hands its chunks on as usual.
final class FileCatchUpHandoff: Sendable {
    enum Route: Equatable {
        /// The pump holds the track's chunks: its earlier audio still comes from the file.
        case file
        /// The pump hands the track's chunks on.
        case live
        /// As `.live`, after a file read that gave up short of the pump's
        /// audio. The first chunk the pump hands on is discontinuous, so the
        /// engine starts a new run there instead of joining it to the file's
        /// last audio.
        case liveAfterGap
        /// Stop came during the file read: the pump drops the track's chunks.
        case dropped
    }

    private struct TrackState {
        var route = Route.file
        /// Where the oldest chunk the pump holds begins; nil before its first.
        var heldFrom: TimeInterval?
    }

    /// The file read and the pump's audio meet within one 16 kHz sample.
    static let tolerance: TimeInterval = 1 / LiveAudioChunk.sampleRate

    /// The pump takes no audio before this time (its `discardBefore`).
    let liveFrom: TimeInterval
    private let tracks: Mutex<[LiveTrack: TrackState]>

    init(tracks: [LiveTrack], liveFrom: TimeInterval) {
        self.liveFrom = liveFrom
        self.tracks = Mutex(Dictionary(uniqueKeysWithValues: tracks.map { ($0, TrackState()) }))
    }

    /// A track the handoff does not cover is live.
    func route(_ track: LiveTrack) -> Route {
        tracks.withLock { $0[track]?.route ?? .live }
    }

    /// The pump now holds the track's audio from `time` on: its first chunk.
    /// Returns true while the track reads its file, which then covers
    /// everything before `time`.
    @discardableResult
    func pumpHolds(_ track: LiveTrack, from time: TimeInterval) -> Bool {
        tracks.withLock { tracks in
            guard let state = tracks[track], state.route == .file else { return false }
            tracks[track]?.heldFrom = max(state.heldFrom ?? time, time)
            return true
        }
    }

    /// Lets the pump drop the oldest audio it holds of a track that reads its
    /// file, under the handoff's lock, so the read cannot reach the old held
    /// audio meanwhile. `drop` removes the chunks and returns where the audio
    /// still held begins. Returns false, without calling `drop`, once the
    /// track no longer reads its file: what the pump drops then is lost.
    func coverDrop(_ track: LiveTrack, _ drop: () -> TimeInterval?) -> Bool {
        tracks.withLock { tracks in
            guard let state = tracks[track], state.route == .file else { return false }
            if let heldFrom = drop() {
                tracks[track]?.heldFrom = max(state.heldFrom ?? heldFrom, heldFrom)
            }
            return true
        }
    }

    /// Where the file read of a track must reach: the audio the pump holds,
    /// or `liveFrom` while it holds none yet (`isHeldAudio` false). Nil once
    /// the track no longer reads its file.
    func readTarget(_ track: LiveTrack) -> (time: TimeInterval, isHeldAudio: Bool)? {
        tracks.withLock { tracks in
            guard let state = tracks[track], state.route == .file else { return nil }
            return state.heldFrom.map { ($0, true) } ?? (liveFrom, false)
        }
    }

    /// The file read handed over the track's audio up to `time`. If that
    /// reaches the audio the pump holds, the track goes live. Returns whether
    /// it did.
    func reach(_ track: LiveTrack, through time: TimeInterval) -> Bool {
        tracks.withLock { tracks in
            guard let state = tracks[track], state.route == .file,
                  let heldFrom = state.heldFrom, time >= heldFrom - Self.tolerance
            else { return false }
            tracks[track]?.route = .live
            return true
        }
    }

    /// The file read cannot go on: the track goes live after a gap. Returns
    /// where the stretch it misses ends: the audio the pump holds, or
    /// `liveFrom`.
    func giveUp(_ track: LiveTrack) -> TimeInterval {
        tracks.withLock { tracks in
            let end = tracks[track]?.heldFrom ?? liveFrom
            if tracks[track]?.route == .file { tracks[track]?.route = .liveAfterGap }
            return end
        }
    }

    /// The pump handed on its first chunk after the gap, marked discontinuous.
    func joinedAfterGap(_ track: LiveTrack) {
        tracks.withLock { tracks in
            if tracks[track]?.route == .liveAfterGap { tracks[track]?.route = .live }
        }
    }

    /// Stop: tracks still reading their file drop the audio the pump holds.
    /// Returns them.
    func abandon() -> Set<LiveTrack> {
        tracks.withLock { tracks in
            let reading = tracks.filter { $0.value.route == .file }.keys
            for track in reading {
                tracks[track]?.route = .dropped
            }
            return Set(reading)
        }
    }
}

/// Turns a track's recording into 250 ms chunks of 16 kHz audio from 0:00,
/// resampled as the pump resamples the tap's blocks.
struct TrackFileChunker {
    /// One read covers a second at 24 kHz.
    static let readFrames = 24000

    let track: LiveTrack
    private let audio: any RecordedTrackAudio
    private let resampler: TrackResampler
    private var nextFrame: Int64 = 0
    /// Resampled audio not yet in a chunk.
    private var pending: [Float] = []
    private var sentSamples = 0

    init(track: LiveTrack, audio: any RecordedTrackAudio) throws {
        guard let resampler = TrackResampler(sampleRate: audio.sampleRate, channelCount: 1) else {
            throw RecordedTrackError.unsupportedFormat
        }
        self.track = track
        self.audio = audio
        self.resampler = resampler
    }

    /// Where the chunks made so far end.
    var end: TimeInterval {
        Double(sentSamples) / LiveAudioChunk.sampleRate
    }

    func hasReached(_ time: TimeInterval) -> Bool {
        Self.samples(through: time) <= sentSamples
    }

    /// The next chunk, at most 250 ms and ending no later than `time`. Nil
    /// when the file does not reach that far yet; the next call goes on from
    /// the same place.
    mutating func nextChunk(through time: TimeInterval) throws -> LiveAudioChunk? {
        let wanted = min(LivePumpCore.chunkSamples, Self.samples(through: time) - sentSamples)
        guard wanted > 0 else { return nil }
        while pending.count < wanted {
            let frames = try audio.read(from: nextFrame, count: Self.readFrames)
            guard !frames.isEmpty else { return nil }
            nextFrame += Int64(frames.count)
            pending += frames.withUnsafeBufferPointer { resampler.convert($0) }
        }
        let chunk = LiveAudioChunk(track: track, startTime: end, samples: Array(pending.prefix(wanted)))
        pending.removeFirst(wanted)
        sentSamples += wanted
        return chunk
    }

    private static func samples(through time: TimeInterval) -> Int {
        Int((time * LiveAudioChunk.sampleRate).rounded())
    }
}

/// Reads a start mid-recording's earlier audio from the recording's track
/// files and queues it in the session's pipe ahead of the live audio, so it
/// reaches the engine through the same catch-up as audio the pump held: as
/// backfill, no faster than the engine transcribes it.
final class LiveFileCatchUp: Sendable {
    enum Outcome: Equatable {
        /// The file was handed over through `time`, where the pump's audio begins.
        case reachedLive(through: TimeInterval)
        /// The file could not be read on. The gap, if any, is the stretch the
        /// live transcript misses before the pump's audio.
        case gaveUp(LiveGap?, reason: String)
        /// The session ended, or Stop abandoned the read.
        case stopped
    }

    private static let log = Logger(subsystem: "net.scosman.biscotti", category: "live")

    let handoff: FileCatchUpHandoff
    private let files: LiveRecordingFiles
    private let pipe: LiveChunkPipe
    private let pollInterval: Duration
    private let stallLimit: Duration

    /// - Parameter stallLimit: How long the file may stay short of the audio
    ///   the read needs before the read gives up (`LiveTiming.fileStallLimit`).
    init(files: LiveRecordingFiles, pipe: LiveChunkPipe, liveFrom: TimeInterval, pollInterval: Duration, stallLimit: Duration) {
        self.files = files
        self.pipe = pipe
        self.pollInterval = pollInterval
        self.stallLimit = stallLimit
        handoff = FileCatchUpHandoff(tracks: pipe.tracks, liveFrom: liveFrom)
    }

    /// Reads one track's file from 0:00 until it reaches the audio the pump
    /// holds, waiting for the pipe to take each chunk. Runs off the main actor.
    func read(_ track: LiveTrack) async -> Outcome {
        var chunker: TrackFileChunker
        do {
            chunker = try TrackFileChunker(track: track, audio: files.open(track))
        } catch {
            return giveUp(track, at: 0, reason: "the file did not open: \(error.localizedDescription)")
        }
        let liveFrom = handoff.liveFrom
        Self.log.notice("The live catch-up reads the \(track.rawValue, privacy: .public) file from 0:00; the live audio begins at \(liveFrom, format: .fixed(precision: 2), privacy: .public) s")
        var stall = FileStall(limit: stallLimit)
        while !Task.isCancelled {
            if let outcome = await step(&chunker, stall: &stall) { return outcome }
        }
        return .stopped
    }

    /// Hands over the next chunk, or waits for the pump's audio or the file.
    /// Returns the outcome once the read ends.
    private func step(_ chunker: inout TrackFileChunker, stall: inout FileStall) async -> Outcome? {
        let track = chunker.track
        guard let target = handoff.readTarget(track) else { return .stopped }
        if chunker.hasReached(target.time) {
            if target.isHeldAudio, handoff.reach(track, through: chunker.end) {
                return .reachedLive(through: chunker.end)
            }
            // The pump holds none of the track yet, or holds it from later now.
            return await pause() ? nil : .stopped
        }
        let chunk: LiveAudioChunk?
        do {
            chunk = try chunker.nextChunk(through: target.time)
        } catch {
            return giveUp(track, at: chunker.end, reason: "the file could not be read: \(error.localizedDescription)")
        }
        if let chunk {
            stall.reset()
            return await pipe.send(chunk) ? nil : .stopped
        }
        if stall.hasLasted() {
            return giveUp(track, at: chunker.end, reason: "the file stopped growing")
        }
        // The writer is a moment behind the tap.
        return await pause() ? nil : .stopped
    }

    /// The track goes live; what the read did not cover before the pump's
    /// audio is a gap. Whether it held sound is not known.
    private func giveUp(_ track: LiveTrack, at time: TimeInterval, reason: String) -> Outcome {
        let end = handoff.giveUp(track)
        guard end - time > LiveTranscriptStore.gapJoinTolerance else { return .gaveUp(nil, reason: reason) }
        return .gaveUp(LiveGap(track: track, startTime: time, duration: end - time, reason: .queueOverflow), reason: reason)
    }

    /// How long the file has stayed short of what the read needs.
    private struct FileStall {
        let limit: Duration
        private var since: ContinuousClock.Instant?

        init(limit: Duration) {
            self.limit = limit
        }

        /// Notes that the file is short now; true once it has been for `limit`.
        mutating func hasLasted() -> Bool {
            let now = ContinuousClock.now
            let since = since ?? now
            self.since = since
            return now - since >= limit
        }

        mutating func reset() {
            since = nil
        }
    }

    /// False once the read should end: its task was cancelled, or the
    /// session ended and finished the pipe.
    private func pause() async -> Bool {
        do { try await Task.sleep(for: pollInterval) } catch { return false }
        return !pipe.isFinished
    }
}
