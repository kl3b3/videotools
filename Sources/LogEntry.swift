import Foundation

/// Ein Eintrag im (untechnischen) Fenster-Log.
struct LogEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case header    // neue Datei wird verarbeitet
        case info
        case success
        case warning
        case error
    }

    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String
    /// Sekundärzeile, z.B. "1920×1080 · 25 fps" oder "Details im technischen Log".
    var detail: String? = nil
    /// Erzeugte/betroffene Datei – wird verkürzt angezeigt und ist im Finder öffenbar.
    var path: String? = nil
}
