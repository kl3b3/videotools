import Foundation

// ============================================================================
// Tool-Suche (ffmpeg/ffprobe): erst App-Bundle, dann Homebrew/System, dann PATH
// ============================================================================

@MainActor
enum Tools {
    /// Kandidaten, die auf diesem System nachweislich starten (per `-version`).
    private static var workingCache: [String: URL] = [:]
    private static var encoderCache: Set<String>?

    /// Schnelle, synchrone Suche (für UI-Statusanzeige). Nach dem ersten
    /// erfolgreichen `locateWorking` liefert sie dessen Ergebnis.
    static func locate(_ name: String) -> URL? {
        if let working = workingCache[name] { return working }
        return candidates(name).first
    }

    /// Alle denkbaren Orte für ein Tool, in Präferenz-Reihenfolge:
    /// 1. App-Bundle (natives Homebrew-Bundling – schnellster Pfad)
    /// 2. Homebrew-/System-Installation des Nutzers (nativ)
    /// 3. Statisches Kompatibilitäts-Binary im Bundle (x86_64, ab macOS 10.13;
    ///    auf Apple Silicon via Rosetta) – Rückfallebene für ältere Systeme,
    ///    deren libc++ die gebündelten Homebrew-Dylibs nicht laden kann.
    static func candidates(_ name: String) -> [URL] {
        var list: [URL] = []
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            list.append(bundled)
        }
        for p in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        where FileManager.default.isExecutableFile(atPath: p) {
            list.append(URL(fileURLWithPath: p))
        }
        if let fromPath = which(name) { list.append(fromPath) }
        if let compat = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "compat"),
           FileManager.default.isExecutableFile(atPath: compat.path) {
            list.append(compat)
        }
        // Duplikate (z.B. which == Homebrew) entfernen, Reihenfolge erhalten
        var seen = Set<String>()
        return list.filter { seen.insert($0.path).inserted }
    }

    static func isCompat(_ url: URL) -> Bool {
        url.path.contains("/compat/")
    }

    /// Erster Kandidat, der auf diesem System tatsächlich startet.
    /// Fehlermeldungen gescheiterter Kandidaten (z.B. dyld) gehen an `onStderr`.
    static func locateWorking(
        _ name: String,
        onStderr: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> URL? {
        if let cached = workingCache[name] { return cached }
        for candidate in candidates(name) {
            let (_, code) = await ProcessRunner.capture(candidate, args: ["-version"],
                                                        onStderr: onStderr)
            if code == 0 {
                workingCache[name] = candidate
                return candidate
            }
            onStderr("Kandidat startet nicht (exit \(code)): \(candidate.path)\n")
        }
        return nil
    }

    private static func which(_ name: String) -> URL? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run(); proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) {
                return URL(fileURLWithPath: out)
            }
        } catch {}
        return nil
    }

    /// Prüft (einmalig, gecacht), ob der tatsächlich genutzte ffmpeg-Build
    /// einen Encoder mitbringt.
    static func hasEncoder(_ name: String) async -> Bool {
        if let cached = encoderCache { return cached.contains(name) }
        guard let ffmpeg = await locateWorking("ffmpeg") else { return false }
        let (data, _) = await ProcessRunner.capture(ffmpeg, args: ["-hide_banner", "-encoders"])
        var names = Set<String>()
        if let data, let text = String(data: data, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2 { names.insert(String(parts[1])) }
            }
        }
        encoderCache = names
        return names.contains(name)
    }
}

// ============================================================================
// ffprobe-JSON
// ============================================================================

struct FFProbeOutput: Decodable {
    struct Format: Decodable {
        let format_long_name: String?
        let duration: String?
        let bit_rate: String?
        let size: String?
    }
    struct Stream: Decodable {
        let codec_type: String?
        let codec_name: String?
        let width: Int?
        let height: Int?
        let avg_frame_rate: String?
        let bit_rate: String?
        let display_aspect_ratio: String?
        let field_order: String?
        let sample_rate: String?
        let channels: Int?
    }
    let format: Format
    let streams: [Stream]
}

// ============================================================================
// Prozess-Helfer
// ============================================================================

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func append(_ d: Data) { lock.lock(); storage.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class StringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    /// Hängt einen Chunk an und liefert alle vollständigen Zeilen zurück.
    func drainLines(appending chunk: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer += chunk
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: "\n") {
            lines.append(String(buffer[..<nl]))
            buffer.removeSubrange(...nl)
        }
        return lines
    }
}

@MainActor
enum ProcessRunner {

    /// Startet ein Tool, sammelt stdout, streamt stderr an `onStderr`.
    static func capture(
        _ tool: URL,
        args: [String],
        onStderr: @escaping @Sendable (String) -> Void = { _ in },
        register: (Process) -> Void = { _ in }
    ) async -> (Data?, Int32) {
        let proc = Process()
        proc.executableURL = tool
        proc.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let box = DataBox()
        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if !d.isEmpty { box.append(d) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            onStderr(s)
        }

        register(proc)
        return await withCheckedContinuation { cont in
            proc.terminationHandler = { p in
                if let rest = try? outPipe.fileHandleForReading.readToEnd() {
                    box.append(rest)
                }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: (box.data, p.terminationStatus))
            }
            do {
                try proc.run()
            } catch {
                proc.terminationHandler = nil
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                onStderr("❌  \(error.localizedDescription)\n")
                cont.resume(returning: (nil, -1))
            }
        }
    }

    /// Startet ein Tool und leitet stdout+stderr live an `onLog`.
    static func live(
        _ tool: URL,
        args: [String],
        onLog: @escaping @Sendable (String) -> Void,
        register: (Process) -> Void = { _ in }
    ) async -> Int32 {
        let proc = Process()
        proc.executableURL = tool
        proc.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let stream: @Sendable (FileHandle) -> Void = { fh in
            let d = fh.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            onLog(s)
        }
        outPipe.fileHandleForReading.readabilityHandler = stream
        errPipe.fileHandleForReading.readabilityHandler = stream

        register(proc)
        return await withCheckedContinuation { cont in
            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: p.terminationStatus)
            }
            do {
                try proc.run()
            } catch {
                proc.terminationHandler = nil
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                onLog("❌  \(error.localizedDescription)\n")
                cont.resume(returning: -1)
            }
        }
    }

    /// ffmpeg mit `-progress pipe:1`: parst stdout als key=value-Stream und
    /// ruft `onProgress` (0…1) bei jeder Aktualisierung auf.
    static func ffmpegProgress(
        _ tool: URL,
        args: [String],
        duration: Double,
        onProgress: @escaping @Sendable (Double) -> Void,
        onStderr: @escaping @Sendable (String) -> Void,
        register: (Process) -> Void = { _ in }
    ) async -> Int32 {
        let proc = Process()
        proc.executableURL = tool
        proc.arguments = args

        let outPipe = Pipe()    // progress key=value
        let errPipe = Pipe()    // Fehlermeldungen
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let buffer = StringBox()
        outPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            guard !d.isEmpty, let chunk = String(data: d, encoding: .utf8) else { return }
            for line in buffer.drainLines(appending: chunk) {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let val = parts[1].trimmingCharacters(in: .whitespaces)
                if key == "out_time_us" || key == "out_time_ms" {
                    // "out_time_ms" liefert in der ffmpeg-Praxis ebenfalls µs.
                    if let us = Double(val), duration > 0 {
                        onProgress(min(1, max(0, us / 1_000_000 / duration)))
                    }
                } else if key == "progress", val == "end" {
                    onProgress(1)
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            onStderr(s)
        }

        register(proc)
        return await withCheckedContinuation { cont in
            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: p.terminationStatus)
            }
            do {
                try proc.run()
            } catch {
                proc.terminationHandler = nil
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                onStderr("❌  \(error.localizedDescription)\n")
                cont.resume(returning: -1)
            }
        }
    }
}

func stripANSI(_ s: String) -> String {
    let pattern = "\u{001B}\\[[0-9;]*[A-Za-z]"
    guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
    let range = NSRange(s.startIndex..., in: s)
    return re.stringByReplacingMatches(in: s, range: range, withTemplate: "")
}
