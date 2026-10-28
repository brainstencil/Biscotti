import Foundation
import Testing
import WhisperKit
@testable import Transcription

@Suite("Method resolution")
struct MethodResolutionTests {
    @Test("current method id is v3")
    func currentIsV3() {
        #expect(TranscriptionMethod.current.id == "v3")
        #expect(TranscriptionMethod.v3.id == "v3")
        #expect(TranscriptionMethod.v2.id == "v2")
        #expect(TranscriptionMethod.v1.id == "v1")
    }

    // MARK: - RAM-aware resolution (now internal to the method resolver)

    @Test("v1 resolves to the single STT model + sequential loading at 8 GB")
    func resolvesWithSequentialLoadingAt8GB() {
        let eightGB: UInt64 = 8 * 1024 * 1024 * 1024
        let settings = MethodResolver.resolve(.v1, physicalMemory: eightGB)

        #expect(settings.sttModel == MethodResolver.sttModel)
        #expect(settings.sequentialLoading == true)
        // Non-RAM-dependent settings are fixed for v1.
        #expect(settings.sttModelRepo == MethodResolver.defaultRepo)
        #expect(settings.enableWordTimestamps == true)
        #expect(settings.detectLanguage == false)
        #expect(settings.diarizationStrategy == .subsegment)
    }

    @Test("v2 matches v1 but enables language detection")
    func v2EnablesLanguageDetection() {
        let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
        let v1Settings = MethodResolver.resolve(.v1, physicalMemory: sixteenGB)
        let v2Settings = MethodResolver.resolve(.v2, physicalMemory: sixteenGB)

        #expect(v2Settings.sttModel == v1Settings.sttModel)
        #expect(v2Settings.sttModelRepo == v1Settings.sttModelRepo)
        #expect(v2Settings.enableWordTimestamps == v1Settings.enableWordTimestamps)
        #expect(v2Settings.diarizationStrategy == v1Settings.diarizationStrategy)
        #expect(v2Settings.sequentialLoading == v1Settings.sequentialLoading)
        #expect(v1Settings.detectLanguage == false)
        #expect(v2Settings.detectLanguage == true)
    }

    @Test("v3 matches v2 but turns off the first-token check")
    func v3TurnsOffFirstTokenCheck() {
        let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
        let v2Settings = MethodResolver.resolve(.v2, physicalMemory: sixteenGB)
        let v3Settings = MethodResolver.resolve(.v3, physicalMemory: sixteenGB)

        #expect(v3Settings.sttModel == v2Settings.sttModel)
        #expect(v3Settings.sttModelRepo == v2Settings.sttModelRepo)
        #expect(v3Settings.enableWordTimestamps == v2Settings.enableWordTimestamps)
        #expect(v3Settings.detectLanguage == v2Settings.detectLanguage)
        #expect(v3Settings.diarizationStrategy == v2Settings.diarizationStrategy)
        #expect(v3Settings.sequentialLoading == v2Settings.sequentialLoading)
        #expect(v2Settings.checksFirstToken == true)
        #expect(v3Settings.checksFirstToken == false)
    }

    // MARK: - Decoding options

    @Test("v1 and v2 keep WhisperKit's default decoding options")
    func v1AndV2KeepWhisperKitDefaults() {
        let defaults = DecodingOptions()
        for method in [TranscriptionMethod.v1, .v2] {
            let options = MethodResolver.resolve(method).decodingOptions
            #expect(options.firstTokenLogProbThreshold == defaults.firstTokenLogProbThreshold)
            #expect(options.firstTokenLogProbThreshold != nil)
            #expect(options.wordTimestamps == true)
        }
        #expect(MethodResolver.resolve(.v1).decodingOptions.detectLanguage == false)
        #expect(MethodResolver.resolve(.v2).decodingOptions.detectLanguage == true)
    }

    /// With the check on, a window whose first token is unlikely is retried at
    /// higher temperatures, and the speech after the retry's first segment is
    /// lost. Meetings lost their first 30 s this way (2026-10-27).
    @Test("v3 decodes without the first-token check and keeps the other fallbacks")
    func v3DecodingOptionsHaveNoFirstTokenCheck() {
        let defaults = DecodingOptions()
        let options = MethodResolver.resolve(.v3).decodingOptions

        #expect(options.firstTokenLogProbThreshold == nil)
        #expect(options.logProbThreshold == defaults.logProbThreshold)
        #expect(options.compressionRatioThreshold == defaults.compressionRatioThreshold)
        #expect(options.temperatureFallbackCount == defaults.temperatureFallbackCount)
        #expect(options.detectLanguage == true)
        #expect(options.wordTimestamps == true)
    }

    @Test("v1 resolves to the single STT model + sequential loading below 8 GB")
    func resolvesWithSequentialLoadingBelow8GB() {
        let fourGB: UInt64 = 4 * 1024 * 1024 * 1024
        let settings = MethodResolver.resolve(.v1, physicalMemory: fourGB)

        #expect(settings.sttModel == MethodResolver.sttModel)
        #expect(settings.sequentialLoading == true)
    }

    @Test("v1 resolves to the single STT model + no sequential loading at 16 GB")
    func resolvesNoSequentialLoadingAt16GB() {
        let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
        let settings = MethodResolver.resolve(.v1, physicalMemory: sixteenGB)

        #expect(settings.sttModel == MethodResolver.sttModel)
        #expect(settings.sequentialLoading == false)
    }

    @Test("v1 resolves to the single STT model + no sequential loading above 8 GB")
    func resolvesNoSequentialLoadingAbove8GB() {
        let twelveGB: UInt64 = 12 * 1024 * 1024 * 1024
        let settings = MethodResolver.resolve(.v1, physicalMemory: twelveGB)

        #expect(settings.sttModel == MethodResolver.sttModel)
        #expect(settings.sequentialLoading == false)
    }

    @Test("unknown method id falls back to v1 behavior")
    func unknownFallsBackToV1() {
        let sixteenGB: UInt64 = 16 * 1024 * 1024 * 1024
        let settings = MethodResolver.resolve(
            TranscriptionMethod(id: "v999"), physicalMemory: sixteenGB
        )

        #expect(settings.sttModel == MethodResolver.sttModel)
        #expect(settings.diarizationStrategy == .subsegment)
    }
}
