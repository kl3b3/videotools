import SwiftUI
import AppKit

@main
struct VideoToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("VideoTools") {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 360)
                .onAppear { AppDelegate.sharedModel = model }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Beim Kaltstart mit Dokument feuert das open-Event, bevor SwiftUI das
    /// Fenster aufgebaut hat – bis dahin werden URLs hier zwischengepuffert.
    static weak var sharedModel: AppModel? {
        didSet {
            if let model = sharedModel, !pendingURLs.isEmpty {
                model.enqueue(pendingURLs)
                pendingURLs.removeAll()
            }
        }
    }
    private static var pendingURLs: [URL] = []

    private static func deliver(_ urls: [URL]) {
        if let model = sharedModel {
            model.enqueue(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    /// Moderner Weg (Finder „Öffnen mit“, Drag aufs Dock-Icon, `open -a`).
    func application(_ application: NSApplication, open urls: [URL]) {
        Self.deliver(urls)
    }

    /// Legacy-Fallback für ältere LaunchServices-Pfade.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        Self.deliver(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }
}
