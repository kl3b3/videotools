import SwiftUI

// ============================================================================
// Einstellungen (⌘,): Allgemein + Preset-Verwaltung
//
// Eingebaute Presets lassen sich bearbeiten, deaktivieren und zurücksetzen,
// aber nicht löschen. Bis zu 5 eigene Presets können angelegt werden.
// ============================================================================

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
            PresetManagerView()
                .tabItem { Label("Presets", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 780, height: 640)
    }
}

// ============================================================================
// Allgemein
// ============================================================================

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
                Picker("Audio-Codec (MP4)", selection: $model.settings.audioCodec) {
                    ForEach(AudioCodecChoice.allCases) { c in Text(c.label).tag(c) }
                }
                if let hasFdkAAC {
                    LabeledContent("libfdk_aac verfügbar") {
                        Image(systemName: hasFdkAAC ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(hasFdkAAC ? .green : .orange)
                    }
                }
            } footer: {
                Text("libfdk_aac liefert die beste AAC-Qualität, ist aber nicht in jedem ffmpeg-Build enthalten. „Automatisch“ fällt auf den nativen aac-Encoder zurück. MP3/WAV-Renditions nutzen ihre eigenen Codecs.")
            }

            Section {
                Button("Alle Einstellungen auf Standard zurücksetzen") {
                    model.settings = TranscodeSettings()
                }
            } footer: {
                Text("Entfernt eigene Presets und stellt die eingebauten Presets wieder her.")
            }
        }
        .formStyle(.grouped)
        .task { hasFdkAAC = await Tools.hasEncoder("libfdk_aac") }
    }
}

// ============================================================================
// Preset-Verwaltung: Liste links, Editor rechts
// ============================================================================

private struct PresetManagerView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedID: String?

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(model.settings.sortedPresets) { preset in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(preset.isActive ? Color.green : Color.gray.opacity(0.5))
                                .frame(width: 7, height: 7)
                            Text(preset.label)
                                .lineLimit(1)
                            Spacer()
                            if preset.isBuiltin {
                                Image(systemName: "lock.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .help("Eingebautes Preset – kann deaktiviert, aber nicht gelöscht werden")
                            }
                        }
                        .tag(preset.id)
                    }
                }
                .listStyle(.sidebar)

                Divider()
                HStack(spacing: 12) {
                    Button {
                        addPreset()
                    } label: { Image(systemName: "plus") }
                    .disabled(!model.settings.canAddPreset)
                    .help(model.settings.canAddPreset
                          ? "Eigenes Preset hinzufügen"
                          : "Maximal \(TranscodeSettings.maxCustomPresets) eigene Presets")

                    Button {
                        deleteSelected()
                    } label: { Image(systemName: "minus") }
                    .disabled(!canDeleteSelected)
                    .help("Ausgewähltes Preset löschen (nur eigene Presets)")

                    Spacer()
                    Text("\(model.settings.customPresetCount)/\(TranscodeSettings.maxCustomPresets) eigene")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(width: 220)

            Divider()

            if let index = model.settings.presets.firstIndex(where: { $0.id == selectedID }) {
                PresetEditorView(
                    preset: $model.settings.presets[index],
                    generalSettings: model.settings
                )
                .id(selectedID)
            } else {
                ContentUnavailableView(
                    "Kein Preset ausgewählt",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Links ein Preset auswählen oder mit „+“ ein neues anlegen.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = model.settings.selectedPreset?.id }
        }
    }

    private var canDeleteSelected: Bool {
        guard let p = model.settings.presets.first(where: { $0.id == selectedID }) else { return false }
        return !p.isBuiltin
    }

    private func addPreset() {
        let maxSort = model.settings.presets.map(\.sortOrder).max() ?? 0
        let preset = TranscodePreset.newCustom(sortOrder: min(maxSort + 10, 80))
        model.settings.presets.append(preset)
        selectedID = preset.id
    }

    private func deleteSelected() {
        guard let id = selectedID,
              let p = model.settings.presets.first(where: { $0.id == id }),
              !p.isBuiltin else { return }
        model.settings.presets.removeAll { $0.id == id }
        selectedID = model.settings.sortedPresets.first?.id
    }
}

// ============================================================================
// Preset-Editor
// ============================================================================

private struct PresetEditorView: View {
    @Binding var preset: TranscodePreset
    let generalSettings: TranscodeSettings

    var body: some View {
        Form {
            Section("Preset") {
                TextField("Name", text: $preset.label)
                TextField("Beschreibung", text: $preset.details, axis: .vertical)
                    .lineLimit(1...3)
                Toggle("Aktiv (im Preset-Menü sichtbar)", isOn: $preset.isActive)
                if preset.isBuiltin {
                    LabeledContent("Typ", value: preset.mediaType.label)
                } else {
                    Picker("Typ", selection: $preset.mediaType) {
                        ForEach(MediaType.allCases) { t in Text(t.label).tag(t) }
                    }
                }
            }

            Section {
                TextField("Basissuffix", text: $preset.baseSuffix)
                    .font(.system(.body, design: .monospaced))
                ForEach(preset.renditions) { r in
                    LabeledContent(r.name) {
                        Text(preset.outputFileName(base: "clip", rendition: r))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Dateinamen")
            } footer: {
                Text("Ausgabename = <Dateiname><Basissuffix><Rendition-Suffix>.<Endung>")
            }

            Section {
                ForEach($preset.renditions) { $rendition in
                    DisclosureGroup {
                        RenditionEditorView(
                            rendition: $rendition,
                            mediaType: preset.mediaType,
                            generalSettings: generalSettings
                        )
                        if preset.renditions.count > 1 {
                            Button(role: .destructive) {
                                preset.renditions.removeAll { $0.id == rendition.id }
                            } label: {
                                Label("Rendition entfernen", systemImage: "trash")
                            }
                        }
                    } label: {
                        HStack {
                            Text(rendition.name).fontWeight(.medium)
                            Spacer()
                            Text(renditionSummary(rendition))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button {
                    addRendition()
                } label: {
                    Label("Rendition hinzufügen", systemImage: "plus")
                }
                .disabled(preset.renditions.count >= TranscodeSettings.maxRenditions)
            } header: {
                Text("Renditions (\(preset.renditions.count)/\(TranscodeSettings.maxRenditions))")
            } footer: {
                Text("Jede Rendition erzeugt eine eigene Ausgabedatei.")
            }

            if preset.isBuiltin, let original = TranscodePreset.builtin(preset.id) {
                Section {
                    Button("Auf eingebauten Standard zurücksetzen") {
                        var restored = original
                        restored.isActive = preset.isActive
                        preset = restored
                    }
                    .disabled(presetEqualsIgnoringActive(original))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func renditionSummary(_ r: Rendition) -> String {
        switch r.container {
        case .mp4:
            switch r.rateControl {
            case .cbr:       return "\(r.width)×\(r.height) · CBR \(r.videoBitrateKbps)k"
            case .cappedCRF: return "\(r.width)×\(r.height) · CRF \(r.crf) ≤ \(r.maxrateKbps)k"
            case .crf:       return "\(r.width)×\(r.height) · CRF \(r.crf)"
            }
        case .mp3: return "MP3 · \(r.audioBitrateKbps)k"
        case .wav: return "WAV · \(r.audioSampleRate / 1000) kHz"
        }
    }

    private func addRendition() {
        let rendition: Rendition
        if preset.mediaType == .audio {
            rendition = Rendition(name: "mp3", filenameSuffix: "_MP3", container: .mp3,
                                  audioCodec: "libmp3lame")
        } else {
            rendition = Rendition(name: "Neu", filenameSuffix: "-neu")
        }
        preset.renditions.append(rendition)
    }

    private func presetEqualsIgnoringActive(_ original: TranscodePreset) -> Bool {
        var a = preset; var b = original
        b.isActive = a.isActive
        // Rendition-IDs sind laufzeitgeneriert und für den Vergleich egal.
        a.renditions = a.renditions.map { r in var c = r; c.id = UUID(uuid: UUID_NULL); return c }
        b.renditions = b.renditions.map { r in var c = r; c.id = UUID(uuid: UUID_NULL); return c }
        return a == b
    }
}

// ============================================================================
// Rendition-Editor
// ============================================================================

private struct RenditionEditorView: View {
    @Binding var rendition: Rendition
    let mediaType: MediaType
    let generalSettings: TranscodeSettings

    var body: some View {
        Group {
            TextField("Name", text: $rendition.name)
            TextField("Dateisuffix", text: $rendition.filenameSuffix)
                .font(.system(.body, design: .monospaced))
            Picker("Format", selection: $rendition.container) {
                ForEach(OutputContainer.allCases) { c in Text(c.label).tag(c) }
            }
            .onChange(of: rendition.container) { _, newValue in
                // Codec passend zum Format setzen; MP4 nutzt die globale Wahl.
                switch newValue {
                case .mp4: rendition.audioCodec = nil
                case .mp3: rendition.audioCodec = "libmp3lame"
                case .wav: rendition.audioCodec = "pcm_s16le"
                }
            }

            if rendition.container == .mp4 {
                TextField("Breite (px)", value: $rendition.width, format: .number.grouping(.never))
                TextField("Höhe (px)", value: $rendition.height, format: .number.grouping(.never))

                Picker("Rate-Control", selection: $rendition.rateControl) {
                    ForEach(RateControl.allCases) { rc in Text(rc.label).tag(rc) }
                }
                switch rendition.rateControl {
                case .cbr:
                    TextField("Bitrate (kbit/s)", value: $rendition.videoBitrateKbps, format: .number.grouping(.never))
                    TextField("Maxrate (kbit/s)", value: $rendition.maxrateKbps, format: .number.grouping(.never))
                    TextField("Bufsize (kbit/s)", value: $rendition.bufsizeKbps, format: .number.grouping(.never))
                case .cappedCRF:
                    Stepper("CRF: \(rendition.crf)", value: $rendition.crf, in: 0...51)
                    TextField("Maxrate (kbit/s)", value: $rendition.maxrateKbps, format: .number.grouping(.never))
                    TextField("Bufsize (kbit/s)", value: $rendition.bufsizeKbps, format: .number.grouping(.never))
                case .crf:
                    Stepper("CRF: \(rendition.crf)", value: $rendition.crf, in: 0...51)
                }

                Stepper("Keyframe-Intervall: \(rendition.keyint)", value: $rendition.keyint, in: 1...300)
                Picker("Profil", selection: $rendition.profile) {
                    ForEach(Rendition.x264Profiles, id: \.self) { Text($0) }
                }
                Picker("Encoder-Preset", selection: $rendition.speedPreset) {
                    ForEach(Rendition.x264SpeedPresets, id: \.self) { Text($0) }
                }
            }

            if rendition.container != .wav {
                TextField("Audio-Bitrate (kbit/s)", value: $rendition.audioBitrateKbps, format: .number.grouping(.never))
            }
            Picker("Samplerate", selection: $rendition.audioSampleRate) {
                Text("44,1 kHz").tag(44100)
                Text("48 kHz").tag(48000)
            }
            Stepper("Kanäle: \(rendition.audioChannels)", value: $rendition.audioChannels, in: 1...2)

            DisclosureGroup("Befehl (Vorschau)") {
                Text(previewCommand)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var previewCommand: String {
        let audio: String
        switch generalSettings.audioCodec {
        case .nativeAAC:     audio = "aac"
        case .fdkAAC, .auto: audio = "libfdk_aac"
        }
        let args = rendition.coreArguments(
            input: "eingabe.mp4",
            deinterlace: generalSettings.deinterlace == .always && rendition.container == .mp4,
            resolvedAudioCodec: audio
        )
        let out = "ausgabe\(rendition.filenameSuffix).\(rendition.container.fileExtension)"
        return (["ffmpeg"] + args + [out]).joined(separator: " ")
    }
}
