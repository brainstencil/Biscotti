import Foundation

/// `manifest.json`: everything needed to reproduce or question a result.
struct BenchManifest: Codable {
    /// `run`, `cost` or `final-pass`.
    var kind: String
    var createdAt: String
    var arguments: [String]
    var repo: RepoRecord
    var model: ModelRecord?
    var machine: MachineRecord
    /// At the start of the command.
    var power: PowerRecord
    var options: OptionsRecord
    var fixtures: FixtureRecord
    var memoryBaseline: MemoryBaseline?
    var sessions: [SessionRecord] = []

    func write(to folder: URL) throws {
        try BenchJSON.write(self, to: folder.appending(path: "manifest.json"))
    }
}

struct RepoRecord: Codable, Equatable {
    var commit: String?
    /// True when tracked files had uncommitted changes.
    var dirty: Bool?
    /// SHA-256 over `git diff HEAD` and every untracked, unignored file, so
    /// runs made from different uncommitted code can be told apart.
    var sourceFingerprint: String?
    var argmaxOssSwift: PinRecord?
}

struct PinRecord: Codable, Equatable {
    var version: String?
    var revision: String
}

struct ModelRecord: Codable, Equatable {
    var name: String
    var folder: String
    /// SHA-256 of the sorted "path<TAB>hash" lines of `files`; nil until hashed.
    var sha256: String?
    var files: [FileRecord] = []
    var loadSeconds: Double?
}

struct FileRecord: Codable, Equatable {
    /// Relative to the folder that was hashed.
    var path: String
    var bytes: Int
    var sha256: String
}

struct MachineRecord: Codable, Equatable {
    var model: String
    var chip: String
    var memoryBytes: UInt64
    var operatingSystem: String
}

struct PowerRecord: Codable, Equatable {
    var lowPowerMode: Bool
    var thermalState: String
}

/// The command's options. Fields a command does not use are left out.
struct OptionsRecord: Codable, Equatable {
    var option: BenchEngine?
    var model: String?
    var interval: Double?
    var mode: BenchMode?
    var clips: [String]
    var load: String?
    /// `real` or `simulated`.
    var clock: String?
    var vocabulary: Bool?
    /// The app's final-pass model; a final-pass run with another model is a
    /// diagnostic, not the accuracy baseline.
    var finalPassModel: String?
    /// SpeechAnalyzer only: whether `.fastResults` was on.
    var fastResults: Bool?
    /// SpeechAnalyzer only: the locale it transcribed.
    var locale: String?
    /// What ran alongside the replay in another process (`--alongside`);
    /// such a run is a diagnostic, not gated.
    var alongside: String?
    /// Whisper only: what each decode was prompted with.
    var whisperPrompt: BenchPrompt?
    /// Dry runs only: the seconds of each clip used, and the baseline length.
    var clipSeconds: Double?
    var baselineSeconds: Int?
    /// `cost` only: timed decodes per window length.
    var decodes: Int?
}

struct FixtureRecord: Codable, Equatable {
    /// SHA-256 of `fixtures.lock.json`; nil when there is no lock yet.
    var lockSha256: String?
    /// Clip ID → file name → SHA-256, for the files the clip has.
    var clips: [String: [String: String]]
}

struct SessionRecord: Codable, Equatable {
    var clip: String
    /// False for the first session after the model loaded.
    var warm: Bool
    var startedAt: String
    var finishSeconds: Double?
}

/// What the manifest reads from the machine and the repository. Tests use fixed values.
struct SystemProbe {
    var machine: @Sendable () -> MachineRecord
    var power: @Sendable () -> PowerRecord
    var repo: @Sendable () -> RepoRecord

    static let live = SystemProbe(
        machine: {
            MachineRecord(
                model: sysctlString("hw.model") ?? "unknown",
                chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
                memoryBytes: ProcessInfo.processInfo.physicalMemory,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
            )
        },
        power: {
            PowerRecord(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, thermalState: ProcessInfo.processInfo.thermalState.label)
        },
        repo: { RepoProbe.current() }
    )
}

extension BenchManifest {
    static func make(
        kind: String,
        options: OptionsRecord,
        model: WhisperModelLocation?,
        hashingModel: Bool = true,
        fixtures: URL,
        probe: SystemProbe = .live
    ) throws -> BenchManifest {
        try BenchManifest(
            kind: kind,
            createdAt: timestamp(),
            arguments: CommandLine.arguments,
            repo: probe.repo(),
            model: model.map { hashingModel ? try ModelRecord.hashing($0) : ModelRecord(location: $0) },
            machine: probe.machine(),
            power: probe.power(),
            options: options,
            fixtures: FixtureRecord.hashing(clips: options.clips, in: fixtures)
        )
    }

    static func timestamp(_ date: Date = Date()) -> String {
        date.formatted(.iso8601)
    }
}

extension ModelRecord {
    init(location: WhisperModelLocation) {
        self.init(name: location.name, folder: location.folder.lastPathComponent)
    }

    static func hashing(_ location: WhisperModelLocation) throws -> ModelRecord {
        let files = try FileRecord.hashingFiles(in: location.folder)
        let summary = files.map { "\($0.path)\t\($0.sha256)\n" }.joined()
        return ModelRecord(name: location.name, folder: location.folder.lastPathComponent, sha256: FileHash.sha256(of: summary), files: files)
    }
}

extension FixtureRecord {
    static func hashing(clips: [String], in fixtures: URL) throws -> FixtureRecord {
        let lock = fixtures.appending(path: "fixtures.lock.json")
        var hashes: [String: [String: String]] = [:]
        for clip in clips {
            let folder = try ClipAudio.folder(of: clip, in: fixtures)
            for file in ClipAudio.recordedFiles where FileManager.default.fileExists(atPath: folder.appending(path: file).path) {
                hashes[clip, default: [:]][file] = try FileHash.sha256(of: folder.appending(path: file))
            }
        }
        let lockHash = FileManager.default.fileExists(atPath: lock.path) ? try FileHash.sha256(of: lock) : nil
        return FixtureRecord(lockSha256: lockHash, clips: hashes)
    }
}

extension FileRecord {
    /// Every regular file under `folder`, sorted by relative path.
    static func hashingFiles(in folder: URL) throws -> [FileRecord] {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var records: [FileRecord] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let path = String(url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1))
            try records.append(FileRecord(path: path, bytes: values.fileSize ?? 0, sha256: FileHash.sha256(of: url)))
        }
        return records.sorted { $0.path < $1.path }
    }
}

/// The repository commit and the pinned argmax-oss-swift, read with `git`.
enum RepoProbe {
    static func current() -> RepoRecord {
        guard let root = git(["rev-parse", "--show-toplevel"]) else { return RepoRecord() }
        let status = git(["status", "--porcelain", "--untracked-files=no"])
        let resolved = URL(filePath: root).appending(path: "Packages/Transcription/Package.resolved")
        return RepoRecord(
            commit: git(["rev-parse", "HEAD"]),
            dirty: status.map { !$0.isEmpty },
            sourceFingerprint: sourceFingerprint(root: URL(filePath: root)),
            argmaxOssSwift: (try? Data(contentsOf: resolved)).flatMap { argmaxPin(inResolved: $0) }
        )
    }

    /// The diff against HEAD, then each untracked file's path and hash, hashed together.
    static func sourceFingerprint(root: URL) -> String? {
        guard let diff = gitData(["-C", root.path, "diff", "HEAD", "--binary"]),
              let untracked = git(["-C", root.path, "ls-files", "--others", "--exclude-standard"])
        else { return nil }
        let files = untracked.split(separator: "\n").map(String.init).sorted().map { path in
            "\(path)\t\((try? FileHash.sha256(of: root.appending(path: path))) ?? "unreadable")\n"
        }
        return fingerprint(diff: diff, untrackedFiles: files.joined())
    }

    static func fingerprint(diff: Data, untrackedFiles: String) -> String {
        FileHash.sha256(of: FileHash.sha256(of: diff) + "\n" + untrackedFiles)
    }

    static func argmaxPin(inResolved data: Data) -> PinRecord? {
        let pins = try? JSONDecoder().decode(ResolvedPackages.self, from: data).pins
        return pins?.first { $0.identity == "argmax-oss-swift" }?.state
    }

    private static func git(_ arguments: [String]) -> String? {
        gitData(arguments).flatMap { String(bytes: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func gitData(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/git")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}

/// The parts of `Package.resolved` the manifest reads.
private struct ResolvedPackages: Decodable {
    struct Pin: Decodable {
        var identity: String
        var state: PinRecord
    }

    var pins: [Pin]
}
