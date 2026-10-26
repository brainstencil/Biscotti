import ArgumentParser
import Foundation
import LiveTranscription

/// `live-bench speech-assets`: whether SpeechAnalyzer's model for a locale is
/// installed for live-bench, and the request that installs it.
struct SpeechAssetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speech-assets",
        abstract: "Check, or request, SpeechAnalyzer's model for a locale.",
        discussion: """
        The system downloads, stores and updates SpeechAnalyzer's models, and keeps
        one for each program that asks for it: until this live-bench build asks, a
        model already on this Mac reads as not installed. --install makes that
        request. The folders are checked like every command's, so make bench-live
        can run it; nothing is written to them.
        """
    )

    @OptionGroup var paths: BenchPaths

    @Option(help: "The locale identifier.")
    var locale = ReplayEngine.speechAnalyzerLocale

    @Flag(help: "Ask the system to install the model for live-bench.")
    var install = false

    func run() async throws {
        _ = try paths.resolve()
        guard #available(macOS 26, *) else {
            throw BenchError.speechAnalyzerNeedsMacOS26(found: ProcessInfo.processInfo.operatingSystemVersionString)
        }
        let status = await SpeechAnalyzerAssets.status(locale: locale)
        print("\(locale): \(Self.describe(status))")
        guard install, status != .installed else { return }
        guard status != .unsupported else { throw BenchError.speechLocaleUnsupported(locale) }

        try await SpeechAnalyzerAssets.install(locale: locale) { fraction in
            progress("Installing \(Int((fraction * 100).rounded())) %")
        }
        await print("\(locale): \(Self.describe(SpeechAnalyzerAssets.status(locale: locale)))")
    }

    @available(macOS 26, *)
    static func describe(_ status: SpeechAnalyzerAssets.Status) -> String {
        switch status {
        case .installed: "installed for live-bench"
        case .downloading: "downloading"
        case .notInstalled: "not installed for live-bench (run with --install)"
        case .unsupported: "not supported by SpeechAnalyzer on this Mac"
        }
    }
}
