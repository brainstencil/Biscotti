#if DEBUG
    import Foundation
    import Testing
    @testable import MeetingChat

    @Suite("FootprintSampler")
    struct FootprintSamplerTests {
        @Test("The sampler reads this process's footprint and resident size, and finds it by its executable")
        func footprintSamplerReadsThisProcess() throws {
            let memory = try #require(FootprintSampler.memory(of: getpid()))
            let executable = try #require(FootprintSampler.runningProcesses().first { $0.pid == getpid() }?.path)
            let sample = FootprintSampler(transcriberExecutable: executable, llmExecutable: "/no/such/BiscottiLLM").sample()

            #expect(memory.footprint > 0)
            #expect(memory.resident > 0)
            #expect(sample.app != nil)
            #expect(sample.transcriber != nil)
            #expect(sample.llm == nil)
        }

        @Test("The workers are found by the app's bundle identifier")
        func workersFoundByBundleIdentifier() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "FootprintSamplerTests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let app = root.appending(path: "Test.app")
            try Self.writeBundle(at: app, identifier: "net.example.test", executable: "Test")
            let services = app.appending(path: "Contents/XPCServices")
            try Self.writeBundle(at: services.appending(path: "BiscottiLLM.xpc"), identifier: "net.example.test.BiscottiLLM", executable: "BiscottiLLM")
            try Self.writeBundle(at: services.appending(path: "Other.xpc"), identifier: "net.other.BiscottiTranscriber", executable: "Other")

            let sampler = try FootprintSampler.forApp(#require(Bundle(url: app)))

            #expect(sampler.llmExecutable?.hasSuffix("BiscottiLLM.xpc/Contents/MacOS/BiscottiLLM") == true)
            #expect(sampler.transcriberExecutable == nil)
        }

        private static func writeBundle(at url: URL, identifier: String, executable: String) throws {
            let macOS = url.appending(path: "Contents/MacOS")
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            let info: [String: String] = [
                "CFBundleIdentifier": identifier,
                "CFBundleExecutable": executable,
                "CFBundlePackageType": url.pathExtension == "xpc" ? "XPC!" : "APPL"
            ]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: url.appending(path: "Contents/Info.plist"))
            FileManager.default.createFile(atPath: macOS.appending(path: executable).path, contents: Data())
        }
    }
#endif
