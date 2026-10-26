import AVFoundation
import Foundation
import Testing
@testable import live_bench

@Suite("Clip audio")
struct ClipAudioTests {
    @Test("a clip loads both 16 kHz tracks, pads the shorter one and reads its vocabulary")
    func clipLoadsTracksAndVocabulary() throws {
        let temporary = try TemporaryFolder()
        defer { temporary.remove() }
        let folder = try temporary.folder("fixtures/smoke")
        try writeWAV(Array(repeating: 0.25, count: 1600), rate: 16000, to: folder.appending(path: "mic.wav"))
        try writeWAV(Array(repeating: 0.5, count: 800), rate: 16000, to: folder.appending(path: "system.wav"))
        try temporary.file("fixtures/smoke/meta.json", contents: #"{"vocabulary": ["Biscotti"], "lead_in": 5}"#)

        let clip = try ClipAudio.load(id: "smoke", fixtures: temporary.url.appending(path: "fixtures"))

        #expect(clip.sampleCount == 1600)
        #expect(clip.duration == 0.1)
        #expect(abs(clip.mic[100] - 0.25) < 1e-3)
        #expect(clip.system[1599] == 0)
        #expect(abs(clip.mixed[0] - 0.75) < 1e-3)
        #expect(clip.vocabulary == ["Biscotti"])
    }

    @Test("audio that is not 16 kHz mono is refused, and a missing clip names its folder")
    func wrongFormatAndMissingClipAreRefused() throws {
        let temporary = try TemporaryFolder()
        defer { temporary.remove() }
        let wav = temporary.url.appending(path: "48k.wav")
        try writeWAV(Array(repeating: 0, count: 4800), rate: 48000, to: wav)

        let wrongRate = #expect(throws: BenchError.self) { try ClipAudio.readMono16k(wav) }
        #expect(wrongRate?.description.contains("16 kHz mono") == true)

        let missing = #expect(throws: BenchError.self) { try ClipAudio.load(id: "nope", fixtures: temporary.url) }
        #expect(missing?.description.contains("nope") == true)
    }

    private func writeWAV(_ samples: [Float], rate: Double, to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channel = try #require(buffer.floatChannelData?[0])
        samples.enumerated().forEach { channel[$0.offset] = $0.element }
        try file.write(from: buffer)
    }
}
