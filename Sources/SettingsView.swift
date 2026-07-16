import SwiftUI

// ============================================================================
// Einstellungen (⌘,): Allgemein + editierbare Transcoding-Presets
// ============================================================================

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
            PresetSettingsView(preset: $model.settings.preset360,
                               defaults: .default360,
                               generalSettings: model.settings)
                .tabItem { Label("360p", systemImage: "rectangle.compress.vertical") }
            PresetSettingsView(preset: $model.settings.preset720,
                               defaults: .default720,
                               generalSettings: model.settings)
                .tabItem { Label("720p", systemImage: "rectangle.expand.vertical") }
        }
        .frame(width: 560, height: 620)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var hasFdkAAC: Bool?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Deinterlacing", selection: $model.settings.deinterlace) {
                    ForEach(DeinterlaceMode.allCases) { m in Text(m.label).tag(m) }
                }
            } footer: {
                Text("Bei „Automatisch“ wird der Scan-Typ der Quelle per ffprobe ermittelt; interlaced Material wird mit yadif deinterlaced.")
            }

            Section {
                Picker("Audio-Codec", selection: $model.settings.audioCodec) {
                    ForEach(AudioCodecChoice.allCases) { c in Text(c.label).tag(c) }
                }
                if let hasFdkAAC {
                    LabeledContent("libfdk_aac verfügbar") {
                        Image(systemName: hasFdkAAC ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(hasFdkAAC ? .green : .orange)
                    }
                }
            } footer: {
                Text("libfdk_aac liefert die beste AAC-Qualität, ist aber nicht in jedem ffmpeg-Build enthalten. „Automatisch“ fällt auf den nativen aac-Encoder zurück.")
            }

            Section {
                Button("Alle Einstellungen auf Standard zurücksetzen") {
                    model.settings = TranscodeSettings()
                }
            }
        }
        .formStyle(.grouped)
        .task { hasFdkAAC = await Tools.hasEncoder("libfdk_aac") }
    }
}

private struct PresetSettingsView: View {
    @Binding var preset: TranscodePreset
    let defaults: TranscodePreset
    let generalSettings: TranscodeSettings

    var body: some View {
        Form {
            Section("Video") {
                TextField("Breite (px)", value: $preset.width, format: .number.grouping(.never))
                TextField("Höhe (px)", value: $preset.height, format: .number.grouping(.never))
                TextField("Bitrate (kbit/s)", value: $preset.videoBitrateKbps, format: .number.grouping(.never))
                TextField("Maxrate (kbit/s)", value: $preset.maxrateKbps, format: .number.grouping(.never))
                TextField("Bufsize (kbit/s)", value: $preset.bufsizeKbps, format: .number.grouping(.never))
                Stepper("CRF: \(preset.crf)", value: $preset.crf, in: 0...51)
                Stepper("Keyframe-Intervall: \(preset.keyint)", value: $preset.keyint, in: 1...300)
                Picker("Profil", selection: $preset.profile) {
                    ForEach(TranscodePreset.x264Profiles, id: \.self) { Text($0) }
                }
                Picker("Encoder-Preset", selection: $preset.speedPreset) {
                    ForEach(TranscodePreset.x264SpeedPresets, id: \.self) { Text($0) }
                }
            }

            Section("Audio") {
                TextField("Bitrate (kbit/s)", value: $preset.audioBitrateKbps, format: .number.grouping(.never))
                Picker("Samplerate", selection: $preset.audioSampleRate) {
                    Text("44,1 kHz").tag(44100)
                    Text("48 kHz").tag(48000)
                }
                Stepper("Kanäle: \(preset.audioChannels)", value: $preset.audioChannels, in: 1...2)
            }

            Section("Ausgabe") {
                TextField("Dateisuffix", text: $preset.suffix)
                    .font(.system(.body, design: .monospaced))
            }

            Section {
                Text(previewCommand)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Befehl (Vorschau)")
            } footer: {
                if preset != defaults {
                    Button("Auf Standard zurücksetzen") { preset = defaults }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var previewCommand: String {
        let audio: String
        switch generalSettings.audioCodec {
        case .nativeAAC: audio = "aac"
        case .fdkAAC, .auto: audio = "libfdk_aac"
        }
        return preset.previewCommand(
            deinterlace: generalSettings.deinterlace == .always,
            audioCodec: audio
        )
    }
}
