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

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedModel: AppModel?

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        Task { @MainActor in AppDelegate.sharedModel?.enqueue(urls) }
        sender.reply(toOpenOrPrint: .success)
    }
}
