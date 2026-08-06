import Foundation
import SQLite3

// ============================================================================
// SQLite-Persistenz für Presets + Einstellungen
//
// Datei: ~/Library/Application Support/VideoTools/videotools.sqlite
//
// Seed-Semantik wie beim API-Server: eingebaute Presets werden beim ersten
// Start eingefügt; existiert ein Preset bereits, wird NICHTS überschrieben —
// Nutzeränderungen (inkl. is_active) überleben jedes App-Update. „Auf
// Standard zurücksetzen“ passiert nur explizit über die Oberfläche.
// ============================================================================

@MainActor
final class PresetStore {
    private var db: OpaquePointer?

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                               appropriateFor: nil, create: true))?
            .appendingPathComponent("VideoTools", isDirectory: true)
        if let dir {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("videotools.sqlite").path
            if sqlite3_open(path, &db) != SQLITE_OK {
                db = nil
            }
        }
        guard db != nil else { return }
        exec("PRAGMA journal_mode=WAL")
        createSchema()
        seedBuiltins()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // -------------------------------------------------------------------
    // Schema + Seed
    // -------------------------------------------------------------------

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS presets (
            id          TEXT PRIMARY KEY,
            label       TEXT NOT NULL,
            details     TEXT NOT NULL DEFAULT '',
            media_type  TEXT NOT NULL DEFAULT 'video',
            is_builtin  INTEGER NOT NULL DEFAULT 0,
            is_active   INTEGER NOT NULL DEFAULT 1,
            sort_order  INTEGER NOT NULL DEFAULT 50,
            base_suffix TEXT NOT NULL DEFAULT '_T'
        )
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS renditions (
            id                 TEXT PRIMARY KEY,
            preset_id          TEXT NOT NULL,
            position           INTEGER NOT NULL,
            name               TEXT NOT NULL,
            filename_suffix    TEXT NOT NULL DEFAULT '',
            container          TEXT NOT NULL DEFAULT 'mp4',
            width              INTEGER NOT NULL DEFAULT 1280,
            height             INTEGER NOT NULL DEFAULT 720,
            rate_control       TEXT NOT NULL DEFAULT 'capped-crf',
            video_bitrate_kbps INTEGER NOT NULL DEFAULT 4500,
            maxrate_kbps       INTEGER NOT NULL DEFAULT 5000,
            bufsize_kbps       INTEGER NOT NULL DEFAULT 15000,
            crf                INTEGER NOT NULL DEFAULT 20,
            keyint             INTEGER NOT NULL DEFAULT 25,
            profile            TEXT NOT NULL DEFAULT 'main',
            speed_preset       TEXT NOT NULL DEFAULT 'veryfast',
            audio_codec        TEXT,
            audio_bitrate_kbps INTEGER NOT NULL DEFAULT 128,
            audio_sample_rate  INTEGER NOT NULL DEFAULT 44100,
            audio_channels     INTEGER NOT NULL DEFAULT 2
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_renditions_preset ON renditions(preset_id, position)")
        exec("""
        CREATE TABLE IF NOT EXISTS app_settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """)
    }

    private func seedBuiltins() {
        for preset in TranscodePreset.builtins where !presetExists(preset.id) {
            insert(preset)
        }
    }

    private func presetExists(_ id: String) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM presets WHERE id = ?", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        sqlite3_bind_text(stmt, 1, id, -1, Self.transient)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // -------------------------------------------------------------------
    // Laden
    // -------------------------------------------------------------------

    func load() -> TranscodeSettings {
        var settings = TranscodeSettings()
        let presets = loadPresets()
        if !presets.isEmpty { settings.presets = presets }
        settings.selectedPresetID = readSetting("selected_preset_id") ?? TranscodePreset.defaultID
        settings.deinterlace = DeinterlaceMode(rawValue: readSetting("deinterlace") ?? "") ?? .auto
        settings.audioCodec = AudioCodecChoice(rawValue: readSetting("audio_codec") ?? "") ?? .auto
        return settings
    }

    private func loadPresets() -> [TranscodePreset] {
        var result: [TranscodePreset] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT id, label, details, media_type, is_builtin, is_active, sort_order, base_suffix
        FROM presets ORDER BY sort_order, label
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = text(stmt, 0) ?? ""
            var preset = TranscodePreset(
                id: id,
                label: text(stmt, 1) ?? id,
                details: text(stmt, 2) ?? "",
                mediaType: MediaType(rawValue: text(stmt, 3) ?? "") ?? .video,
                isBuiltin: sqlite3_column_int64(stmt, 4) != 0,
                isActive: sqlite3_column_int64(stmt, 5) != 0,
                sortOrder: Int(sqlite3_column_int64(stmt, 6)),
                baseSuffix: text(stmt, 7) ?? "",
                renditions: []
            )
            preset.renditions = loadRenditions(presetID: id)
            result.append(preset)
        }
        return result
    }

    private func loadRenditions(presetID: String) -> [Rendition] {
        var result: [Rendition] = []
        var stmt: OpaquePointer?
        let sql = """
        SELECT id, name, filename_suffix, container, width, height, rate_control,
               video_bitrate_kbps, maxrate_kbps, bufsize_kbps, crf, keyint, profile,
               speed_preset, audio_codec, audio_bitrate_kbps, audio_sample_rate, audio_channels
        FROM renditions WHERE preset_id = ? ORDER BY position
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, presetID, -1, Self.transient)

        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(Rendition(
                id: UUID(uuidString: text(stmt, 0) ?? "") ?? UUID(),
                name: text(stmt, 1) ?? "",
                filenameSuffix: text(stmt, 2) ?? "",
                container: OutputContainer(rawValue: text(stmt, 3) ?? "") ?? .mp4,
                width: Int(sqlite3_column_int64(stmt, 4)),
                height: Int(sqlite3_column_int64(stmt, 5)),
                rateControl: RateControl(rawValue: text(stmt, 6) ?? "") ?? .cappedCRF,
                videoBitrateKbps: Int(sqlite3_column_int64(stmt, 7)),
                maxrateKbps: Int(sqlite3_column_int64(stmt, 8)),
                bufsizeKbps: Int(sqlite3_column_int64(stmt, 9)),
                crf: Int(sqlite3_column_int64(stmt, 10)),
                keyint: Int(sqlite3_column_int64(stmt, 11)),
                profile: text(stmt, 12) ?? "main",
                speedPreset: text(stmt, 13) ?? "veryfast",
                audioCodec: text(stmt, 14),
                audioBitrateKbps: Int(sqlite3_column_int64(stmt, 15)),
                audioSampleRate: Int(sqlite3_column_int64(stmt, 16)),
                audioChannels: Int(sqlite3_column_int64(stmt, 17))
            ))
        }
        return result
    }

    // -------------------------------------------------------------------
    // Speichern (kompletter Abgleich in einer Transaktion)
    // -------------------------------------------------------------------

    func save(_ settings: TranscodeSettings) {
        guard db != nil else { return }
        exec("BEGIN")
        exec("DELETE FROM renditions")
        exec("DELETE FROM presets")
        for preset in settings.presets { insert(preset) }
        writeSetting("selected_preset_id", settings.selectedPresetID)
        writeSetting("deinterlace", settings.deinterlace.rawValue)
        writeSetting("audio_codec", settings.audioCodec.rawValue)
        exec("COMMIT")
    }

    private func insert(_ preset: TranscodePreset) {
        var stmt: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO presets
            (id, label, details, media_type, is_builtin, is_active, sort_order, base_suffix)
        VALUES (?,?,?,?,?,?,?,?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, preset.id, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, preset.label, -1, Self.transient)
        sqlite3_bind_text(stmt, 3, preset.details, -1, Self.transient)
        sqlite3_bind_text(stmt, 4, preset.mediaType.rawValue, -1, Self.transient)
        sqlite3_bind_int64(stmt, 5, preset.isBuiltin ? 1 : 0)
        sqlite3_bind_int64(stmt, 6, preset.isActive ? 1 : 0)
        sqlite3_bind_int64(stmt, 7, Int64(preset.sortOrder))
        sqlite3_bind_text(stmt, 8, preset.baseSuffix, -1, Self.transient)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        for (position, r) in preset.renditions.enumerated() {
            insertRendition(r, presetID: preset.id, position: position)
        }
    }

    private func insertRendition(_ r: Rendition, presetID: String, position: Int) {
        var stmt: OpaquePointer?
        let sql = """
        INSERT OR REPLACE INTO renditions
            (id, preset_id, position, name, filename_suffix, container, width, height,
             rate_control, video_bitrate_kbps, maxrate_kbps, bufsize_kbps, crf, keyint,
             profile, speed_preset, audio_codec, audio_bitrate_kbps, audio_sample_rate,
             audio_channels)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, r.id.uuidString, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, presetID, -1, Self.transient)
        sqlite3_bind_int64(stmt, 3, Int64(position))
        sqlite3_bind_text(stmt, 4, r.name, -1, Self.transient)
        sqlite3_bind_text(stmt, 5, r.filenameSuffix, -1, Self.transient)
        sqlite3_bind_text(stmt, 6, r.container.rawValue, -1, Self.transient)
        sqlite3_bind_int64(stmt, 7, Int64(r.width))
        sqlite3_bind_int64(stmt, 8, Int64(r.height))
        sqlite3_bind_text(stmt, 9, r.rateControl.rawValue, -1, Self.transient)
        sqlite3_bind_int64(stmt, 10, Int64(r.videoBitrateKbps))
        sqlite3_bind_int64(stmt, 11, Int64(r.maxrateKbps))
        sqlite3_bind_int64(stmt, 12, Int64(r.bufsizeKbps))
        sqlite3_bind_int64(stmt, 13, Int64(r.crf))
        sqlite3_bind_int64(stmt, 14, Int64(r.keyint))
        sqlite3_bind_text(stmt, 15, r.profile, -1, Self.transient)
        sqlite3_bind_text(stmt, 16, r.speedPreset, -1, Self.transient)
        if let codec = r.audioCodec {
            sqlite3_bind_text(stmt, 17, codec, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, 17)
        }
        sqlite3_bind_int64(stmt, 18, Int64(r.audioBitrateKbps))
        sqlite3_bind_int64(stmt, 19, Int64(r.audioSampleRate))
        sqlite3_bind_int64(stmt, 20, Int64(r.audioChannels))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // -------------------------------------------------------------------
    // Key-Value-Einstellungen
    // -------------------------------------------------------------------

    private func readSetting(_ key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM app_settings WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return text(stmt, 0)
    }

    private func writeSetting(_ key: String, _ value: String) {
        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO app_settings (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, key, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, value, -1, Self.transient)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    // -------------------------------------------------------------------
    // Helfer
    // -------------------------------------------------------------------

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, column) else { return nil }
        return String(cString: c)
    }
}
