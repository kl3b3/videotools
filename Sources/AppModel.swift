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
        didSet { store.save(settings) }
    }

    private let store: PresetStore
    private var currentProcess: Process?
    private var cancelled = false

    private static let targetFolderKey = "VideoTools.targetFolder"

    init() {
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

        if mode.usesPreset, settings.selectedPreset == nil {
            append("❌  Kein aktives Transcoding-Preset. In den Einstellungen (⌘,) ein Preset aktivieren.\n")
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
        append(report + "\n")

        let outTxt = outputPath(for: input, fileName: "\(baseName(of: input))_metadata.txt")
        do {
            try report.write(toFile: outTxt, atomically: true, encoding: .utf8)
            append("✓  Metadaten gespeichert → \(outTxt)\n")
        } catch {
            append("❌  Konnte Metadaten-Datei nicht schreiben: \(error.localizedDescription)\n")
        }
        updateStepProgress(stepIndex: stepIndex, stepCount: stepCount, inner: 1)
    }

    // ---- still ----------------------------------------------------------

    private func runStill(_ input: URL, atSecond: Int, stepCount: Int, stepIndex: Int) async {
        guard let ffmpeg = Tools.locate("ffmpeg") else {
            append("❌  ffmpeg nicht gefunden.\n"); return
        }
        // Bei sehr kurzen Clips läge der Zeitpunkt hinter dem letzten Frame.
        var at = Double(atSecond)
        let duration = (await probeVideo(input)).duration
        if duration > 0, at >= duration { at = duration / 2 }
        sep(); append("ℹ  Extrahiere Stills bei \(String(format: "%.1f", at))s …\n")
        let sizes: [(String, String)] = [
            ("small",  "320:180"),
            ("medium", "640:360"),
            ("large",  "1280:720")
        ]
        for (idx, (label, size)) in sizes.enumerated() {
            if cancelled { break }
            statusText = "Still \(label)"
            let outPath = outputPath(for: input, fileName: "\(baseName(of: input))_still_\(label).jpg")
            let args = [
                "-ss", String(format: "%.2f", at), "-i", input.path,
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

    // ---- encode (Preset mit Renditions, mit Progress-Parsing) ------------

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

    private func runEncode(_ input: URL, preset: TranscodePreset, stepCount: Int, stepIndex: Int) async {
        guard let ffmpeg = Tools.locate("ffmpeg") else {
            append("❌  ffmpeg nicht gefunden.\n"); return
        }
        guard !preset.renditions.isEmpty else {
            append("⚠  Preset „\(preset.label)“ hat keine Renditions – nichts zu tun.\n")
            return
        }
        sep(); append("ℹ  Starte Transkodierung: \(input.lastPathComponent)\n")
        append("ℹ  Preset: \(preset.label)\n")

        let probe = await probeVideo(input)
        if probe.duration <= 0 { append("⚠  Dauer unbekannt – Fortschritt indeterminate.\n") }

        let hasVideoRenditions = preset.renditions.contains { $0.container == .mp4 }

        var deinterlace = false
        if hasVideoRenditions {
            switch settings.deinterlace {
            case .off:    deinterlace = false
            case .always: deinterlace = true
            case .auto:   deinterlace = probe.isInterlaced
            }
            if deinterlace {
                append("ℹ  Deinterlacing aktiv (yadif).\n")
            }
        }

        let resolvedAudio = hasVideoRenditions ? await resolveAudioCodec() : "aac"
        if hasVideoRenditions {
            append("ℹ  Audio-Codec (MP4): \(resolvedAudio)\n")
        }

        let renditionCount = preset.renditions.count
        for (rIdx, rendition) in preset.renditions.enumerated() {
            if cancelled { break }
            let fileName = preset.outputFileName(base: baseName(of: input), rendition: rendition)
            let outFile = outputPath(for: input, fileName: fileName)

            sep()
            switch rendition.container {
            case .mp4:
                append("ℹ  Transkodiere → \(rendition.name) (\(rendition.scaleDescription)) …\n")
            case .mp3, .wav:
                append("ℹ  Extrahiere Audio → \(rendition.name) (\(rendition.container.rawValue.uppercased())) …\n")
            }
            statusText = "Transkodiere \(rendition.name) · 0 %"

            var args = rendition.coreArguments(input: input.path,
                                               deinterlace: deinterlace && rendition.container == .mp4,
                                               resolvedAudioCodec: resolvedAudio)
            args += ["-nostats", "-loglevel", "error", "-progress", "pipe:1", outFile]
            append("$ ffmpeg \(args.joined(separator: " "))\n")

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
                onStderr: logSink,
                register: { currentProcess = $0 }
            )
            currentProcess = nil
            if code == 0 {
                append("✓  Fertig → \(outFile)\n")
            } else if cancelled {
                append("⛔  \(rendition.name) abgebrochen\n")
                // Unvollständige Datei aufräumen
                try? FileManager.default.removeItem(atPath: outFile)
                break
            } else {
                append("❌  Transkodierung (\(rendition.name)) exit \(code)\n")
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

    private func sep() {
        append("/*──────────────────────────────────────────────────────*/\n")
    }

    private func hms(_ total: Int) -> String {
        String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
