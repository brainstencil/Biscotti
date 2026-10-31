import AVFoundation
import LiveTranscriptModel

/// The recording's track files. A live transcript turned on mid-recording
/// reads them from 0:00 up to where its live audio begins, so it catches up
/// from the start of the recording.
public struct LiveRecordingFiles: Sendable {
    let open: @Sendable (LiveTrack) throws -> any RecordedTrackAudio

    /// The recorder's ADTS AAC files, still being written.
    public init(mic: URL, system: URL) {
        open = { track in
            switch track {
            case .mic: try AACTrackFile(url: mic)
            case .system: try AACTrackFile(url: system)
            case .mixed: throw RecordedTrackError.noFile
            }
        }
    }

    init(open: @escaping @Sendable (LiveTrack) throws -> any RecordedTrackAudio) {
        self.open = open
    }
}

enum RecordedTrackError: Error {
    case noFile
    case unsupportedFormat
}

/// One track's recording, read while its writer still adds to it.
protocol RecordedTrackAudio {
    /// Mono frames per second.
    var sampleRate: Double { get }

    /// Up to `count` mono frames from `frame` on, where frame 0 is 0:00 on the
    /// recording timeline. Fewer, or none, when the file does not reach that
    /// far yet.
    func read(from frame: Int64, count: Int) throws -> [Float]
}

/// A track's ADTS AAC file. The file's timeline is the recording's: the
/// writer fills capture gaps with silence and the system track starts with
/// the silence that aligns it with the mic.
///
/// An open `AVAudioFile` keeps the length it found when it opened, so a read
/// that needs audio past it opens the file again (well under a millisecond).
final class AACTrackFile: RecordedTrackAudio {
    /// Apple's AAC-LC encoder starts every stream with 2,112 frames of encoder
    /// delay. MP4 and CAF files record it and decoders skip it; ADTS has no
    /// field for it, so every frame decodes 2,112 frames late.
    static let primingFrames: Int64 = 2112

    let url: URL
    let sampleRate: Double
    private var file: AVAudioFile

    init(url: URL) throws {
        self.url = url
        file = try Self.open(url)
        guard file.processingFormat.channelCount > 0 else { throw RecordedTrackError.unsupportedFormat }
        sampleRate = file.processingFormat.sampleRate
    }

    /// The file's last packets may still be being written: a failure to
    /// open it again, or to decode near its end, reads as no audio yet.
    func read(from frame: Int64, count: Int) throws -> [Float] {
        guard count > 0 else { return [] }
        let position = frame + Self.primingFrames
        if position + Int64(count) > file.length, let reopened = try? Self.open(url) {
            file = reopened
        }
        let available = file.length - position
        guard available > 0 else { return [] }
        let frames = AVAudioFrameCount(min(Int64(count), available))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return [] }
        // Setting the position seeks the decoder even when it is already
        // there; reading on from where the last read ended does not.
        if file.framePosition != position { file.framePosition = position }
        do {
            try file.read(into: buffer, frameCount: frames)
        } catch {
            guard position + Int64(frames) >= file.length - Self.tailFrames else { throw error }
            // The decoder starts again from a fresh open.
            if let reopened = try? Self.open(url) { file = reopened }
            return []
        }
        return Self.mono(buffer)
    }

    /// The end of the file a read failure is taken as unfinished: two AAC packets.
    private static let tailFrames: Int64 = 2048

    private static func open(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// The buffer's channels averaged. The recorder writes mono.
    private static func mono(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        guard count > 1 else { return Array(UnsafeBufferPointer(start: channels[0], count: frames)) }
        let scale = 1 / Float(count)
        return (0 ..< frames).map { frame in
            (0 ..< count).reduce(Float(0)) { $0 + channels[$1][frame] } * scale
        }
    }
}
