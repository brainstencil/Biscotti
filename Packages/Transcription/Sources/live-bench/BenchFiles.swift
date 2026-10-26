import CryptoKit
import Foundation
import Synchronization

/// JSON as the Python scorer reads it: snake_case keys, sorted.
enum BenchJSON {
    static func encoder(pretty: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func write(_ value: some Encodable, to url: URL) throws {
        try encoder(pretty: true).encode(value).write(to: url, options: .atomic)
    }
}

/// Appends one JSON object per line. Safe to use from any task.
final class JSONLinesWriter: Sendable {
    private let handle: Mutex<FileHandle>
    private let encoder = BenchJSON.encoder()

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try Mutex(FileHandle(forWritingTo: url))
    }

    func write(_ value: some Encodable) throws {
        let line = try encoder.encode(value) + Data("\n".utf8)
        try handle.withLock { try $0.write(contentsOf: line) }
    }

    func close() throws {
        try handle.withLock { try $0.close() }
    }
}

enum FileHash {
    /// SHA-256 of a file's contents, read in pieces so model weights never sit in memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
