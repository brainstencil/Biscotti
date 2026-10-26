import AVFoundation
import Foundation
import LiveTranscriptModel

/// One fixture clip in memory: `<fixtures>/<id>/mic.wav` and `system.wav`,
/// 16 kHz mono, as `make_fixtures.py` writes them.
struct ClipAudio {
    static let trackFiles = ["mic.wav", "system.wav"]
    /// Files whose hashes the manifest records.
    static let recordedFiles = ["mic.wav", "system.wav", "mixed.wav", "reference.json", "meta.json"]

    let id: String
    /// Both tracks have the same length; the shorter one is padded with silence.
    let mic: [Float]
    let system: [Float]
    /// Terms passed to the session unless `--vocabulary-off` (gated runs).
    let vocabulary: [String]

    var sampleCount: Int {
        mic.count
    }

    var duration: TimeInterval {
        Double(sampleCount) / LiveAudioChunk.sampleRate
    }

    /// Both tracks summed, as mixed mode and the cost check hear them.
    var mixed: [Float] {
        zip(mic, system).map(+)
    }

    init(id: String, mic: [Float], system: [Float], vocabulary: [String] = []) {
        let count = max(mic.count, system.count)
        self.id = id
        self.mic = mic + Array(repeating: 0, count: count - mic.count)
        self.system = system + Array(repeating: 0, count: count - system.count)
        self.vocabulary = vocabulary
    }

    /// The first `seconds` of the clip, for dry runs of the harness.
    func prefix(seconds: Double?) -> ClipAudio {
        guard let seconds else { return self }
        let count = min(sampleCount, Int(seconds * LiveAudioChunk.sampleRate))
        return ClipAudio(id: id, mic: Array(mic.prefix(count)), system: Array(system.prefix(count)), vocabulary: vocabulary)
    }

    static func folder(of id: String, in fixtures: URL) throws -> URL {
        try PathGuard.checkName(id, flag: "--clips")
        return fixtures.appending(path: id, directoryHint: .isDirectory)
    }

    static func load(id: String, fixtures: URL) throws -> ClipAudio {
        let folder = try folder(of: id, in: fixtures)
        let needed = trackFiles + ["meta.json"]
        guard needed.allSatisfy({ FileManager.default.fileExists(atPath: folder.appending(path: $0).path) }) else {
            throw BenchError.missingClip(id: id, folder: folder.path)
        }
        let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: folder.appending(path: "meta.json")))
        return try ClipAudio(
            id: id,
            mic: readMono16k(folder.appending(path: "mic.wav")),
            system: readMono16k(folder.appending(path: "system.wav")),
            vocabulary: meta.vocabulary ?? []
        )
    }

    /// Reads a 16 kHz mono file as Float32 samples. Any other format is
    /// refused rather than resampled, so the replay hears the fixture exactly.
    static func readMono16k(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw BenchError.unreadableAudio(path: url.path, reason: error.localizedDescription)
        }
        let format = file.fileFormat
        guard format.sampleRate == LiveAudioChunk.sampleRate, format.channelCount == 1 else {
            throw BenchError.unreadableAudio(path: url.path, reason: "expected 16 kHz mono, found \(format.sampleRate) Hz with \(format.channelCount) channels")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw BenchError.unreadableAudio(path: url.path, reason: "cannot allocate \(file.length) frames")
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw BenchError.unreadableAudio(path: url.path, reason: "no Float32 samples")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private struct Meta: Decodable {
        var vocabulary: [String]?
    }
}
