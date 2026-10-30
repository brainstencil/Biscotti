import AudioCapture
import AudioToolbox
import AVFoundation
import BiscottiTestSupport
import Foundation
import LiveTranscriptModel
import Synchronization
import Testing
@testable import LiveTranscriptionService

// MARK: - Fakes and fixtures

/// A track file the test writes, read as the catch-up reads a recording's.
/// Frame `n` holds `value(n)`; it reaches `seconds` until it grows.
final class ScriptedTrackFile: RecordedTrackAudio, Sendable {
    let sampleRate: Double
    private let length: Mutex<Int64>
    private let value: @Sendable (Int64) -> Float

    init(seconds: TimeInterval, sampleRate: Double = 16000, value: @escaping @Sendable (Int64) -> Float = { _ in 0.25 }) {
        self.sampleRate = sampleRate
        self.value = value
        length = Mutex(Int64((seconds * sampleRate).rounded()))
    }

    func grow(to seconds: TimeInterval) {
        length.withLock { $0 = Int64((seconds * sampleRate).rounded()) }
    }

    func read(from frame: Int64, count: Int) throws -> [Float] {
        let end = min(frame + Int64(count), length.withLock { $0 })
        guard end > frame else { return [] }
        return (frame ..< end).map(value)
    }

    /// The same file for every track.
    var files: LiveRecordingFiles {
        LiveRecordingFiles { _ in self }
    }
}

/// Writes an ADTS AAC file as the recorder does: 24 kHz mono at the voice
/// bit rate, written in 100 ms blocks, readable while it is still open.
private final class ADTSWriter {
    static let rate = 24000.0
    let url: URL
    private let file: ExtAudioFileRef

    init(url: URL) throws {
        self.url = url
        var output = AudioStreamBasicDescription(
            mSampleRate: Self.rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
        )
        var created: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileAAC_ADTSType, &output, nil, AudioFileFlags.eraseFile.rawValue, &created)
        guard status == noErr, let created else { throw WriterError(status: status) }
        file = created
        var client = AudioStreamBasicDescription(
            mSampleRate: Self.rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        let clientStatus = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard clientStatus == noErr else { throw WriterError(status: clientStatus) }
        let rateStatus = EncoderSettings.applyBitRate(to: file, bitRate: EncoderSettings.voice.bitRate)
        guard rateStatus == noErr else { throw WriterError(status: rateStatus) }
    }

    /// `seconds` of silence, or of a 1 kHz tone.
    func write(seconds: TimeInterval, tone: Bool) throws {
        let frames = Int((seconds * Self.rate).rounded())
        try write((0 ..< frames).map { tone ? 0.5 * sin(Float($0) * 2 * .pi * 1000 / Float(Self.rate)) : 0 })
    }

    func write(_ samples: [Float]) throws {
        var samples = samples
        let block = 2400
        for start in stride(from: 0, to: samples.count, by: block) {
            let count = min(block, samples.count - start)
            let status = samples[start ..< start + count].withUnsafeMutableBytes { raw in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return ExtAudioFileWrite(file, UInt32(count), &list)
            }
            guard status == noErr else { throw WriterError(status: status) }
        }
    }

    func close() {
        ExtAudioFileDispose(file)
    }

    struct WriterError: Error {
        let status: OSStatus
    }
}

private func temporaryAACURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("live-catch-up-\(UUID().uuidString).aac")
}

/// The first frame louder than 0.1.
private func onset(_ samples: [Float]) -> Int? {
    samples.firstIndex { abs($0) > 0.1 }
}

/// True when each chunk starts where the one before it ended.
private func isContiguous(_ chunks: [LiveAudioChunk]) -> Bool {
    zip(chunks, chunks.dropFirst()).allSatisfy { abs($1.startTime - $0.endTime) < 1e-6 }
}

/// Reads every chunk of `track` the pipe carries, freeing each slot, until
/// the read ends.
private func drain(_ pipe: LiveChunkPipe, _ track: LiveTrack, until read: Task<LiveFileCatchUp.Outcome, Never>) async -> (LiveFileCatchUp.Outcome, [LiveAudioChunk]) {
    let collector = Task {
        var chunks: [LiveAudioChunk] = []
        for await chunk in pipe.chunks(of: track) {
            chunks.append(chunk)
            pipe.release(track)
        }
        return chunks
    }
    let outcome = await read.value
    pipe.finish()
    return await (outcome, collector.value)
}

// MARK: - Recorded track files

@Suite("Recorded track files")
struct RecordedTrackFileTests {
    @Test("A track file reads from 0:00 on the recording timeline, without the AAC encoder's delay")
    func readsOnTheRecordingTimeline() throws {
        let url = temporaryAACURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ADTSWriter(url: url)
        try writer.write(seconds: 1, tone: false)
        try writer.write(seconds: 0.5, tone: true)
        try writer.write(seconds: 1, tone: false)
        writer.close()

        let file = try AACTrackFile(url: url)
        #expect(file.sampleRate == 24000)
        let samples = try file.read(from: 0, count: 60000)
        let start = try #require(onset(samples))
        // The tone starts at 1.0 s, frame 24,000; its first loud frame follows within a cycle.
        #expect(abs(start - 24000) <= 32, "onset at \(start)")
        // Reading from a later frame lands on the same timeline.
        let later = try file.read(from: 23000, count: 2000)
        let laterStart = try #require(onset(later))
        #expect(abs(laterStart + 23000 - start) <= 8)
    }

    @Test("A file still being written is read as it grows; a read past its end returns nothing")
    func readsAGrowingFile() throws {
        let url = temporaryAACURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ADTSWriter(url: url)
        defer { writer.close() }
        try writer.write(seconds: 2, tone: true)

        let file = try AACTrackFile(url: url)
        let first = try file.read(from: 0, count: 96000)
        // Nothing past what was written can decode. The encoder holds back
        // only its delay and lookahead (about 0.1 s here) and writes each
        // packet as it makes it: the recorder's crash safety rests on that
        // (audio research, phase 9 test 5). 0.5 s leaves room for other
        // macOS versions.
        #expect(first.count <= 48000 && first.count >= 48000 - 12000, "read \(first.count) frames")
        #expect(try file.read(from: Int64(first.count), count: 2400).isEmpty)

        try writer.write(seconds: 2, tone: true)
        let more = try file.read(from: Int64(first.count), count: 96000)
        #expect(first.count + more.count >= 96000 - 12000, "the reopened file reaches further")
    }

    @Test("Reads that open the file again and seek stay on the recording timeline, sample for sample, two minutes in")
    func reopenedReadsStayOnTheTimeline() throws {
        let url = temporaryAACURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try ADTSWriter(url: url)
        // Two minutes of quiet noise, with a 300 ms burst after 50 ms of
        // silence at each of these times.
        let bursts: [TimeInterval] = [10, 30.25, 61.5, 90, 118.75]
        var seed: UInt64 = 42
        let samples = (0 ..< 120 * 24000).map { frame -> Float in
            let time = Double(frame) / ADTSWriter.rate
            if let burst = bursts.first(where: { time >= $0 - 0.05 && time < $0 + 0.3 }) {
                return time < burst ? 0 : 0.6 * sin(Float(time - burst) * 2 * .pi * 800)
            }
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: seed >> 11) % 1000) / 20000
        }
        // Each piece is read from a file opened afresh while it still grows.
        var pieces: [Float] = []
        for second in stride(from: 0, to: 120, by: 10) {
            try writer.write(Array(samples[second * 24000 ..< (second + 10) * 24000]))
            let start = Int64(pieces.count)
            pieces += try AACTrackFile(url: url).read(from: start, count: (second + 10) * 24000 - Int(start))
        }
        writer.close()
        pieces += try AACTrackFile(url: url).read(from: Int64(pieces.count), count: samples.count)

        let sequential = try AACTrackFile(url: url).read(from: 0, count: samples.count + 4096)
        #expect(pieces.count == sequential.count)
        // The AAC decoder's output after a seek need not be bit-identical on other macOS versions (CI runs macOS 15).
        let largestDifference = zip(pieces, sequential).map { abs($0 - $1) }.max() ?? 0
        #expect(largestDifference < 1e-4, "reopening and seeking decode the same samples, largest difference \(largestDifference)")
        for burst in bursts {
            let frame = Int(burst * ADTSWriter.rate)
            let start = try #require(sequential[(frame - 1000)...].firstIndex { abs($0) > 0.3 })
            #expect(start >= frame && start <= frame + 8, "the burst at \(burst) s starts at frame \(start)")
        }
    }

    @Test("A recording file that does not exist does not open")
    func missingFileDoesNotOpen() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).aac")
        let files = LiveRecordingFiles(mic: missing, system: missing)
        #expect(throws: (any Error).self) { try files.open(.mic) }
    }
}

// MARK: - Chunking

@Suite("TrackFileChunker")
struct TrackFileChunkerTests {
    @Test("File audio becomes 250 ms chunks from 0:00; the last ends where the pump's audio begins, and the next continues there")
    func chunksEndAtTheHandoff() throws {
        let file = ScriptedTrackFile(seconds: 3, value: { Float($0 % 1000) / 1000 })
        var chunker = try TrackFileChunker(track: .mic, audio: file)
        var chunks: [LiveAudioChunk] = []
        while let chunk = try chunker.nextChunk(through: 1.1) {
            chunks.append(chunk)
        }
        #expect(chunks.map(\.startTime) == [0, 0.25, 0.5, 0.75, 1.0])
        #expect(chunks.last?.samples.count == 1600)
        #expect(chunker.hasReached(1.1) && abs(chunker.end - 1.1) < 1e-9)
        #expect(chunks.flatMap(\.samples) == (0 ..< 17600).map { Float($0 % 1000) / 1000 })

        let following = try chunker.nextChunk(through: 1.6)
        let next = try #require(following)
        #expect(abs(next.startTime - 1.1) < 1e-9 && next.samples.count == 4000)
        #expect(next.samples.first == Float(17600 % 1000) / 1000)
        #expect(!chunks.contains { $0.isDiscontinuity || $0.isBackfill })
    }

    @Test("24 kHz file audio becomes 16 kHz chunks at exact times")
    func resamplesTo16kHz() throws {
        let file = ScriptedTrackFile(seconds: 2, sampleRate: 24000, value: { sin(Float($0) * 0.0577) * 0.5 })
        var chunker = try TrackFileChunker(track: .system, audio: file)
        var chunks: [LiveAudioChunk] = []
        while let chunk = try chunker.nextChunk(through: 1) {
            chunks.append(chunk)
        }
        #expect(chunks.map(\.startTime) == [0, 0.25, 0.5, 0.75])
        #expect(chunks.allSatisfy { $0.samples.count == 4000 && $0.track == .system })
    }

    @Test("A file short of the target gives no chunk until it grows")
    func waitsForTheFileToGrow() throws {
        let file = ScriptedTrackFile(seconds: 0.3)
        var chunker = try TrackFileChunker(track: .mic, audio: file)
        let first = try chunker.nextChunk(through: 1)
        #expect(first?.startTime == 0)
        let none = try chunker.nextChunk(through: 1)
        #expect(none == nil)
        file.grow(to: 1)
        let grown = try chunker.nextChunk(through: 1)
        let chunk = try #require(grown)
        #expect(chunk.startTime == 0.25)
    }
}

// MARK: - Handoff

@Suite("FileCatchUpHandoff")
struct FileCatchUpHandoffTests {
    @Test("A track reads its file to where the pump's audio begins, follows that as the pump drops, then goes live")
    func readsToTheHeldAudioThenGoesLive() {
        let handoff = FileCatchUpHandoff(tracks: [.mic, .system], liveFrom: 10)
        #expect(handoff.route(.mic) == .file)
        #expect(handoff.route(.mixed) == .live, "a track the handoff does not cover")
        #expect(handoff.readTarget(.mic)?.time == 10 && handoff.readTarget(.mic)?.isHeldAudio == false)
        #expect(!handoff.reach(.mic, through: 10), "the pump holds none of the track yet")

        #expect(handoff.pumpHolds(.mic, from: 10.3))
        #expect(handoff.readTarget(.mic)?.time == 10.3 && handoff.readTarget(.mic)?.isHeldAudio == true)
        #expect(handoff.coverDrop(.mic) { 12 }, "the pump dropped its oldest chunks")
        #expect(!handoff.reach(.mic, through: 10.3))
        #expect(handoff.reach(.mic, through: 12))
        #expect(handoff.route(.mic) == .live)
        #expect(handoff.readTarget(.mic) == nil)
        #expect(!handoff.coverDrop(.mic) { 20 }, "a live track's drops are gaps")
        #expect(handoff.readTarget(.mic) == nil)
    }

    @Test("A read that gives up goes live after a gap and names where the stretch it misses ends; Stop drops the tracks still reading")
    func giveUpAndAbandon() {
        let handoff = FileCatchUpHandoff(tracks: [.mic, .system], liveFrom: 10)
        handoff.pumpHolds(.mic, from: 10.4)
        #expect(handoff.giveUp(.mic) == 10.4)
        #expect(handoff.route(.mic) == .liveAfterGap)
        handoff.joinedAfterGap(.mic)
        #expect(handoff.route(.mic) == .live)
        #expect(handoff.abandon() == [.system])
        #expect(handoff.route(.system) == .dropped)
        #expect(handoff.readTarget(.system) == nil)
        #expect(handoff.abandon().isEmpty)
    }
}

// MARK: - Pump

/// A pump core whose tracks read their file, and what it hands on.
private final class HandoffPump {
    let handoff: FileCatchUpHandoff
    var chunks: [LiveAudioChunk] = []
    var gaps: [LiveGap] = []
    var accepts = true
    lazy var core = LivePumpCore(
        discardBefore: handoff.liveFrom,
        handoff: handoff,
        sink: { [unowned self] chunk in
            guard accepts else { return false }
            chunks.append(chunk)
            return true
        },
        onGap: { [unowned self] in gaps.append($0) }
    )

    init(liveFrom: TimeInterval) {
        handoff = FileCatchUpHandoff(tracks: [.mic, .system], liveFrom: liveFrom)
    }

    /// `seconds` of 16 kHz tone in `blockSeconds` blocks from `start`.
    func feed(seconds: TimeInterval, from start: TimeInterval, blockSeconds: TimeInterval = 0.1) {
        let frames = Int((blockSeconds * 16000).rounded())
        for block in 0 ..< Int((seconds / blockSeconds).rounded()) {
            let samples = (0 ..< frames).map { sin(Float(block * frames + $0) * 0.0577) * 0.5 }
            samples.withUnsafeBufferPointer {
                core.process(LiveAudioBlock(startTime: start + Double(block) * blockSeconds, kind: .samples($0, sampleRate: 16000, channelCount: 1)), on: .mic)
            }
        }
    }
}

@Suite("LivePumpCore during a catch-up from the files")
struct LivePumpCoreCatchUpTests {
    @Test("While a track reads its file the pump holds its chunks and says where they begin; the tap's overflow before them is no gap")
    func holdsChunksUntilTheFileReadReachesThem() {
        let pump = HandoffPump(liveFrom: 10)
        // The tap's queue filled at 4 s and dropped audio until 12.5 s, well
        // past the start: without the file read, a gap.
        pump.feed(seconds: 4, from: 0, blockSeconds: 0.5)
        pump.core.process(LiveAudioBlock(startTime: 4, kind: .gap(duration: 8.5, kind: .overflow)), on: .mic)
        pump.feed(seconds: 2, from: 12.5)
        pump.core.offerWaiting()

        #expect(pump.gaps.isEmpty)
        #expect(pump.chunks.isEmpty, "held while the file is read")
        #expect(pump.handoff.readTarget(.mic)?.time == 12.5)

        #expect(pump.handoff.reach(.mic, through: 12.5))
        pump.core.offerWaiting()
        #expect(pump.chunks.map(\.startTime) == (0 ..< 8).map { 12.5 + Double($0) * 0.25 })
        #expect(!pump.chunks.contains { $0.isDiscontinuity })
    }

    @Test("A catch-up longer than the retention loses nothing: the file read covers what the pump drops")
    func retentionDropsAreReadFromTheFile() throws {
        let pump = HandoffPump(liveFrom: 0)
        let total = LivePumpCore.retention + 5
        pump.feed(seconds: total, from: 0, blockSeconds: 5)

        #expect(pump.gaps.isEmpty)
        #expect(pump.handoff.readTarget(.mic)?.time == 5, "the oldest chunk the pump still holds")
        #expect(pump.handoff.reach(.mic, through: 5))
        pump.core.offerWaiting()
        let first = try #require(pump.chunks.first)
        #expect(first.startTime == 5 && !first.isDiscontinuity)
        #expect(isContiguous(pump.chunks))
        #expect(abs((pump.chunks.last?.endTime ?? 0) - total) < 1e-9)

        // Live now: what the retention drops is lost, as before.
        pump.accepts = false
        pump.feed(seconds: LivePumpCore.retention + 10, from: total, blockSeconds: 5)
        #expect(!pump.gaps.isEmpty)
    }

    @Test("After a read that gave up, the first chunk the pump hands on is discontinuous, whether it waited or came later")
    func giveUpMakesTheJoinDiscontinuous() {
        let held = HandoffPump(liveFrom: 0)
        held.feed(seconds: 1, from: 0)
        _ = held.handoff.giveUp(.mic)
        held.core.offerWaiting()
        #expect(held.chunks.map(\.isDiscontinuity) == [true, false, false, false])
        held.feed(seconds: 0.5, from: 1)
        #expect(held.chunks.count == 6 && held.chunks.dropFirst().allSatisfy { !$0.isDiscontinuity })
        #expect(held.handoff.route(.mic) == .live)

        // The read gave up before the pump held any of the track.
        let later = HandoffPump(liveFrom: 0)
        _ = later.handoff.giveUp(.mic)
        later.feed(seconds: 0.5, from: 3)
        #expect(later.chunks.map(\.isDiscontinuity) == [true, false])
    }

    @Test("After Stop abandons the read, the pump drops the track's audio and ends")
    func abandonedTrackDropsItsAudio() {
        let pump = HandoffPump(liveFrom: 0)
        pump.feed(seconds: 2, from: 0)
        #expect(pump.handoff.abandon() == [.mic, .system])
        pump.core.offerWaiting()
        pump.feed(seconds: 1, from: 2)
        pump.core.process(LiveAudioBlock(startTime: 3, kind: .end), on: .mic)
        pump.core.process(LiveAudioBlock(startTime: 3, kind: .end), on: .system)
        #expect(pump.core.isEnded)
        #expect(pump.chunks.isEmpty)
        #expect(pump.gaps.isEmpty, "the session records what Stop left untranscribed")
        #expect(pump.core.chunkExtents[.mic]?.end == 3)
    }
}

// MARK: - File read

@Suite("LiveFileCatchUp")
struct LiveFileCatchUpTests {
    private func catchUp(_ file: ScriptedTrackFile, liveFrom: TimeInterval, stallLimit: Duration = .seconds(5)) -> (LiveFileCatchUp, LiveChunkPipe) {
        let pipe = LiveChunkPipe(tracks: [.mic])
        let catchUp = LiveFileCatchUp(files: file.files, pipe: pipe, liveFrom: liveFrom, pollInterval: .milliseconds(5), stallLimit: stallLimit)
        return (catchUp, pipe)
    }

    @Test("The read queues the file's audio from 0:00 up to where the pump's audio begins, then the track goes live")
    func readsUpToTheLiveAudio() async {
        let (catchUp, pipe) = catchUp(ScriptedTrackFile(seconds: 5), liveFrom: 1.5)
        catchUp.handoff.pumpHolds(.mic, from: 1.6)
        let read = Task { await catchUp.read(.mic) }
        let (outcome, chunks) = await drain(pipe, .mic, until: read)

        #expect(outcome == .reachedLive(through: 1.6))
        #expect(chunks.first?.startTime == 0)
        #expect(isContiguous(chunks))
        #expect(abs((chunks.last?.endTime ?? 0) - 1.6) < 1e-9)
        #expect(catchUp.handoff.route(.mic) == .live)
    }

    @Test("A catch-up longer than the pump's retention reads on through the audio the pump dropped meanwhile")
    func readsOnThroughDroppedAudio() async {
        let (catchUp, pipe) = catchUp(ScriptedTrackFile(seconds: 10), liveFrom: 4)
        catchUp.handoff.pumpHolds(.mic, from: 4)
        let read = Task { await catchUp.read(.mic) }
        // The pipe's eight slots hold 2 s: the read waits there, short of 4 s.
        var iterator = pipe.chunks(of: .mic).makeAsyncIterator()
        var chunks: [LiveAudioChunk] = []
        for _ in 0 ..< LiveChunkPipe.limit {
            if let chunk = await iterator.next() { chunks.append(chunk) }
        }
        // The pump dropped its held audio up to 7 s, beyond its retention.
        #expect(catchUp.handoff.coverDrop(.mic) { 7 })
        let finished = Task {
            let outcome = await read.value
            pipe.finish()
            return outcome
        }
        for _ in 0 ..< LiveChunkPipe.limit {
            pipe.release(.mic)
        }
        while let chunk = await iterator.next() {
            chunks.append(chunk)
            pipe.release(.mic)
        }
        let outcome = await finished.value

        #expect(outcome == .reachedLive(through: 7))
        #expect(chunks.first?.startTime == 0)
        #expect(isContiguous(chunks))
        #expect(abs((chunks.last?.endTime ?? 0) - 7) < 1e-9)
    }

    @Test("A file that stops short gives up after the stall limit; the rest up to the pump's audio is a gap")
    func stalledFileGivesUp() async {
        let (catchUp, pipe) = catchUp(ScriptedTrackFile(seconds: 1), liveFrom: 3, stallLimit: .milliseconds(50))
        catchUp.handoff.pumpHolds(.mic, from: 3)
        let read = Task { await catchUp.read(.mic) }
        let (outcome, chunks) = await drain(pipe, .mic, until: read)

        guard case let .gaveUp(gap, _) = outcome else {
            Issue.record("expected a give-up, got \(outcome)")
            return
        }
        #expect(gap == LiveGap(track: .mic, startTime: 1, duration: 2, reason: .queueOverflow))
        #expect(abs((chunks.last?.endTime ?? 0) - 1) < 1e-9)
        #expect(catchUp.handoff.route(.mic) == .liveAfterGap)
    }

    @Test("A file that does not open is a gap from 0:00")
    func unopenedFileIsAGapFromTheStart() async {
        let pipe = LiveChunkPipe(tracks: [.mic])
        let files = LiveRecordingFiles { _ in throw RecordedTrackError.noFile }
        let catchUp = LiveFileCatchUp(files: files, pipe: pipe, liveFrom: 3, pollInterval: .milliseconds(5), stallLimit: .seconds(5))
        let outcome = await catchUp.read(.mic)
        guard case let .gaveUp(gap, _) = outcome else {
            Issue.record("expected a give-up, got \(outcome)")
            return
        }
        #expect(gap == LiveGap(track: .mic, startTime: 0, duration: 3, reason: .queueOverflow))
    }

    @Test("A read Stop abandons ends")
    func abandonedReadEnds() async {
        let (catchUp, pipe) = catchUp(ScriptedTrackFile(seconds: 10), liveFrom: 5)
        let read = Task { await catchUp.read(.mic) }
        _ = catchUp.handoff.abandon()
        let (outcome, _) = await drain(pipe, .mic, until: read)
        #expect(outcome == .stopped)
    }
}

@Suite("LiveChunkPipe send")
struct LiveChunkPipeSendTests {
    @Test("Send waits for a free slot of its track, and returns false once the pipe finishes")
    func sendWaitsForASlot() async throws {
        let pipe = LiveChunkPipe()
        let chunk = LiveAudioChunk(track: .mic, startTime: 0, samples: [0])
        for _ in 0 ..< LiveChunkPipe.limit {
            #expect(await pipe.send(chunk))
        }
        let sent = Mutex(false)
        let waiting = Task {
            let taken = await pipe.send(chunk)
            sent.withLock { $0 = taken }
            return taken
        }
        #expect(pipe.offer(LiveAudioChunk(track: .system, startTime: 0, samples: [0])))
        pipe.release(.system)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!sent.withLock { $0 }, "a system slot does not let a mic chunk through")
        pipe.release(.mic)
        #expect(await waiting.value, "a slot of its own track freed")

        let blocked = Task { await pipe.send(chunk) }
        try await Task.sleep(for: .milliseconds(20))
        pipe.finish()
        #expect(await blocked.value == false)
        #expect(await pipe.send(chunk) == false)
    }

    @Test("A cancelled send stops waiting")
    func cancelledSendStops() async throws {
        let pipe = LiveChunkPipe()
        let chunk = LiveAudioChunk(track: .mic, startTime: 0, samples: [0])
        for _ in 0 ..< LiveChunkPipe.limit {
            #expect(pipe.offer(chunk))
        }
        let waiting = Task { await pipe.send(chunk) }
        try await Task.sleep(for: .milliseconds(20))
        waiting.cancel()
        #expect(await waiting.value == false)
    }
}
