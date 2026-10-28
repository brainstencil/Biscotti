#if DEBUG
    import Darwin
    import Foundation

    /// One process's memory, in bytes.
    struct ProcessMemory: Equatable {
        /// `ri_phys_footprint`, what Activity Monitor shows as Memory. It
        /// leaves out clean file-backed pages, such as model weights that
        /// llama.cpp maps from the GGUF file (`use_mmap`) and Metal uses in place.
        var footprint: UInt64
        /// `ri_resident_size`: every page in RAM, file-backed ones included.
        var resident: UInt64

        static func + (lhs: ProcessMemory, rhs: ProcessMemory) -> ProcessMemory {
            ProcessMemory(footprint: lhs.footprint + rhs.footprint, resident: lhs.resident + rhs.resident)
        }
    }

    /// The memory of the app and its two workers; nil for a process that is
    /// not running.
    struct ProcessFootprints: Equatable {
        var app: ProcessMemory?
        var transcriber: ProcessMemory?
        var llm: ProcessMemory?
    }

    /// Reads the physical footprint and resident size of the app and its two
    /// XPC workers. Debug builds only.
    struct FootprintSampler {
        /// The workers' executables, from their bundles.
        let transcriberExecutable: String?
        let llmExecutable: String?

        /// The workers inside `app`: the XPC services whose bundle identifiers
        /// are the app's plus `.BiscottiTranscriber` and `.BiscottiLLM`
        /// (`net.scosman.biscotti.dev.BiscottiLLM` in Biscotti Dev).
        static func forApp(_ app: Bundle = .main) -> FootprintSampler {
            let appIdentifier = app.bundleIdentifier ?? ""
            let services = app.bundleURL.appending(path: "Contents/XPCServices")
            let bundles = ((try? FileManager.default.contentsOfDirectory(at: services, includingPropertiesForKeys: nil)) ?? [])
                .compactMap(Bundle.init(url:))
            func executable(_ name: String) -> String? {
                bundles.first { $0.bundleIdentifier == "\(appIdentifier).\(name)" }?
                    .executableURL?.resolvingSymlinksInPath().path
            }
            return FootprintSampler(transcriberExecutable: executable("BiscottiTranscriber"), llmExecutable: executable("BiscottiLLM"))
        }

        /// The memory now. A worker that runs as several processes counts
        /// their sum.
        func sample() -> ProcessFootprints {
            let processes = Self.runningProcesses()
            func memory(of executable: String?) -> ProcessMemory? {
                guard let executable else { return nil }
                return processes.filter { $0.path == executable }.compactMap { Self.memory(of: $0.pid) }.reduce(nil) { total, next in
                    total.map { $0 + next } ?? next
                }
            }
            return ProcessFootprints(
                app: Self.memory(of: getpid()),
                transcriber: memory(of: transcriberExecutable),
                llm: memory(of: llmExecutable)
            )
        }

        /// A process's memory, nil when it cannot be read.
        static func memory(of pid: pid_t) -> ProcessMemory? {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            return result == 0 ? ProcessMemory(footprint: usage.ri_phys_footprint, resident: usage.ri_resident_size) : nil
        }

        /// Every process this user can see, with its executable's path.
        static func runningProcesses() -> [(pid: pid_t, path: String)] {
            // Room for processes that start between the two calls.
            let capacity = Int(proc_listallpids(nil, 0)) + 64
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes { buffer in
                Int(proc_listallpids(buffer.baseAddress, Int32(buffer.count)))
            }
            var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
            return pids.prefix(max(count, 0)).compactMap { pid in
                guard pid > 0 else { return nil }
                let length = Int(proc_pidpath(pid, &path, UInt32(path.count)))
                guard length > 0, let executable = String(bytes: path.prefix(length), encoding: .utf8) else { return nil }
                return (pid, executable)
            }
        }
    }
#endif
