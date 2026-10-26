import LiveTranscriptModel

/// Cuts released audio into the 250 ms chunks the app's pump sends: one per
/// track (mic first), or both tracks summed in mixed mode. Replayed audio has
/// no gaps, so no chunk is marked discontinuous.
struct ChunkAssembler {
    static let chunkSamples = 4000

    let mode: BenchMode
    private var sentSamples = 0

    init(mode: BenchMode) {
        self.mode = mode
    }

    /// The whole chunks that `releasedSamples` completes.
    mutating func take(releasedSamples: Int, of clip: ClipAudio) -> [LiveAudioChunk] {
        var chunks: [LiveAudioChunk] = []
        while sentSamples + Self.chunkSamples <= min(releasedSamples, clip.sampleCount) {
            chunks += makeChunks(sentSamples ..< sentSamples + Self.chunkSamples, of: clip)
            sentSamples += Self.chunkSamples
        }
        return chunks
    }

    /// The last, shorter chunks at the end of the clip.
    mutating func flush(_ clip: ClipAudio) -> [LiveAudioChunk] {
        var chunks = take(releasedSamples: clip.sampleCount, of: clip)
        if sentSamples < clip.sampleCount {
            chunks += makeChunks(sentSamples ..< clip.sampleCount, of: clip)
            sentSamples = clip.sampleCount
        }
        return chunks
    }

    private func makeChunks(_ range: Range<Int>, of clip: ClipAudio) -> [LiveAudioChunk] {
        let startTime = Double(range.lowerBound) / LiveAudioChunk.sampleRate
        switch mode {
        case .twoTrack:
            return [
                LiveAudioChunk(track: .mic, startTime: startTime, samples: Array(clip.mic[range])),
                LiveAudioChunk(track: .system, startTime: startTime, samples: Array(clip.system[range]))
            ]
        case .mixed:
            let samples = zip(clip.mic[range], clip.system[range]).map(+)
            return [LiveAudioChunk(track: .mixed, startTime: startTime, samples: samples)]
        }
    }
}
