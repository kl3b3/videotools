import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
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
        @Bindable var model = model
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("VideoTools").font(.title2).bold()
                Text("Metadaten · Stills · Transkodierung")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Picker("Aufgabe", selection: $model.mode) {
                    ForEach(Mode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.menu)
                if model.mode.usesPreset {
                    Picker("Preset", selection: Binding(
                        get: { model.settings.selectedPreset?.id ?? "" },
                        set: { model.settings.selectedPresetID = $0 }
                    )) {
                        ForEach(model.settings.activePresets) { p in
                            Text(p.label).tag(p.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .frame(maxWidth: 360)
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
                .disabled(model.entries.isEmpty)
            }

            Spacer()

            Button {
                NSWorkspace.shared.open(model.techLogDirectory)
            } label: {
                Label("Technisches Log", systemImage: "doc.text.magnifyingglass")
            }
            .help("Technische Logdateien im Finder öffnen (werden \(TechLog.retentionDays) Tage aufbewahrt)")

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
                if model.entries.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "text.alignleft")
                            .font(.title3)
                            .foregroundStyle(.quaternary)
                        Text("Noch keine Aktivität")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(model.entries) { entry in
                            LogRowView(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .frame(minHeight: 180)
            .onChange(of: model.entries.count) { _, _ in
                guard let last = model.entries.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            ToolStatusView()
            Spacer()
            SettingsLink {
                Label("Einstellungen", systemImage: "gearshape")
            }
            .help("Transcoding-Einstellungen (⌘,)")
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

// ============================================================================
// Eine Zeile im Fenster-Log
// ============================================================================

private struct LogRowView: View {
    let entry: LogEntry

    var body: some View {
        switch entry.kind {
        case .header: headerRow
        default:      standardRow
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "film")
                .foregroundStyle(.tint)
            Text(entry.text)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail = entry.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            timestamp
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.top, 6)
    }

    private var standardRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.callout)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.text)
                    .font(.callout)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let path = entry.path {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let path = entry.path {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Im Finder zeigen")
            }
            timestamp
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contextMenu {
            if let path = entry.path {
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button("Pfad kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
            }
        }
    }

    private var timestamp: some View {
        Text(entry.date.formatted(date: .omitted, time: .standard))
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.quaternary)
    }

    private var icon: String {
        switch entry.kind {
        case .header:  return "film"
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    private var iconColor: AnyShapeStyle {
        switch entry.kind {
        case .header:  return AnyShapeStyle(.tint)
        case .info:    return AnyShapeStyle(.secondary)
        case .success: return AnyShapeStyle(.green)
        case .warning: return AnyShapeStyle(.orange)
        case .error:   return AnyShapeStyle(.red)
        }
    }
}

private struct ToolStatusView: View {
    @State private var ok = false
    @State private var label = "Suche ffmpeg …"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(label).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .task {
            let ff = Tools.locate("ffmpeg")
            let fp = Tools.locate("ffprobe")
            ok = (ff != nil && fp != nil)
            let bundled = (ff?.path.contains(".app/Contents/Resources/") ?? false)
            if !ok {
                label = "ffmpeg/ffprobe fehlen"
            } else {
                label = bundled ? "ffmpeg gebündelt" : "ffmpeg: \(ff?.path ?? "")"
            }
        }
    }
}
