import Foundation

// ============================================================================
// Transcoding-Konfiguration
//
// Ein Preset bündelt mehrere Renditions (z.B. 1080p + 720p-Vorschau), die
// beim Transkodieren alle erzeugt werden. Die eingebauten Presets entsprechen
// der Pflege-JSON des API-Servers (1080p Web / 1080p Master / Alt / Audio).
//
// rateControl:
//   cbr        -> -b:v/-maxrate/-bufsize, KEIN -crf. Zielbitrate wird geliefert.
//   capped-crf -> -crf plus -maxrate/-bufsize als Deckel (Verhalten des alten
//                 PHP-Workers: er übergab beides, bei libx264 gewinnt CRF).
//   crf        -> nur -crf, kein Deckel.
//
// Dateiname: <basename><baseSuffix><renditionSuffix>.<ext>
//   baseSuffix "_T" + Suffix ""      -> clip_T.mp4
//   baseSuffix "_T" + Suffix "-720p" -> clip_T-720p.mp4
//   baseSuffix ""   + Suffix "_MP3"  -> clip_MP3.mp3
// ============================================================================

enum DeinterlaceMode: String, Codable, CaseIterable, Identifiable {
    case auto, off, always
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto:   return "Automatisch (per ffprobe erkennen)"
        case .off:    return "Aus"
        case .always: return "Immer (yadif)"
        }
    }
}

enum AudioCodecChoice: String, Codable, CaseIterable, Identifiable {
    case auto, fdkAAC, nativeAAC
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto:      return "Automatisch (libfdk_aac, sonst aac)"
        case .fdkAAC:    return "libfdk_aac"
        case .nativeAAC: return "aac (nativ)"
        }
    }
}

enum MediaType: String, Codable, CaseIterable, Identifiable {
    case video, audio
    var id: String { rawValue }
    var label: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        }
    }
}

enum RateControl: String, Codable, CaseIterable, Identifiable {
    case cbr = "cbr"
    case cappedCRF = "capped-crf"
    case crf = "crf"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cbr:       return "CBR (feste Bitrate)"
        case .cappedCRF: return "Capped CRF (Qualität mit Bitraten-Deckel)"
        case .crf:       return "CRF (nur Qualität)"
        }
    }
}

enum OutputContainer: String, Codable, CaseIterable, Identifiable {
    case mp4, mp3, wav
    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var label: String {
        switch self {
        case .mp4: return "MP4 (H.264 + AAC)"
        case .mp3: return "MP3 (nur Audio)"
        case .wav: return "WAV (nur Audio)"
        }
    }
}

// ============================================================================
// Rendition: eine einzelne Ausgabedatei innerhalb eines Presets
// ============================================================================

struct Rendition: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// Wird hinter den Basissuffix des Presets gehängt, z.B. "-720p".
    var filenameSuffix: String
    var container: OutputContainer

    // Video (nur bei container == .mp4 relevant)
    var width: Int
    var height: Int
    var rateControl: RateControl
    var videoBitrateKbps: Int
    var maxrateKbps: Int
    var bufsizeKbps: Int
    var crf: Int
    var keyint: Int
    var profile: String
    var speedPreset: String

    // Audio. `audioCodec` nil = globale Einstellung (libfdk_aac/aac);
    // bei MP3/WAV-Renditions explizit gesetzt (libmp3lame/pcm_s16le).
    var audioCodec: String?
    var audioBitrateKbps: Int
    var audioSampleRate: Int
    var audioChannels: Int

    init(
        id: UUID = UUID(),
        name: String,
        filenameSuffix: String,
        container: OutputContainer = .mp4,
        width: Int = 1280,
        height: Int = 720,
        rateControl: RateControl = .cappedCRF,
        videoBitrateKbps: Int = 4500,
        maxrateKbps: Int = 5000,
        bufsizeKbps: Int = 15000,
        crf: Int = 20,
        keyint: Int = 25,
        profile: String = "main",
        speedPreset: String = "veryfast",
        audioCodec: String? = nil,
        audioBitrateKbps: Int = 128,
        audioSampleRate: Int = 44100,
        audioChannels: Int = 2
    ) {
        self.id = id
        self.name = name
        self.filenameSuffix = filenameSuffix
        self.container = container
        self.width = width
        self.height = height
        self.rateControl = rateControl
        self.videoBitrateKbps = videoBitrateKbps
        self.maxrateKbps = maxrateKbps
        self.bufsizeKbps = bufsizeKbps
        self.crf = crf
        self.keyint = keyint
        self.profile = profile
        self.speedPreset = speedPreset
        self.audioCodec = audioCodec
        self.audioBitrateKbps = audioBitrateKbps
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
    }

    static let x264SpeedPresets = [
        "ultrafast", "superfast", "veryfast", "faster", "fast",
        "medium", "slow", "slower", "veryslow"
    ]
    static let x264Profiles = ["baseline", "main", "high"]

    var scaleDescription: String { "\(width):\(height)" }

    /// Maßgebliche Videobitrate (kbit/s) für Größenschätzungen.
    var nominalVideoBitrateKbps: Int? {
        guard container == .mp4 else { return nil }
        switch rateControl {
        case .cbr:              return videoBitrateKbps
        case .cappedCRF, .crf:  return maxrateKbps
        }
    }

    /// Grobe Gesamtbitrate (kbit/s) für Dateigrößen-Schätzungen.
    var estimatedBitrateKbps: Int {
        switch container {
        case .mp4: return (nominalVideoBitrateKbps ?? 0) + audioBitrateKbps
        case .mp3: return audioBitrateKbps
        case .wav: return audioSampleRate * 16 * audioChannels / 1000
        }
    }

    /// ffmpeg-Argumente ohne Ausgabedatei und ohne Progress-/Log-Plumbing.
    func coreArguments(input: String, deinterlace: Bool, resolvedAudioCodec: String) -> [String] {
        switch container {
        case .mp3:
            return [
                "-y", "-i", input,
                "-vn",
                "-codec:a", audioCodec ?? "libmp3lame",
                "-b:a", "\(audioBitrateKbps)k",
                "-ar", "\(audioSampleRate)",
                "-ac", "\(audioChannels)",
            ]
        case .wav:
            // PCM hat keine einstellbare Bitrate — sie ergibt sich aus
            // Samplerate × Bittiefe × Kanälen.
            return [
                "-y", "-i", input,
                "-vn",
                "-codec:a", audioCodec ?? "pcm_s16le",
                "-ar", "\(audioSampleRate)",
                "-ac", "\(audioChannels)",
            ]
        case .mp4:
            var filters: [String] = []
            if deinterlace { filters.append("yadif") }
            filters.append("scale=\(width):\(height)")
            // 4:2:0 erzwingen: profile main/baseline können kein 4:2:2/4:4:4
            // (z.B. Screen-Recordings), und Player erwarten ohnehin yuv420p.
            filters.append("format=yuv420p")

            var args: [String] = [
                "-y", "-i", input,
                "-codec:v", "libx264",
                "-vf", filters.joined(separator: ","),
            ]
            switch rateControl {
            case .cbr:
                args += [
                    "-b:v", "\(videoBitrateKbps)k",
                    "-maxrate", "\(maxrateKbps)k",
                    "-bufsize", "\(bufsizeKbps)k",
                ]
            case .cappedCRF:
                args += [
                    "-crf", "\(crf)",
                    "-maxrate", "\(maxrateKbps)k",
                    "-bufsize", "\(bufsizeKbps)k",
                ]
            case .crf:
                args += ["-crf", "\(crf)"]
            }
            args += [
                "-x264opts", "keyint=\(keyint):min-keyint=\(keyint)",
                "-profile:v", profile,
                "-threads", "0",
                "-preset", speedPreset,
                "-codec:a", audioCodec ?? resolvedAudioCodec,
                "-b:a", "\(audioBitrateKbps)k",
                "-ar", "\(audioSampleRate)",
                "-ac", "\(audioChannels)",
                "-movflags", "faststart",
            ]
            return args
        }
    }
}

// ============================================================================
// Preset: benannte Sammlung von Renditions
// ============================================================================

struct TranscodePreset: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var details: String
    var mediaType: MediaType
    /// Eingebaute Presets können deaktiviert, aber nicht gelöscht werden.
    var isBuiltin: Bool
    /// Inaktive Presets erscheinen nicht in der Preset-Auswahl.
    var isActive: Bool
    var sortOrder: Int
    /// Gemeinsamer Namensbestandteil aller Renditions, z.B. "_T".
    var baseSuffix: String
    var renditions: [Rendition]

    func outputFileName(base: String, rendition: Rendition) -> String {
        "\(base)\(baseSuffix)\(rendition.filenameSuffix).\(rendition.container.fileExtension)"
    }

    /// Namensschlüssel einer Rendition (Suffix + Endung) – identischer Schlüssel
    /// innerhalb eines Presets bedeutet: gleiche Ausgabedatei.
    func outputKey(_ rendition: Rendition) -> String {
        "\(baseSuffix)\(rendition.filenameSuffix).\(rendition.container.fileExtension)"
    }

    /// Namensschlüssel, die mehrfach vorkommen – die spätere Rendition würde
    /// die frühere überschreiben.
    var duplicateOutputKeys: Set<String> {
        var seen: Set<String> = []
        var duplicates: Set<String> = []
        for r in renditions {
            let key = outputKey(r)
            if !seen.insert(key).inserted { duplicates.insert(key) }
        }
        return duplicates
    }

    // -------------------------------------------------------------------
    // Eingebaute Presets (Stand: Pflege-JSON des API-Servers)
    // -------------------------------------------------------------------

    static let webID    = "1080p-web"
    static let masterID = "1080p-master"
    static let legacyID = "legacy-360-720"
    static let audioID  = "audio-standard"

    /// Start-Auswahl beim ersten App-Start (`is_default` der Pflege-JSON).
    static let defaultID = webID

    static var builtins: [TranscodePreset] {
        [
            TranscodePreset(
                id: webID,
                label: "1080p Web (4,5 Mbit)",
                details: "Standard-Upload: 1080p mit 4.500 kbit/s plus 720p-Vorschau.",
                mediaType: .video,
                isBuiltin: true, isActive: true, sortOrder: 10,
                baseSuffix: "_T",
                renditions: [
                    Rendition(name: "1080p", filenameSuffix: "",
                              width: 1920, height: 1080,
                              rateControl: .cbr,
                              videoBitrateKbps: 4500, maxrateKbps: 4500, bufsizeKbps: 9000),
                    preview720,
                ]
            ),
            TranscodePreset(
                id: masterID,
                label: "1080p Master (16 Mbit)",
                details: "Hohe Qualität: 1080p mit 16.000 kbit/s plus 720p-Vorschau.",
                mediaType: .video,
                isBuiltin: true, isActive: true, sortOrder: 20,
                baseSuffix: "_T",
                renditions: [
                    Rendition(name: "1080p", filenameSuffix: "",
                              width: 1920, height: 1080,
                              rateControl: .cbr,
                              videoBitrateKbps: 16000, maxrateKbps: 16000, bufsizeKbps: 32000,
                              profile: "high"),
                    preview720,
                ]
            ),
            TranscodePreset(
                id: legacyID,
                label: "Alt: 360p + 720p",
                details: "Die Werte aus dem alten PHP-Skript. Als Rückfallebene aufbewahrt, standardmäßig inaktiv.",
                mediaType: .video,
                isBuiltin: true, isActive: false, sortOrder: 90,
                baseSuffix: "_T",
                renditions: [
                    Rendition(name: "360p", filenameSuffix: "",
                              width: 640, height: 360,
                              rateControl: .cappedCRF,
                              maxrateKbps: 1000, bufsizeKbps: 3000),
                    preview720,
                ]
            ),
            TranscodePreset(
                id: audioID,
                label: "Audio: MP3 + WAV",
                details: "Standard-Audioausgabe, entspricht den bisher fest verdrahteten Formaten.",
                mediaType: .audio,
                isBuiltin: true, isActive: true, sortOrder: 40,
                baseSuffix: "",
                renditions: [
                    Rendition(name: "mp3", filenameSuffix: "_MP3", container: .mp3,
                              audioCodec: "libmp3lame", audioBitrateKbps: 128),
                    Rendition(name: "wav", filenameSuffix: "_WAV", container: .wav,
                              audioCodec: "pcm_s16le"),
                ]
            ),
        ]
    }

    /// 720p-Vorschau, wie sie in allen Video-Presets der Pflege-JSON steckt.
    private static var preview720: Rendition {
        Rendition(name: "720p", filenameSuffix: "-720p",
                  width: 1280, height: 720,
                  rateControl: .cappedCRF,
                  maxrateKbps: 5000, bufsizeKbps: 15000, crf: 20)
    }

    static func builtin(_ id: String) -> TranscodePreset? {
        builtins.first { $0.id == id }
    }

    static func newCustom(sortOrder: Int) -> TranscodePreset {
        TranscodePreset(
            id: "custom-\(UUID().uuidString)",
            label: "Neues Preset",
            details: "",
            mediaType: .video,
            isBuiltin: false, isActive: true, sortOrder: sortOrder,
            baseSuffix: "_T",
            renditions: [preview720]
        )
    }
}

// ============================================================================
// Gesamteinstellungen (persistiert als JSON in UserDefaults)
// ============================================================================

struct TranscodeSettings: Codable, Equatable {
    var presets: [TranscodePreset] = TranscodePreset.builtins
    var selectedPresetID: String = TranscodePreset.defaultID
    var deinterlace: DeinterlaceMode = .auto
    var audioCodec: AudioCodecChoice = .auto

    /// Maximal so viele eigene Presets zusätzlich zu den eingebauten.
    static let maxCustomPresets = 5
    /// Renditions pro Preset.
    static let maxRenditions = 4

    var customPresetCount: Int { presets.filter { !$0.isBuiltin }.count }
    var canAddPreset: Bool { customPresetCount < Self.maxCustomPresets }

    var sortedPresets: [TranscodePreset] {
        presets.sorted { ($0.sortOrder, $0.label) < ($1.sortOrder, $1.label) }
    }

    var activePresets: [TranscodePreset] {
        sortedPresets.filter(\.isActive)
    }

    /// Das aktuell gewählte Preset; fällt auf das erste aktive zurück.
    var selectedPreset: TranscodePreset? {
        if let p = presets.first(where: { $0.id == selectedPresetID && $0.isActive }) {
            return p
        }
        return activePresets.first
    }

    private static let defaultsKey = "VideoTools.transcodeSettings"

    static func load() -> TranscodeSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(TranscodeSettings.self, from: data)
        else { return TranscodeSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
