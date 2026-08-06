import AppKit
import Foundation
import Observation

// ============================================================================
// App-Model: Zustand + Verarbeitungslogik (Warteschlange, Pipelines)
// ============================================================================

@MainActor
@Observable
final class AppModel {
    var mode: Mode = .all
    var entries: [LogEntry] = []
    var isRunning = false
    var currentFile: String = ""
    var queue: [URL] = []
    var progress: Double = 0          // 0 … 1 (-1 = indeterminate)
    var statusText: String = ""       // z.B. "Transkodiere 720p · 42 %"
    var showLog: Bool = false

    /// Optionaler Zielordner. nil = Ausgabe neben die Quelldatei legen.
    var targetFolder: URL? {
        didSet { persistTargetFolder() }
    }

    var settings: TranscodeSettings {
        didSet { store.save(settings) }
    }

    private let store: PresetStore
    private let techLog: TechLog
    private var currentProcess: Process?
    private var cancelled = false

    private static let targetFolderKey = "VideoTools.targetFolder"

    /// Ordner mit den technischen Logdateien (für „Im Finder öffnen“).
    var techLogDirectory: URL { techLog.directory }

    init() {
        self.techLog = TechLog()
        let store = PresetStore()
        self.store = store
        var loaded = store.load()
        // Auswahl normalisieren, falls das gespeicherte Preset weg/inaktiv ist.
        if let fallback = loaded.selectedPreset, fallback.id != loaded.selectedPresetID {
            loaded.selectedPresetID = fallback.id
        }
        self.settings = loaded

        if let s = UserDefaults.standard.string(forKey: Self.targetFolderKey), !s.isEmpty {
            let url = URL(fileURLWithPath: s)
            if FileManager.default.fileExists(atPath: url.path) {
                targetFolder = url
            }
        }
    }

    private func persistTargetFolder() {
        if let path = targetFolder?.path {
            UserDefaults.standard.set(path, forKey: Self.targetFolderKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.targetFolderKey)
        }
    }

    /// Baut den Ausgabepfad `<targetFolder | Quellordner>/<fileName>`
    private func outputPath(for input: URL, fileName: String) -> String {
        let dir = targetFolder?.path ?? input.deletingLastPathComponent().path
        return "\(dir)/\(fileName)"
    }

    private func baseName(of input: URL) -> String {
        input.deletingPathExtension().lastPathComponent
    }

    // -------------------------------------------------------------------

    /// Eintrag fürs Fenster-Log; wird parallel ins technische Log geschrieben.
    private func logEntry(_ kind: LogEntry.Kind, _ text: String,
                          detail: String? = nil, path: String? = nil) {
        entries.append(LogEntry(kind: kind, text: text, detail: detail, path: path))
        let prefix: String
        switch kind {
        case .header:  prefix = "▶ "
        case .info:    prefix = "ℹ "
        case .success: prefix = "✓ "
        case .warning: prefix = "⚠ "
        case .error:   prefix = "❌ "
        }
        var line = prefix + text
        if let detail { line += "  (\(detail))" }
        if let path { line += "  → \(path)" }
        techLog.write(line + "\n")
    }

    func logHeader(_ text: String, detail: String? = nil) { logEntry(.header, text, detail: detail) }
    func logInfo(_ text: String, detail: String? = nil, path: String? = nil) { logEntry(.info, text, detail: detail, path: path) }
    func logSuccess(_ text: String, detail: String? = nil, path: String? = nil) { logEntry(.success, text, detail: detail, path: path) }
    func logWarning(_ text: String, detail: String? = nil) { logEntry(.warning, text, detail: detail) }
    func logError(_ text: String, detail: String? = nil) { logEntry(.error, text, detail: detail) }

    /// Technisches Detail: landet nur in der Logdatei, nicht im Fenster.
    func tech(_ s: String) {
        techLog.write(stripANSI(s))
    }

    func clearLog() { entries.removeAll() }

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

    /// Streamt Tool-Ausgaben (stderr etc.) ins technische Log (von beliebigem Thread aus).
    private var techSink: @Sendable (String) -> Void {
        { [weak self] s in Task { @MainActor in self?.tech(s) } }
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
            logError("ffmpeg/ffprobe nicht gefunden.",
                     detail: "Mit „brew install ffmpeg“ installieren – oder im Bundle bereitstellen.")
            queue.removeAll()
            return
        }

        if mode.usesPreset, settings.selectedPreset == nil {
            logError("Kein aktives Transcoding-Preset.",
                     detail: "In den Einstellungen (⌘,) ein Preset aktivieren.")
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
                    logInfo("Zielordner neu angelegt", path: dir.path)
                } catch {
                    logError("Zielordner nicht verfügbar", detail: error.localizedDescription)
                    queue.removeAll()
                    return
                }
            } else if !isDir.boolValue {
                logError("Zielpfad ist kein Ordner", detail: dir.path)
                queue.removeAll()
                return
            }
            logInfo("Zielordner", path: dir.path)
        }

        while !queue.isEmpty, !cancelled {
            let url = queue.removeFirst()
            currentFile = url.lastPathComponent
            tech("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
            logHeader(url.lastPathComponent, detail: mode.label)

            switch mode {
            case .all:
                await runInfo(url, stepCount: 3, stepIndex: 0)
                if cancelled { break }
                await runStill(url, atSecond: 3, stepCount: 3, stepIndex: 1)
                if cancelled { break }
                if let preset = settings.selectedPreset {
                    await runEncode(url, preset: preset, stepCount: 3, stepIndex: 2)
                }
            case .info:
                await runInfo(url, stepCount: 1, stepIndex: 0)
            case .still:
                await runStill(url, atSecond: 3, stepCount: 1, stepIndex: 0)
            case .encode:
                if let preset = settings.selectedPreset {
                    await runEncode(url, preset: preset, stepCount: 1, stepIndex: 0)
                }
            }
        }

        if cancelled {
            logWarning("Abgebrochen – Warteschlange geleert.")
        } else {
            logSuccess("Alle Dateien verarbeitet.")
            NSSound(named: .init("Glass"))?.play()
        }
    }

    // -------------------------------------------------------------------
    // Pipelines
    // -------------------------------------------------------------------

    /// Ermittelt Dauer (Sekunden) und Scan-Typ des ersten Videostreams.
    private struct ProbeSummary: Decodable {
        struct Format: Decodable { let duration: String? }
        struct Stream: Decodable { let field_order: String? }
        let format: Format?
        let streams: [Stream]?
    }

    private func probeVideo(_ url: URL) async -> (duration: Double, isInterlaced: Bool) {
        guard let ffprobe = Tools.locate("ffprobe") else { return (0, false) }
        let (data, _) = await ProcessRunner.capture(ffprobe, args: [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=field_order",
            "-show_entries", "format=duration",
            "-of", "json",
            url.path
        ], onStderr: techSink, register: { currentProcess = $0 })
        currentProcess = nil
        guard let data, let p = try? JSONDecoder().decode(ProbeSummary.self, from: data) else {
            return (0, false)
        }
        let duration = Double(p.format?.duration ?? "") ?? 0
        let fo = p.streams?.first?.field_order?.lowercased() ?? ""
        let interlaced = !fo.isEmpty && fo != "unknown" && !fo.contains("progressive")
        return (duration, interlaced)
    }

    // ---- info -----------------------------------------------------------

    private func runInfo(_ input: URL, stepCount: Int, stepIndex: Int) async {
        sep()
        statusText = "Metadaten …"; progress = -1

        guard let ffprobe = Tools.locate("ffprobe") else {
            logError("ffprobe nicht gefunden."); return
        }

        let (data, _) = await ProcessRunner.capture(ffprobe, args: [
            "-v", "quiet", "-print_format", "json",
            "-show_format", "-show_streams", input.path
        ], onStderr: techSink, register: { currentProcess = $0 })
        currentProcess = nil
        guard let data, let probe = try? JSONDecoder().decode(FFProbeOutput.self, from: data) else {
            logError("Metadaten konnten nicht gelesen werden", detail: "Details im technischen Log"); return
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

        var estimateBlock = ""
        if let preset = settings.selectedPreset {
            var lines: [String] = []
            for r in preset.renditions {
                let kbps = r.estimatedBitrateKbps
                let mb = Double(kbps) * 1000 * Double(durSec) / 8 / 1_048_576
                lines.append("  \(r.name) (~\(kbps) kbps) : ~\(String(format: "%.2f", mb)) MB")
            }
            estimateBlock = """


            [VORSCHAU-SCHÄTZUNGEN – Preset „\(preset.label)“]
            \(lines.joined(separator: "\n"))
            """
        }

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
          Kanäle           : \(a?.channels ?? 0)\(estimateBlock)
        """
        tech(report + "\n")

        // Kompakte, verständliche Zusammenfassung fürs Fenster
        let codec = (v?.codec_name ?? "?").uppercased()
        let summary = "\(v?.width ?? 0)×\(v?.height ?? 0) · \(fps) fps · \(hms(durSec)) · \(codec) · \(String(format: "%.1f", sizeMB)) MB · \(scan)"

        let outTxt = outputPath(for: input, fileName: "\(baseName(of: input))_metadata.txt")
        do {
            try report.write(toFile: outTxt, atomically: true, encoding: .utf8)
            logSuccess("Metadaten gespeichert", detail: summary, path: outTxt)
        } catch {
            logError("Metadaten-Datei konnte nicht geschrieben werden", detail: error.localizedDescription)
        }
        updateStepProgress(stepIndex: stepIndex, stepCount: stepCount, inner: 1)
    }

    // ---- still ----------------------------------------------------------

    private func runStill(_ input: URL, atSecond: Int, stepCount: Int, stepIndex: Int) async {
        guard let ffmpeg = Tools.locate("ffmpeg") else {
            logError("ffmpeg nicht gefunden."); return
        }
        // Bei sehr kurzen Clips läge der Zeitpunkt hinter dem letzten Frame.
        var at = Double(atSecond)
        let duration = (await probeVideo(input)).duration
        if duration > 0, at >= duration { at = duration / 2 }
        sep()
        logInfo("Erzeuge Vorschaubilder", detail: "bei Sekunde \(String(format: "%.1f", at)), 3 Größen")
        let sizes: [(String, String)] = [
            ("small",  "320:180"),
            ("medium", "640:360"),
            ("large",  "1280:720")
        ]
        for (idx, (label, size)) in sizes.enumerated() {
            if cancelled { break }
            statusText = "Vorschaubild \(label)"
            let outPath = outputPath(for: input, fileName: "\(baseName(of: input))_still_\(label).jpg")
            let args = [
                "-ss", String(format: "%.2f", at), "-i", input.path,
                "-frames:v", "1",
                "-vf", "scale=\(size):force_original_aspect_ratio=decrease",
                "-q:v", "5", "-y", outPath,
                "-loglevel", "error"
            ]
            tech("$ ffmpeg \(args.joined(separator: " "))\n")
            let code = await ProcessRunner.live(ffmpeg, args: args, onLog: techSink,
                                                register: { currentProcess = $0 })
            currentProcess = nil
            if code == 0 {
                logSuccess("Vorschaubild \(label)", path: outPath)
            } else {
                tech("Still \(label): exit \(code)\n")
                logWarning("Vorschaubild \(label) fehlgeschlagen", detail: "Details im technischen Log")
            }
            let inner = Double(idx + 1) / Double(sizes.count)
            updateStepProgress(stepIndex: stepIndex, stepCount: stepCount, inner: inner)
        }
        sep()
    }

    // ---- encode (Preset mit Renditions, mit Progress-Parsing) ------------

    private func resolveAudioCodec() async -> String {
        switch settings.audioCodec {
        case .nativeAAC:
            return "aac"
        case .fdkAAC:
            if await !Tools.hasEncoder("libfdk_aac") {
                logWarning("libfdk_aac ist in diesem ffmpeg-Build nicht enthalten",
                           detail: "Die Transkodierung wird vermutlich fehlschlagen.")
            }
            return "libfdk_aac"
        case .auto:
            if await Tools.hasEncoder("libfdk_aac") { return "libfdk_aac" }
            return "aac"
        }
    }

    private func runEncode(_ input: URL, preset: TranscodePreset, stepCount: Int, stepIndex: Int) async {
        guard let ffmpeg = Tools.locate("ffmpeg") else {
            logError("ffmpeg nicht gefunden."); return
        }
        guard !preset.renditions.isEmpty else {
            logWarning("Preset „\(preset.label)“ hat keine Renditions – nichts zu tun.")
            return
        }
        sep()
        let outputWord = preset.renditions.count == 1 ? "1 Ausgabe" : "\(preset.renditions.count) Ausgaben"
        logInfo("Transkodiere mit Preset „\(preset.label)“", detail: outputWord)

        let probe = await probeVideo(input)
        if probe.duration <= 0 { logWarning("Videodauer unbekannt – keine Prozentanzeige möglich.") }

        let hasVideoRenditions = preset.renditions.contains { $0.container == .mp4 }

        var deinterlace = false
        if hasVideoRenditions {
            switch settings.deinterlace {
            case .off:    deinterlace = false
            case .always: deinterlace = true
            case .auto:   deinterlace = probe.isInterlaced
            }
            if deinterlace {
                logInfo("Quelle ist interlaced – Deinterlacing wird angewendet.")
            }
        }

        let resolvedAudio = hasVideoRenditions ? await resolveAudioCodec() : "aac"
        if hasVideoRenditions {
            tech("Audio-Codec (MP4): \(resolvedAudio)\n")
        }

        let renditionCount = preset.renditions.count
        for (rIdx, rendition) in preset.renditions.enumerated() {
            if cancelled { break }
            let fileName = preset.outputFileName(base: baseName(of: input), rendition: rendition)
            let outFile = outputPath(for: input, fileName: fileName)

            sep()
            switch rendition.container {
            case .mp4:
                logInfo("\(rendition.name) wird erstellt", detail: "\(rendition.width)×\(rendition.height)")
            case .mp3, .wav:
                logInfo("\(rendition.name) wird erstellt", detail: rendition.container.rawValue.uppercased())
            }
            statusText = "Transkodiere \(rendition.name) · 0 %"

            var args = rendition.coreArguments(input: input.path,
                                               deinterlace: deinterlace && rendition.container == .mp4,
                                               resolvedAudioCodec: resolvedAudio)
            args += ["-nostats", "-loglevel", "error", "-progress", "pipe:1", outFile]
            tech("$ ffmpeg \(args.joined(separator: " "))\n")

            let name = rendition.name
            let code = await ProcessRunner.ffmpegProgress(
                ffmpeg, args: args, duration: probe.duration,
                onProgress: { [weak self] pct in
                    Task { @MainActor in
                        guard let self else { return }
                        self.statusText = "Transkodiere \(name) · \(Int(pct * 100)) %"
                        let innerStage = Double(rIdx) / Double(renditionCount) + (pct / Double(renditionCount))
                        self.updateStepProgress(stepIndex: stepIndex, stepCount: stepCount, inner: innerStage)
                    }
                },
                onStderr: techSink,
                register: { currentProcess = $0 }
            )
            currentProcess = nil
            if code == 0 {
                logSuccess("\(rendition.name) fertig", detail: fileSizeLabel(outFile), path: outFile)
            } else if cancelled {
                logWarning("\(rendition.name) abgebrochen")
                // Unvollständige Datei aufräumen
                try? FileManager.default.removeItem(atPath: outFile)
                break
            } else {
                tech("Transkodierung \(rendition.name): exit \(code)\n")
                logError("\(rendition.name) fehlgeschlagen", detail: "Details im technischen Log")
            }
            updateStepProgress(
                stepIndex: stepIndex, stepCount: stepCount,
                inner: Double(rIdx + 1) / Double(renditionCount)
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

    /// Abschnittstrenner – nur im technischen Log.
    private func sep() {
        tech("/*──────────────────────────────────────────────────────*/\n")
    }

    private func hms(_ total: Int) -> String {
        String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Lesbare Dateigröße, z.B. "12,4 MB".
    private func fileSizeLabel(_ path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1000 { return String(format: "%.2f GB", mb / 1024) }
        return String(format: "%.1f MB", mb)
    }
}
