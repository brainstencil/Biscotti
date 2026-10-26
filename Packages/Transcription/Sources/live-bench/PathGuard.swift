import Foundation

/// Keeps the harness away from production Biscotti: its data folder and the
/// installed app. Every command resolves its folders here before it reads or
/// writes anything.
struct PathGuard {
    private let home: URL
    private let workingDirectory: URL
    /// Each protected place, as written and as resolved through symlinks.
    private let protectedRoots: [URL]

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        workingDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    ) {
        self.home = home
        self.workingDirectory = workingDirectory
        let roots = [
            home.appending(path: "Library/Application Support/Biscotti", directoryHint: .isDirectory),
            URL(filePath: "/Applications/Biscotti.app", directoryHint: .isDirectory)
        ]
        // `realpath` leaves firmlinks alone, so the same folders reached
        // through the system Data volume are listed as well.
        protectedRoots = roots
            .flatMap { [$0.standardizedFileURL, Self.canonical($0)] }
            .flatMap { [$0, URL(filePath: Self.dataVolume + $0.path)] }
    }

    /// Where `/Users` and `/Applications` live; their firmlinked paths start here.
    static let dataVolume = "/System/Volumes/Data"

    /// The absolute, symlink-resolved form of `path`.
    /// - Throws: `BenchError.productionPath` when it is a protected place or lies inside one.
    func resolve(_ path: String, flag: String) throws -> URL {
        let resolved = Self.canonical(absolute(path))
        if protectedRoots.contains(where: { Self.isSameOrInside(resolved, $0) }) {
            throw BenchError.productionPath(flag: flag, path: resolved.path)
        }
        return resolved
    }

    /// A clip ID or model name: one path component, so joining it to a
    /// checked folder cannot leave that folder.
    static func checkName(_ value: String, flag: String) throws {
        let isSingleComponent = !value.isEmpty && value != "." && value != ".." && !value.contains("/")
        guard isSingleComponent else { throw BenchError.invalidName(flag: flag, value: value) }
    }

    private func absolute(_ path: String) -> URL {
        if path == "~" {
            return home
        }
        if path.hasPrefix("~/") {
            return home.appending(path: String(path.dropFirst(2)))
        }
        return URL(filePath: path, relativeTo: workingDirectory).absoluteURL
    }

    /// Resolves symlinks and `..` the way the file system will: `realpath` on
    /// the deepest part that exists, then the rest as written, where a `..`
    /// can only undo a folder that does not exist yet.
    static func canonical(_ url: URL) -> URL {
        canonical(path: url.path, linksFollowed: 0)
    }

    private static func canonical(path: String, linksFollowed: Int) -> URL {
        let components = path.split(separator: "/").map(String.init)
        let existingCount = (0 ... components.count).last { count in
            entryExists("/" + components.prefix(count).joined(separator: "/"))
        } ?? 0
        let existing = "/" + components.prefix(existingCount).joined(separator: "/")
        let remainder = components.dropFirst(existingCount)
        if realPath(existing) == nil, linksFollowed < 16,
           let target = try? FileManager.default.destinationOfSymbolicLink(atPath: existing)
        {
            // A symlink to something that does not exist yet: follow it by
            // hand, so writing through it cannot land somewhere protected.
            let base = target.hasPrefix("/") ? target : (existing as NSString).deletingLastPathComponent + "/" + target
            return canonical(path: ([base] + remainder).joined(separator: "/"), linksFollowed: linksFollowed + 1)
        }
        var result = (realPath(existing) ?? existing).split(separator: "/").map(String.init)
        for component in remainder {
            switch component {
            case ".": continue
            case "..": _ = result.popLast()
            default: result.append(component)
            }
        }
        return URL(filePath: "/" + result.joined(separator: "/"))
    }

    /// True for any directory entry, including a symlink whose target is missing.
    private static func entryExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whole-component comparison, ignoring case as the default macOS volume does.
    private static func isSameOrInside(_ url: URL, _ root: URL) -> Bool {
        let path = url.pathComponents.map { $0.lowercased() }
        let rootPath = root.pathComponents.map { $0.lowercased() }
        return path.starts(with: rootPath)
    }
}
