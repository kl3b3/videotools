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
        return HStack(spacing: 12) {
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
