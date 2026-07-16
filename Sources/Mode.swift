import Foundation

enum Mode: String, CaseIterable, Identifiable {
    case all, info, still, encode360, encode720, encodeAll
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:       return "Alles (Metadaten + Stills + Transkodierung)"
        case .info:      return "Nur Metadaten"
        case .still:     return "Stills extrahieren"
        case .encode360: return "Transkodieren · 360p"
        case .encode720: return "Transkodieren · 720p"
        case .encodeAll: return "Transkodieren · alle Qualitäten"
        }
    }
}
