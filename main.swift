import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation

// ============================================================================
// MARK: - App Entry
// ============================================================================

@main
struct VideoToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("VideoTools") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 360)
                .onAppear { AppDelegate.sharedModel = model }
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedModel: AppModel?

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        Task { @MainActor in AppDelegate.sharedModel?.enqueue(urls) }
        sender.reply(toOpenOrPrint: .success)
    }
}

// ============================================================================
// MARK: - Modes
// ============================================================================

enum Mode: String, CaseIterable, Identifiable {
    case all, info, still, encode360, encode720, encodeAll
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:       return "Alles (Metadaten + Stills + Transkodierung)"
        case .info:      return "Nur Metadaten"
        case .still:     return "Stills extrahieren"
        case .encode360: return "Transkodieren · 360p"
        case .encode720: return "Transkodieren · 720p"
        case .encodeAll: return "Transkodieren · alle Qualitäten"
        }
    }
}

// ============================================================================
// MARK: - Tool locator
// ============================================================================

enum Tools {
    static func locate(_ name: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for p in ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
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
}

// ============================================================================
// MARK: - ffprobe JSON
// ============================================================================

private struct FFProbeOutput: Decodable {
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
// MARK: - App model (state + processing logic)
// ============================================================================

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: Mode = .all
    @Published var log: String = ""
    @Published var isRunning = false
    @Published var currentFile: String = ""
    @Published var queue: [URL] = []
    @Published var progress: Double = 0          // 0 … 1 (-1 = indeterminate)
    @Published var statusText: String = ""       // z.B. "Transkodiere 720p · 42 %"
    @Published var showLog: Bool = false

    /// Optionaler Zielordner. nil = Ausgabe neben die Quelldatei legen.
    @Published var targetFolder: URL? {
        didSet { persistTargetFolder() }
    }

    private var currentProcess: Process?
    private var cancelled: Bool = false

    private static let defaultsKey = "VideoTools.targetFolder"

    init() {
        if let s = UserDefaults.standard.string(forKey: Self.defaultsKey), !s.isEmpty {
            let url = URL(fileURLWithPath: s)
            if FileManager.default.fileExists(atPath: url.path) {
                self.targetFolder = url
            }
        }
    }

    private func persistTargetFolder() {
        if let path = targetFolder?.path {
            UserDefaults.standard.set(path, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
    }

    /// Baut den Ausgabepfad auf Basis `<targetFolder | Quellordner>/<basename><suffix>`
    private func outputPath(for input: URL, suffix: String) -> String {
        let baseName = input.deletingPathExtension().lastPathComponent
        let dir = targetFolder?.path ?? input.deletingLastPathComponent().path
        return "\(dir)/\(baseName)\(suffix)"
    }

    // -------------------------------------------------------------------

    func append(_ s: String) { log += stripANSI(s) }

    func clearLog() { log = "" }

    func enqueue(_ urls: [URL]) {
        queue.append(contentsOf: urls)
        guard !isRunning else { return }
        Task { await drain() }
    }

    /// Bricht die aktuelle Verarbeitung ab und leert die Warteschlange.
    func cancel() {
        cancelled = true
        queue.removeAll()
        if let p = currentProcess, p.isRunning {
            p.terminate()
        }
        statusText = "Abbrechen …"
    }

    // -------------------------------------------------------------------
    // Drain loop
    // -------------------------------------------------------------------

    private func drain() async {
        isRunning = true
        cancelled = false
        defer {
            isRunning = false
            currentFile = ""
            progress = 0
            statusText = ""
            currentProcess = nil
            cancelled = false
        }

        if Tools.locate("ffmpeg") == nil || Tools.locate("ffprobe") == nil {
            append("❌  ffmpeg/ffprobe nicht gefunden. brew install ffmpeg – oder im Bundle bereitstellen.\n")
            queue.removeAll()
            return
        }

        // Zielordner validieren / erzeugen
        if let dir = targetFolder {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
            if !exists {
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    append("ℹ  Zielordner neu angelegt: \(dir.path)\n")
                } catch {
                    append("❌  Zielordner nicht verfügbar: \(error.localizedDescription)\n")
                    queue.removeAll()
                    return
                }
            } else if !isDir.boolValue {
                append("❌  Zielpfad ist keine Directory: \(dir.path)\n")
                queue.removeAll()
                return
            }
            append("ℹ  Zielordner: \(dir.path)\n")
        }

        while !queue.isEmpty, !cancelled {
            let url = queue.removeFirst()
            currentFile = url.lastPathComponent
            append("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
            append("▶  \(url.lastPathComponent)  —  \(mode.label)\n")
            append("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")

            switch mode {
            case .all:
                await runInfo(url, stepCount: 3, stepIndex: 0)
                if cancelled { break }
                await runStill(url, atSecond: 3, stepCount: 3, stepIndex: 1)
                if cancelled { break }
                await runEncode(url, qualities: ["360p", "720p"], stepCount: 3, stepIndex: 2)
            case .info:
                await runInfo(url, stepCount: 1, stepIndex: 0)
            case .still:
                await runStill(url, atSecond: 3, stepCount: 1, stepIndex: 0)
            case .encode360:
                await runEncode(url, qualities: ["360p"], stepCount: 1, stepIndex: 0)
            case .encode720:
                await runEncode(url, qualities: ["720p"], stepCount: 1, stepIndex: 0)
            case .encodeAll:
                await runEncode(url, qualities: ["360p", "720p"], stepCount: 1, stepIndex: 0)
            }
        }

        if cancelled {
            append("\n⛔  Abgebrochen.\n")
        } else {
            append("\n✓  Alle Dateien verarbeitet.\n")
            NSSound(named: .init("Glass"))?.play()
        }
    }

    // -------------------------------------------------------------------
    // Pipelines
    // -------------------------------------------------------------------

    /// Ermittelt die Gesamtdauer per ffprobe (in Sekunden).
    private func probeDuration(_ url: URL) async -> Double {
        guard let ffprobe = Tools.locate("ffprobe") else { return 0 }
        let (data, _) = await runAndCapture(ffprobe, args: [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ])
        guard let data, let s = String(data: data, encoding: .utf8) else { return 0 }
        return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // ---- info -----------------------------------------------------------

    private func runInfo(_ input: URL, stepCount: Int, stepIndex: Int) async {
        sep(); append("ℹ  Extrahiere Metadaten: \(input.lastPathComponent)\n"); sep()
        statusText = "Metadaten …"; progress = -1

        guard let ffprobe = Tools.locate("ffprobe") else {
            append("❌  ffprobe nicht gefunden.\n"); return
        }

        let (data, _) = await runAndCapture(ffprobe, args: [
            "-v", "quiet", "-print_format", "json",
            "-show_format", "-show_streams", input.path
        ])
        guard let data, let probe = try? JSONDecoder().decode(FFProbeOutput.self, from: data) else {
            append("❌  ffprobe-Ausgabe konnte nicht gelesen werden.\n"); return
        }

        let durSec   = Int(Double(probe.format.duration ?? "0") ?? 0)
        let overall  = Int(probe.format.bit_rate ?? "0") ?? 0
        let filesize = Int64(probe.format.size ?? "0") ?? 0
        let sizeMB   = Double(filesize) / 1_048_576.0

        let v = probe.streams.first(where: { $0.codec_type == "video" })
        let a = probe.streams.first(where: { $0.codec_type == "audio" })

        let fps: Double = {
            let parts = (v?.avg_frame_rate ?? "0/1").split(separator: "/").compactMap { Double($0) }
            guard parts.count == 2, parts[1] > 0 else { return 0 }
            return (parts[0] / parts[1] * 1000).rounded() / 1000
        }()
        let scan: String = {
            guard let fo = v?.field_order?.lowercased() else { return "Unbekannt" }
            if fo.contains("progressive") { return "Progressive" }
            return fo.isEmpty ? "Unbekannt" : "Interlaced"
        }()

        let df = DateFormatter(); df.dateFormat = "dd.MM.yyyy HH:mm:ss"
        let est360 = Double(800_000 * durSec) / 8 / 1_048_576
        let est720 = Double(2_500_000 * durSec) / 8 / 1_048_576

        let report = """
        ======================================
          VIDEO METADATEN
          Quelle : \(input.path)
          Datum  : \(df.string(from: Date()))
        ======================================

        [ALLGEMEIN]
          Format           : \(probe.format.format_long_name ?? "")
          Dateiendung      : \(input.pathExtension.uppercased())
          Dateigröße       : \(String(format: "%.2f", sizeMB)) MB
          Dauer (h:m:s)    : \(hms(durSec))
          Gesamt-Bitrate   : \(overall / 1000) Kbps

        [VIDEO]
          Codec            : \((v?.codec_name ?? "").uppercased())
          Auflösung        : \(v?.width ?? 0)x\(v?.height ?? 0)
          Seitenverhältnis : \(v?.display_aspect_ratio ?? "n/a")
          Framerate        : \(fps) fps
          Bitrate          : \((Int(v?.bit_rate ?? "0") ?? 0) / 1000) Kbps
          Scan-Typ         : \(scan)

        [AUDIO]
          Codec            : \((a?.codec_name ?? "").uppercased())
          Bitrate          : \((Int(a?.bit_rate ?? "0") ?? 0) / 1000) Kbps
          Samplerate       : \((Int(a?.sample_rate ?? "0") ?? 0) / 1000) KHz
          Kanäle           : \(a?.channels ?? 0)

        [VORSCHAU-SCHÄTZUNGEN (bei Transkodierung)]
          360p (~800 kbps) : ~\(String(format: "%.2f", est360)) MB
          720p (~2.5 Mbps) : ~\(String(format: "%.2f", est720)) MB
        """
        append(report + "\n")

        let outTxt = outputPath(for: input, suffix: "_metadata.txt")
        do {
            try report.write(toFile: outTxt, atomically: true, encoding: .utf8)
            append("✓  Metadaten gespeichert → \(outTxt)\n")
        } catch {
            append("❌  Konnte Metadaten-Datei nicht schreiben: \(error.localizedDescription)\n")
        }
        updateStepProgress(stepIndex: stepIndex, stepCount: stepCount, inner: 1)
    }

    // ---- still ----------------------------------------------------------

    private func runStill(_ input: URL, atSecond at: Int, stepCount: Int, stepIndex: Int) async {
        sep(); append("ℹ  Extrahiere Stills bei \(at)s …\n")
        guard let ffmpeg = Tools.locate("ffmpeg") else {
            append("❌  ffmpeg nicht gefunden.\n"); return
        }
        let sizes: [(String, String)] = [
            ("small",  "320:180"),
            ("medium", "640:360"),
            ("large",  "1280:720")
        ]
        for (idx, (label, size)) in sizes.enumerated() {
            if cancelled { break }
            statusText = "Still \(label)"
            let outPath = outputPath(for: input, suffix: "_still_\(label).jpg")
            let args = [
                "-ss", "\(at)", "-i", input.path,
                "-frames:v", "1",
                "-vf", "scale=\(size):force_original_aspect_ratio=decrease",
                "-q:v", "5", "-y", outPath,
                "-loglevel", "error"
            ]
            let code = await runLive(ffmpeg, args: args)
            if code == 0 {
                append("✓  Still (\(label)) → \(outPath)\n")
            } else {
                append("❌  Still (\(label)) exit \(code)\n")
            }
            let inner = Double(idx + 1) / Double(sizes.count)
            updateStepProgress(stepIndex: stepIndex, stepCount: stepCount, inner: inner)
        }
        sep()
    }

    // ---- encode (mit Progress-Parsing) ---------------------------------

    private func runEncode(_ input: URL, qualities: [String], stepCount: Int, stepIndex: Int) async {
        guard let ffmpeg = Tools.locate("ffmpeg") else {
            append("❌  ffmpeg nicht gefunden.\n"); return
        }
        sep(); append("ℹ  Starte Transkodierung von: \(input.lastPathComponent)\n")

        let duration = await probeDuration(input)
        if duration <= 0 { append("⚠  Dauer unbekannt – Fortschritt indeterminate.\n") }

        for (qIdx, q) in qualities.enumerated() {
            if cancelled { break }
            let size: String
            switch q {
            case "360p": size = "640:360"
            case "720p": size = "1280:720"
            default: append("❌  Unbekannte Qualität: \(q)\n"); continue
            }
            let suffix = (q == "360p") ? "T" : "T-\(q)"
            let outFile = outputPath(for: input, suffix: "_\(suffix).mp4")

            sep(); append("ℹ  Transkodiere → \(q) (\(size)) …\n")
            statusText = "Transkodiere \(q) · 0 %"

            let args = [
                "-i", input.path,
                "-c:v", "libx264",
                "-c:a", "aac",
                "-s", size,
                "-preset", "fast",
                "-movflags", "faststart",
                "-profile:v", "main",
                "-crf", "23",
                "-y", outFile,
                "-nostats",
                "-loglevel", "error",
                "-progress", "pipe:1"
            ]

            let code = await runFFmpegWithProgress(
                ffmpeg, args: args, duration: duration,
                onProgress: { [weak self] pct in
                    guard let self else { return }
                    let label = "Transkodiere \(q) · \(Int(pct * 100)) %"
                    self.statusText = label
                    let innerStage = Double(qIdx) / Double(qualities.count) + (pct / Double(qualities.count))
                    self.updateStepProgress(stepIndex: stepIndex, stepCount: stepCount, inner: innerStage)
                }
            )
            if code == 0 {
                append("✓  Fertig → \(outFile)\n")
            } else if cancelled {
                append("⛔  \(q) abgebrochen\n")
                // Unvollständige Datei aufräumen
                try? FileManager.default.removeItem(atPath: outFile)
                break
            } else {
                append("❌  Transkodierung (\(q)) exit \(code)\n")
            }
            updateStepProgress(
                stepIndex: stepIndex, stepCount: stepCount,
                inner: Double(qIdx + 1) / Double(qualities.count)
            )
        }
        sep()
    }

    // -------------------------------------------------------------------
    // Progress helpers
    // -------------------------------------------------------------------

    private func updateStepProgress(stepIndex: Int, stepCount: Int, inner: Double) {
        let clamped = max(0, min(1, inner))
        progress = (Double(stepIndex) + clamped) / Double(stepCount)
    }

    private func sep() {
        append("/*──────────────────────────────────────────────────────*/\n")
    }

    private func hms(_ total: Int) -> String {
        String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // -------------------------------------------------------------------
    // Process helpers
    // -------------------------------------------------------------------

    /// Startet ein Tool, sammelt stdout synchron, streamt stderr in den Log.
    private func runAndCapture(_ tool: URL, args: [String]) async -> (Data?, Int32) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Data?, Int32), Never>) in
            let proc = Process()
            proc.executableURL = tool
            proc.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            errPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                Task { @MainActor in AppDelegate.sharedModel?.append(s) }
            }

            proc.terminationHandler = { p in
                errPipe.fileHandleForReading.readabilityHandler = nil
                let out = try? outPipe.fileHandleForReading.readToEnd()
                Task { @MainActor in AppDelegate.sharedModel?.currentProcess = nil }
                cont.resume(returning: (out, p.terminationStatus))
            }

            do {
                currentProcess = proc
                try proc.run()
            } catch {
                append("❌  \(error.localizedDescription)\n")
                cont.resume(returning: (nil, -1))
            }
        }
    }

    /// Startet ein Tool und leitet stdout+stderr live in den Log.
    private func runLive(_ tool: URL, args: [String]) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let proc = Process()
            proc.executableURL = tool
            proc.arguments = args

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            let live: @Sendable (FileHandle) -> Void = { fh in
                let d = fh.availableData
                guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                Task { @MainActor in AppDelegate.sharedModel?.append(s) }
            }
            outPipe.fileHandleForReading.readabilityHandler = live
            errPipe.fileHandleForReading.readabilityHandler = live

            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in AppDelegate.sharedModel?.currentProcess = nil }
                cont.resume(returning: p.terminationStatus)
            }

            do {
                currentProcess = proc
                try proc.run()
            } catch {
                append("❌  \(error.localizedDescription)\n")
                cont.resume(returning: -1)
            }
        }
    }

    /// ffmpeg mit `-progress pipe:1`: parst stdout als key=value-Stream,
    /// ruft onProgress(percent 0..1) bei jeder Aktualisierung auf.
    private func runFFmpegWithProgress(
        _ tool: URL,
        args: [String],
        duration: Double,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async -> Int32 {
        await withCheckedContinuation { (cont: CheckedContinuation<Int32, Never>) in
            let proc = Process()
            proc.executableURL = tool
            proc.arguments = args

            let outPipe = Pipe()    // progress key=value
            let errPipe = Pipe()    // evtl. Fehlermeldungen
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            // Buffer für zeilenweises Parsing (nonisolated closure → lokale Box)
            final class Box { var s = "" }
            let buffer = Box()
            let lock = NSLock()

            outPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                guard !d.isEmpty, let chunk = String(data: d, encoding: .utf8) else { return }
                lock.lock()
                buffer.s += chunk
                var lines: [String] = []
                while let nl = buffer.s.firstIndex(of: "\n") {
                    lines.append(String(buffer.s[..<nl]))
                    buffer.s.removeSubrange(...nl)
                }
                lock.unlock()
                for line in lines {
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    let key = parts[0].trimmingCharacters(in: .whitespaces)
                    let val = parts[1].trimmingCharacters(in: .whitespaces)
                    if key == "out_time_us" || key == "out_time_ms" {
                        // "out_time_ms" ist in der ffmpeg-Praxis ebenfalls µs.
                        if let us = Double(val), duration > 0 {
                            let pct = min(1, max(0, us / 1_000_000 / duration))
                            Task { @MainActor in onProgress(pct) }
                        }
                    } else if key == "progress", val == "end" {
                        Task { @MainActor in onProgress(1) }
                    }
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { fh in
                let d = fh.availableData
                guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                Task { @MainActor in AppDelegate.sharedModel?.append(s) }
            }

            proc.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in AppDelegate.sharedModel?.currentProcess = nil }
                cont.resume(returning: p.terminationStatus)
            }

            do {
                currentProcess = proc
                try proc.run()
            } catch {
                append("❌  \(error.localizedDescription)\n")
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

// ============================================================================
// MARK: - ContentView
// ============================================================================

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 14) {
            header
            targetFolderRow
            dropZone.frame(maxWidth: .infinity, minHeight: 170)
            progressBar
            actions
            if model.showLog { logView.transition(.opacity.combined(with: .move(edge: .top))) }
            footer
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.2), value: model.showLog)
    }

    private var targetFolderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: model.targetFolder == nil ? "folder" : "folder.fill")
                .foregroundStyle(model.targetFolder == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            VStack(alignment: .leading, spacing: 1) {
                Text("Zielordner").font(.caption).foregroundStyle(.secondary)
                Text(model.targetFolder?.path ?? "neben Quelldatei")
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let dir = model.targetFolder {
                Button {
                    NSWorkspace.shared.open(dir)
                } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless)
                .help("Im Finder öffnen")
            }
            Button("Ändern …") { pickTargetFolder() }
                .disabled(model.isRunning)
            if model.targetFolder != nil {
                Button("Zurücksetzen") { model.targetFolder = nil }
                    .disabled(model.isRunning)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func pickTargetFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Auswählen"
        panel.message = "Zielordner für Metadaten, Stills und Transcodes wählen"
        if panel.runModal() == .OK, let url = panel.url {
            model.targetFolder = url
        }
    }

    // MARK: Subviews

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("VideoTools").font(.title2).bold()
                Text("Metadaten · Stills · Transkodierung")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Modus", selection: $model.mode) {
                ForEach(Mode.allCases) { m in Text(m.label).tag(m) }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 320)
            .disabled(model.isRunning)
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.06))
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.6))
            VStack(spacing: 8) {
                Image(systemName: model.isRunning ? "gearshape.2.fill" : "arrow.down.doc.fill")
                    .font(.system(size: 34))
                Text(model.isRunning
                     ? "Läuft: \(model.currentFile)"
                     : "Videodatei(en) hier hineinziehen")
                    .font(.headline)
                Text(model.isRunning
                     ? (model.statusText.isEmpty ? "…" : model.statusText)
                     : "oder klicken, um Datei auszuwählen")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture {
            guard !model.isRunning else { return }
            pickFiles()
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task { await handleProviders(providers) }
            return true
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if model.isRunning {
            HStack(spacing: 10) {
                if model.progress < 0 {
                    ProgressView().controlSize(.small)
                    Text(model.statusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                    Text("\(Int(model.progress * 100)) %")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .frame(minWidth: 44, alignment: .trailing)
                }
            }
            .transition(.opacity)
        }
    }

    private var actions: some View {
        HStack {
            if model.isRunning {
                Button(role: .destructive) {
                    model.cancel()
                } label: {
                    Label("Abbrechen", systemImage: "stop.fill")
                }
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button {
                    model.clearLog()
                } label: {
                    Label("Log leeren", systemImage: "trash")
                }
                .disabled(model.log.isEmpty)
            }

            Spacer()

            Button {
                model.showLog.toggle()
            } label: {
                Label(
                    model.showLog ? "Log verbergen" : "Log anzeigen",
                    systemImage: model.showLog ? "eye.slash" : "eye"
                )
            }
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(model.log.isEmpty ? "Ausgabe erscheint hier…" : model.log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(model.log.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .id("logContent")
            }
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .frame(minHeight: 180)
            .onChange(of: model.log) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("logContent", anchor: .bottom)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            ToolStatusView()
            Spacer()
        }
    }

    // MARK: File handling

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let movie = UTType("public.movie") {
            panel.allowedContentTypes = [movie]
        }
        if panel.runModal() == .OK { model.enqueue(panel.urls) }
    }

    private func handleProviders(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for p in providers {
            if let url = await loadURL(from: p) { urls.append(url) }
        }
        if !urls.isEmpty { model.enqueue(urls) }
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                cont.resume(returning: url)
            }
        }
    }
}

private struct ToolStatusView: View {
    var body: some View {
        let ff = Tools.locate("ffmpeg")
        let fp = Tools.locate("ffprobe")
        let ok = (ff != nil && fp != nil)
        let bundled = (ff?.path.contains(".app/Contents/Resources/") ?? false)
        let label: String = {
            if !ok { return "ffmpeg/ffprobe fehlen" }
            return bundled ? "ffmpeg gebündelt" : "ffmpeg: \(ff?.path ?? "")"
        }()
        return HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}
