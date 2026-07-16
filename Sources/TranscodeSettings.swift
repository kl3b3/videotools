import Foundation

// ============================================================================
// Transcoding-Konfiguration
//
// Standard entspricht der bewährten PHP-Pipeline:
//   ffmpeg -y -i IN -codec:v libx264 -vf scale=… -b:v … -maxrate … -bufsize …
//     [yadif] -crf 20 -x264opts keyint=25:min-keyint=25 -profile:v main
//     -threads 0 -preset veryfast -codec:a libfdk_aac -b:a 128k -ar 44100
//     -ac 2 -movflags faststart OUT
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

struct TranscodePreset: Codable, Equatable {
    var name: String
    /// Wird an den Dateinamen angehängt: <basename><suffix>.mp4
    var suffix: String
    var width: Int
    var height: Int
    var videoBitrateKbps: Int
    var maxrateKbps: Int
    var bufsizeKbps: Int
    var crf: Int
    var keyint: Int
    var profile: String
    var speedPreset: String
    var audioBitrateKbps: Int
    var audioSampleRate: Int
    var audioChannels: Int

    static let default360 = TranscodePreset(
        name: "360p", suffix: "_T",
        width: 640, height: 360,
        videoBitrateKbps: 1000, maxrateKbps: 1000, bufsizeKbps: 3000,
        crf: 20, keyint: 25, profile: "main", speedPreset: "veryfast",
        audioBitrateKbps: 128, audioSampleRate: 44100, audioChannels: 2
    )

    static let default720 = TranscodePreset(
        name: "720p", suffix: "_T-720p",
        width: 1280, height: 720,
        videoBitrateKbps: 5000, maxrateKbps: 5000, bufsizeKbps: 15000,
        crf: 20, keyint: 25, profile: "main", speedPreset: "veryfast",
        audioBitrateKbps: 128, audioSampleRate: 44100, audioChannels: 2
    )

    static let x264SpeedPresets = [
        "ultrafast", "superfast", "veryfast", "faster", "fast",
        "medium", "slow", "slower", "veryslow"
    ]
    static let x264Profiles = ["baseline", "main", "high"]

    var scaleDescription: String { "\(width):\(height)" }

    /// ffmpeg-Argumente ohne Ausgabedatei und ohne Progress-/Log-Plumbing.
    func coreArguments(input: String, deinterlace: Bool, audioCodec: String) -> [String] {
        var filters: [String] = []
        if deinterlace { filters.append("yadif") }
        filters.append("scale=\(width):\(height)")
        // 4:2:0 erzwingen: profile main/baseline können kein 4:2:2/4:4:4
        // (z.B. Screen-Recordings), und Player erwarten ohnehin yuv420p.
        filters.append("format=yuv420p")
        return [
            "-y", "-i", input,
            "-codec:v", "libx264",
            "-vf", filters.joined(separator: ","),
            "-b:v", "\(videoBitrateKbps)k",
            "-maxrate", "\(maxrateKbps)k",
            "-bufsize", "\(bufsizeKbps)k",
            "-crf", "\(crf)",
            "-x264opts", "keyint=\(keyint):min-keyint=\(keyint)",
            "-profile:v", profile,
            "-threads", "0",
            "-preset", speedPreset,
            "-codec:a", audioCodec,
            "-b:a", "\(audioBitrateKbps)k",
            "-ar", "\(audioSampleRate)",
            "-ac", "\(audioChannels)",
            "-movflags", "faststart",
        ]
    }

    func previewCommand(deinterlace: Bool, audioCodec: String) -> String {
        let args = coreArguments(input: "eingabe.mp4",
                                 deinterlace: deinterlace,
                                 audioCodec: audioCodec)
        return (["ffmpeg"] + args + ["ausgabe\(suffix).mp4"]).joined(separator: " ")
    }
}

struct TranscodeSettings: Codable, Equatable {
    var preset360: TranscodePreset = .default360
    var preset720: TranscodePreset = .default720
    var deinterlace: DeinterlaceMode = .auto
    var audioCodec: AudioCodecChoice = .auto

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
