import ArgumentParser
import Foundation

/// The live transcript replay harness. It runs the app's live session code
/// on fixture audio and writes logs that `Tools/live_bench` scores.
@main
struct LiveBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "live-bench",
        abstract: "Replay fixture audio through the live transcription session and log what it produces.",
        discussion: """
        Models load only from --models; nothing is downloaded. Every command first
        refuses folders inside ~/Library/Application Support/Biscotti or the
        installed /Applications/Biscotti.app. Score results with Tools/live_bench.
        """,
        subcommands: [RunCommand.self, CostCommand.self, FinalPassCommand.self, CheckPathsCommand.self, SpeechAssetsCommand.self]
    )
}

/// The three folders every command takes, checked by `PathGuard` first.
struct BenchPaths: ParsableArguments {
    @Option(help: "The model cache folder (holds argmaxinc/whisperkit-coreml/<model>).")
    var models: String

    @Option(help: "The fixtures folder made by make_fixtures.py.")
    var fixtures: String

    @Option(help: "The folder that receives a new results folder per command.")
    var out: String

    struct Resolved {
        let models: URL
        let fixtures: URL
        let out: URL
    }

    func resolve(with pathGuard: PathGuard = PathGuard()) throws -> Resolved {
        try Resolved(
            models: pathGuard.resolve(models, flag: "--models"),
            fixtures: pathGuard.resolve(fixtures, flag: "--fixtures"),
            out: pathGuard.resolve(out, flag: "--out")
        )
    }
}

/// Prints the resolved folders, or the reason one is refused.
struct CheckPathsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "check-paths", abstract: "Resolve and check --models, --fixtures and --out.")

    @OptionGroup var paths: BenchPaths

    func run() throws {
        let resolved = try paths.resolve()
        print("models:   \(resolved.models.path)")
        print("fixtures: \(resolved.fixtures.path)")
        print("out:      \(resolved.out.path)")
    }
}

/// Splits `--clips a,b` and checks each ID is a plain folder name.
func parseClipIDs(_ value: String) throws -> [String] {
    let ids = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    guard !ids.isEmpty else { throw BenchError.invalidName(flag: "--clips", value: value) }
    try ids.forEach { try PathGuard.checkName($0, flag: "--clips") }
    var seen = Set<String>()
    for id in ids where !seen.insert(id).inserted {
        throw BenchError.duplicateClip(id)
    }
    return ids
}

/// Creates `<out>/<name>`, refusing to reuse one: results are never overwritten.
func makeResultsFolder(in out: URL, named name: String) throws -> URL {
    let folder = out.appending(path: name, directoryHint: .isDirectory)
    guard !FileManager.default.fileExists(atPath: folder.path) else { throw BenchError.outputExists(folder.path) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A sortable, filesystem-safe time for results folder names.
func folderTimestamp(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: date)
}

/// Prints progress to standard error, keeping standard output for results.
func progress(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
