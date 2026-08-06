import Foundation

enum Mode: String, CaseIterable, Identifiable {
    case all, info, still, encode
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:    return "Alles (Metadaten + Stills + Transkodierung)"
        case .info:   return "Nur Metadaten"
        case .still:  return "Stills extrahieren"
        case .encode: return "Nur Transkodieren"
        }
    }
    /// Braucht dieser Modus ein gewähltes Transcoding-Preset?
    var usesPreset: Bool {
        self == .all || self == .encode
    }
}
