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
    var log: String = ""
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
        didSet { settings.save() }
    }

    private var currentProcess: Process?
    private var cancelled = false

    private static let targetFolderKey = "VideoTools.targetFolder"

    init() {
        settings = TranscodeSettings.load()
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

    /// Streamt Tool-Ausgaben zurück in den Log (von beliebigem Thread aus).
    private var logSink: @Sendable (String) -> Void {
        { [weak self] s in Task { @MainActor in self?.append(s) } }
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
                await runEncode(url, presets: [settings.preset360, settings.preset720],
                                stepCount: 3, stepIndex: 2)
            case .info:
                await runInfo(url, stepCount: 1, stepIndex: 0)
            case .still:
                await runStill(url, atSecond: 3, stepCount: 1, stepIndex: 0)
            case .encode360:
                await runEncode(url, presets: [settings.preset360], stepCount: 1, stepIndex: 0)
            case .encode720:
                await runEncode(url, presets: [settings.preset720], stepCount: 1, stepIndex: 0)
            case .encodeAll:
                await runEncode(url, presets: [settings.preset360, settings.preset720],
                                stepCount: 1, stepIndex: 0)
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
        ], onStderr: logSink, register: { currentProcess = $0 })
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
        sep(); append("ℹ  Extrahiere Metadaten: \(input.lastPathComponent)\n"); sep()
        statusText = "Metadaten …"; progress = -1

        guard let ffprobe = Tools.locate("ffprobe") else {
            append("❌  ffprobe nicht gefunden.\n"); return
        }

        let (data, _) = await ProcessRunner.capture(ffprobe, args: [
            "-v", "quiet", "-print_format", "json",
            "-show_format", "-show_streams", input.path
        ], onStderr: logSink, register: { currentProcess = $0 })
        currentProcess = nil
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
        let est360 = Double(settings.preset360.videoBitrateKbps * 1000 * durSec) / 8 / 1_048_576
        let est720 = Double(settings.preset720.videoBitrateKbps * 1000 * durSec) / 8 / 1_048_576

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
          360p (~\(settings.preset360.videoBitrateKbps) kbps) : ~\(String(format: "%.2f", est360)) MB
          720p (~\(settings.preset720.videoBitrateKbps) kbps) : ~\(String(format: "%.2f", est720)) MB
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
            let code = await ProcessRunner.live(ffmpeg, args: args, onLog: logSink,
                                                register: { currentProcess = $0 })
            currentProcess = nil
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

    // ---- encode (Standard-Pipeline, mit Progress-Parsing) ----------------

    private func resolveAudioCodec() async -> String {
        switch settings.audioCodec {
        case .nativeAAC:
            return "aac"
        case .fdkAAC:
            if await !Tools.hasEncoder("libfdk_aac") {
                append("⚠  libfdk_aac ist in diesem ffmpeg-Build nicht enthalten – die Transkodierung wird vermutlich fehlschlagen.\n")
            }
            return "libfdk_aac"
        case .auto:
            if await Tools.hasEncoder("libfdk_aac") { return "libfdk_aac" }
            return "aac"
        }
    }

    private func runEncode(_ input: URL, presets: [TranscodePreset], stepCount: Int, stepIndex: Int) async {
        guard let ffmpeg = Tools.locate("ffmpeg") else {
            append("❌  ffmpeg nicht gefunden.\n"); return
        }
        sep(); append("ℹ  Starte Transkodierung von: \(input.lastPathComponent)\n")

        let probe = await probeVideo(input)
        if probe.duration <= 0 { append("⚠  Dauer unbekannt – Fortschritt indeterminate.\n") }

        let deinterlace: Bool
        switch settings.deinterlace {
        case .off:    deinterlace = false
        case .always: deinterlace = true
        case .auto:   deinterlace = probe.isInterlaced
        }
        if deinterlace {
            append("ℹ  Deinterlacing aktiv (yadif).\n")
        }

        let audioCodec = await resolveAudioCodec()
        append("ℹ  Audio-Codec: \(audioCodec)\n")

        for (qIdx, preset) in presets.enumerated() {
            if cancelled { break }
            let outFile = outputPath(for: input, suffix: "\(preset.suffix).mp4")

            sep(); append("ℹ  Transkodiere → \(preset.name) (\(preset.scaleDescription)) …\n")
            statusText = "Transkodiere \(preset.name) · 0 %"

            var args = preset.coreArguments(input: input.path,
                                            deinterlace: deinterlace,
                                            audioCodec: audioCodec)
            args += ["-nostats", "-loglevel", "error", "-progress", "pipe:1", outFile]
            append("$ ffmpeg \(args.joined(separator: " "))\n")

            let name = preset.name
            let presetCount = presets.count
            let code = await ProcessRunner.ffmpegProgress(
                ffmpeg, args: args, duration: probe.duration,
                onProgress: { [weak self] pct in
                    Task { @MainActor in
                        guard let self else { return }
                        self.statusText = "Transkodiere \(name) · \(Int(pct * 100)) %"
                        let innerStage = Double(qIdx) / Double(presetCount) + (pct / Double(presetCount))
                        self.updateStepProgress(stepIndex: stepIndex, stepCount: stepCount, inner: innerStage)
                    }
                },
                onStderr: logSink,
                register: { currentProcess = $0 }
            )
            currentProcess = nil
            if code == 0 {
                append("✓  Fertig → \(outFile)\n")
            } else if cancelled {
                append("⛔  \(preset.name) abgebrochen\n")
                // Unvollständige Datei aufräumen
                try? FileManager.default.removeItem(atPath: outFile)
                break
            } else {
                append("❌  Transkodierung (\(preset.name)) exit \(code)\n")
            }
            updateStepProgress(
                stepIndex: stepIndex, stepCount: stepCount,
                inner: Double(qIdx + 1) / Double(presets.count)
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
}
