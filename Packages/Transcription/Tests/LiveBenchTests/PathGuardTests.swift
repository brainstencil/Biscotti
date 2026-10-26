import Foundation
import Testing
@testable import live_bench

@Suite("Path guard")
struct PathGuardTests {
    @Test("production data and the installed app are refused however the path is written")
    func pathGuardRejectsProductionPaths() throws {
        let temporary = try TemporaryFolder()
        defer { temporary.remove() }
        let home = try temporary.folder("home")
        let production = try temporary.folder("home/Library/Application Support/Biscotti/models")
        let work = try temporary.folder("work")
        let data = try temporary.folder("data")
        try FileManager.default.createSymbolicLink(at: data.appending(path: "link"), withDestinationURL: production)
        try FileManager.default.createSymbolicLink(
            at: data.appending(path: "dangling"),
            withDestinationURL: home.appending(path: "Library/Application Support/Biscotti/not-yet")
        )
        let pathGuard = PathGuard(home: home, workingDirectory: work)

        let refused = [
            "~/Library/Application Support/Biscotti",
            "~/Library/Application Support/Biscotti/models/new/run",
            home.path + "/Library/Application Support/Biscotti",
            work.path + "/../home/Library/Application Support/Biscotti/models",
            "../home/Library/Application Support/Biscotti/out",
            data.path + "/link/out",
            data.path + "/dangling",
            home.path + "/library/application support/BISCOTTI/out",
            "/Applications/Biscotti.app",
            "/Applications/Biscotti.app/Contents/Resources",
            PathGuard.dataVolume + "/Applications/Biscotti.app/Contents",
            PathGuard.dataVolume + PathGuard.canonical(production).path + "/run"
        ]
        for path in refused {
            #expect(throws: BenchError.self, "\(path) should be refused") { try pathGuard.resolve(path, flag: "--out") }
        }

        let allowed = [
            "~/Library/Application Support/BiscottiBench/out",
            data.path + "/out",
            "results",
            "/Applications/Biscotti Copy.app"
        ]
        for path in allowed {
            #expect(throws: Never.self, "\(path) should be allowed") { try pathGuard.resolve(path, flag: "--out") }
        }
    }

    @Test("the refusal names the flag and the resolved production path")
    func refusalNamesTheFlagAndPath() throws {
        let temporary = try TemporaryFolder()
        defer { temporary.remove() }
        let home = try temporary.folder("home")
        let pathGuard = PathGuard(home: home, workingDirectory: temporary.url)

        let error = #expect(throws: BenchError.self) {
            try pathGuard.resolve("~/Library/Application Support/Biscotti/models", flag: "--models")
        }

        #expect(error?.description.contains("--models") == true)
        #expect(error?.description.contains("Library/Application Support/Biscotti/models") == true)
    }

    @Test("relative paths resolve against the working directory")
    func relativePathsResolveAgainstTheWorkingDirectory() throws {
        let temporary = try TemporaryFolder()
        defer { temporary.remove() }
        let work = try temporary.folder("work")
        let pathGuard = PathGuard(home: temporary.url, workingDirectory: work)

        let resolved = try pathGuard.resolve("out/./runs/../final", flag: "--out")

        #expect(resolved == PathGuard.canonical(work).appending(path: "out/final"))
    }

    @Test("clip IDs and model names must be single folder names")
    func clipNamesMustBeSingleComponents() throws {
        #expect(try parseClipIDs("smoke, cal-1") == ["smoke", "cal-1"])
        for value in ["", "..", ".", "../outside", "a/b", "smoke,../x"] {
            #expect(throws: BenchError.self, "\(value) should be refused") { try parseClipIDs(value) }
        }
        #expect(throws: BenchError.self) { try PathGuard.checkName("argmaxinc/model", flag: "--model") }
        #expect(throws: BenchError.duplicateClip("smoke")) { try parseClipIDs("smoke,cal-1,smoke") }
    }
}
