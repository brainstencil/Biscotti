import Foundation
import Testing
@testable import live_bench

@Suite("Manifest and model location")
struct ManifestTests {
    static let probe = SystemProbe(
        machine: { MachineRecord(model: "Mac16,5", chip: "Apple M4 Max", memoryBytes: 64 << 30, operatingSystem: "Version 26.1") },
        power: { PowerRecord(lowPowerMode: false, thermalState: "nominal") },
        repo: { RepoRecord(commit: "abc123", dirty: false, argmaxOssSwift: PinRecord(version: "1.1.0", revision: "1e2a163")) }
    )

    @Test("the manifest records every field the experiment needs, with real file hashes")
    func manifestRecordsAllRequiredFields() throws {
        let temporary = try TemporaryFolder()
        defer { temporary.remove() }
        try makeModel("test-model", in: temporary)
        let location = try WhisperModelLocation.locate(name: "test-model", in: temporary.url.appending(path: "models"))
        let mic = try temporary.file("fixtures/smoke/mic.wav", contents: "mic")
        try temporary.file("fixtures/smoke/system.wav", contents: "system")
        try temporary.file("fixtures/smoke/reference.json", contents: "{}")
        try temporary.file("fixtures/smoke/meta.json", contents: "{}")
        let lock = try temporary.file("fixtures/fixtures.lock.json", contents: "{\"clips\": {}}")
        let options = OptionsRecord(option: .whisperCurrent, model: "test-model", interval: 2, mode: .twoTrack, clips: ["smoke"], load: "none", clock: "real", vocabulary: false)

        var manifest = try BenchManifest.make(kind: "run", options: options, model: location, fixtures: temporary.url.appending(path: "fixtures"), probe: Self.probe)
        manifest.memoryBaseline = MemoryBaseline(seconds: 30, samples: 30, medianUsedBytes: 8 << 30)
        manifest.sessions = [SessionRecord(clip: "smoke", warm: false, startedAt: "2026-10-23T12:00:00Z", finishSeconds: 1.5)]
        let json = try JSONSerialization.jsonObject(with: BenchJSON.encoder().encode(manifest)) as? [String: Any] ?? [:]

        let repo = json["repo"] as? [String: Any]
        #expect(repo?["commit"] as? String == "abc123")
        #expect((repo?["argmax_oss_swift"] as? [String: Any])?["revision"] as? String == "1e2a163")
        let model = json["model"] as? [String: Any]
        #expect(model?["name"] as? String == "test-model")
        #expect((model?["sha256"] as? String)?.count == 64)
        let files = model?["files"] as? [[String: Any]] ?? []
        #expect(files.map { $0["path"] as? String } == ["AudioEncoder.mlmodelc/coremldata.bin", "MelSpectrogram.mlmodelc/coremldata.bin", "TextDecoder.mlmodelc/coremldata.bin", "tokenizer.json"])
        let machine = json["machine"] as? [String: Any]
        for key in ["model", "chip", "memory_bytes", "operating_system"] {
            #expect(machine?[key] != nil, "machine.\(key)")
        }
        let optionsJSON = json["options"] as? [String: Any]
        for key in ["option", "model", "interval", "mode", "clips", "load", "clock", "vocabulary"] {
            #expect(optionsJSON?[key] != nil, "options.\(key)")
        }
        let fixtures = json["fixtures"] as? [String: Any]
        let lockHash = try FileHash.sha256(of: lock)
        let micHash = try FileHash.sha256(of: mic)
        #expect(fixtures?["lock_sha256"] as? String == lockHash)
        let clip = (fixtures?["clips"] as? [String: Any])?["smoke"] as? [String: String]
        #expect(clip?["mic.wav"] == micHash)
        #expect(clip?.keys.sorted() == ["meta.json", "mic.wav", "reference.json", "system.wav"])
        #expect((json["sessions"] as? [[String: Any]])?.first?["warm"] as? Bool == false)
        let power = json["power"] as? [String: Any]
        #expect(power?["low_power_mode"] as? Bool == false)
        #expect(power?["thermal_state"] as? String == "nominal")
        #expect((json["memory_baseline"] as? [String: Any])?["median_used_bytes"] != nil)
        #expect(json["arguments"] != nil && json["created_at"] != nil && json["kind"] as? String == "run")
    }

    @Test("the argmax pin is read from Package.resolved")
    func argmaxPinIsReadFromPackageResolved() {
        let resolved = """
        {"pins": [
          {"identity": "swift-argument-parser", "state": {"revision": "aaa", "version": "1.8.2"}},
          {"identity": "argmax-oss-swift", "state": {"revision": "1e2a163", "version": "1.1.0"}}
        ], "version": 3}
        """

        #expect(RepoProbe.argmaxPin(inResolved: Data(resolved.utf8)) == PinRecord(version: "1.1.0", revision: "1e2a163"))
        #expect(RepoProbe.argmaxPin(inResolved: Data("{}".utf8)) == nil)
    }

    @Test("the source fingerprint changes with uncommitted and untracked code, and only then")
    func sourceFingerprintFollowsUncommittedCode() throws {
        let temporary = try TemporaryFolder()
        defer { temporary.remove() }
        let root = temporary.url
        // The developer's own git settings (commit signing, hooks) must not
        // decide whether the scratch repository gets its first commit.
        let isolation = ["-c", "user.name=test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"]
        let git = { (arguments: [String]) in
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + isolation + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " "))")
        }
        try git(["init", "-q"])
        try temporary.file("Session.swift", contents: "let a = 1\n")
        try git(["add", "."])
        try git(["commit", "-q", "-m", "start"])
        let clean = try #require(RepoProbe.sourceFingerprint(root: root))

        try temporary.file("Session.swift", contents: "let a = 2\n")
        let edited = try #require(RepoProbe.sourceFingerprint(root: root))
        try temporary.file("New.swift", contents: "let b = 1\n")
        let added = try #require(RepoProbe.sourceFingerprint(root: root))
        try temporary.file("New.swift", contents: "let b = 2\n")
        let addedEdited = try #require(RepoProbe.sourceFingerprint(root: root))

        #expect(Set([clean, edited, added, addedEdited]).count == 4)
        #expect(RepoProbe.sourceFingerprint(root: root) == addedEdited, "the same code gives the same fingerprint")
    }

    @Test("a missing model folder, model file or tokenizer is named in the error")
    func missingModelFailsWithClearMessage() throws {
        let temporary = try TemporaryFolder()
        defer { temporary.remove() }
        let models = temporary.url.appending(path: "models")

        let noFolder = #expect(throws: BenchError.self) { try WhisperModelLocation.locate(name: "openai_whisper-small", in: models) }
        #expect(noFolder?.description.contains("models/argmaxinc/whisperkit-coreml/openai_whisper-small") == true)
        #expect(noFolder?.description.contains("never downloads") == true)

        let folder = try makeModel("openai_whisper-small", in: temporary, tokenizer: false)
        try FileManager.default.removeItem(at: folder.appending(path: "TextDecoder.mlmodelc"))
        let noDecoder = #expect(throws: BenchError.self) { try WhisperModelLocation.locate(name: "openai_whisper-small", in: models) }
        #expect(noDecoder == .missingModelFile(file: "TextDecoder", folder: folder.path))
        #expect(noDecoder?.description.contains("TextDecoder") == true)

        try temporary.file("models/argmaxinc/whisperkit-coreml/openai_whisper-small/TextDecoder.mlpackage/Manifest.json")
        let noTokenizer = #expect(throws: BenchError.self) { try WhisperModelLocation.locate(name: "openai_whisper-small", in: models) }
        #expect(noTokenizer?.description.contains("openai/whisper-small") == true)
        #expect(noTokenizer?.description.contains("tokenizer.json") == true)

        try temporary.file("models/openai/whisper-small/tokenizer.json", contents: "{}")
        let location = try WhisperModelLocation.locate(name: "openai_whisper-small", in: models)
        #expect(location.tokenizerFolder == models.appending(path: "openai/whisper-small", directoryHint: .isDirectory))
    }

    @Test("the tokenizer follows the model size, as WhisperKit picks it")
    func tokenizerFollowsTheModelSize() {
        #expect(WhisperModelLocation.tokenizerRepository(forModel: "openai_whisper-large-v3-v20240930_626MB") == "openai/whisper-large-v3")
        #expect(WhisperModelLocation.tokenizerRepository(forModel: "openai_whisper-large-v3_turbo") == "openai/whisper-large-v3")
        #expect(WhisperModelLocation.tokenizerRepository(forModel: "distil-whisper_distil-large-v3") == "openai/whisper-large-v3")
        #expect(WhisperModelLocation.tokenizerRepository(forModel: "openai_whisper-small") == "openai/whisper-small")
        #expect(WhisperModelLocation.tokenizerRepository(forModel: "openai_whisper-small.en_217MB") == "openai/whisper-small.en")
        #expect(WhisperModelLocation.tokenizerRepository(forModel: "openai_whisper-base.en") == "openai/whisper-base.en")
        #expect(WhisperModelLocation.tokenizerRepository(forModel: "mystery-model") == nil)
    }
}
