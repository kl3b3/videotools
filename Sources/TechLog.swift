import Foundation

// ============================================================================
// Technisches Protokoll auf Platte
//
// Ablage: ~/Library/Logs/VideoTools/VideoTools-<yyyy-MM-dd>.log
// Enthält alles, was früher im UI-Log stand (ffmpeg-Befehle, stderr,
// Exit-Codes), mit Zeitstempel pro Zeile. Dateien, die älter als
// `retentionDays` sind, werden beim Start und beim Tageswechsel gelöscht.
// ============================================================================

@MainActor
final class TechLog {
    static let retentionDays = 7

    let directory: URL
    private var handle: FileHandle?
    private var currentDay = ""
    private var atLineStart = true

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    init() {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        directory = library.appendingPathComponent("Logs/VideoTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        purgeOldLogs()
        openTodaysFile()
        write("────────  VideoTools gestartet  ────────\n")
    }

    deinit {
        try? handle?.close()
    }

    /// Hängt einen Text-Chunk an; jede neue Zeile bekommt einen Zeitstempel.
    func write(_ chunk: String) {
        rolloverIfNeeded()
        guard let handle else { return }
        let stamp = "[\(timeFormatter.string(from: Date()))] "
        var out = ""
        var rest = Substring(chunk)
        while let nl = rest.firstIndex(of: "\n") {
            if atLineStart { out += stamp }
            out += rest[..<nl] + "\n"
            atLineStart = true
            rest = rest[rest.index(after: nl)...]
        }
        if !rest.isEmpty {
            if atLineStart { out += stamp }
            out += rest
            atLineStart = false
        }
        if let data = out.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    // -------------------------------------------------------------------

    private func openTodaysFile() {
        currentDay = dayFormatter.string(from: Date())
        let url = directory.appendingPathComponent("VideoTools-\(currentDay).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        atLineStart = true
    }

    private func rolloverIfNeeded() {
        let today = dayFormatter.string(from: Date())
        guard today != currentDay else { return }
        try? handle?.close()
        openTodaysFile()
        purgeOldLogs()
    }

    private func purgeOldLogs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        for file in files
        where file.lastPathComponent.hasPrefix("VideoTools-") && file.pathExtension == "log" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }
}
