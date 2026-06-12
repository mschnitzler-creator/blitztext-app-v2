import Foundation
import Observation

enum TranscriptKind: String, Codable {
    case dictation
    case meeting
}

struct TranscriptEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let workflowType: WorkflowType
    var text: String
    /// Diktat oder Meeting. Alte history.json-Einträge ohne dieses Feld laden als Diktat.
    var kind: TranscriptKind
    /// Sprecher-Segmente (nur Meetings mit Cloud-Transkription).
    var segments: [SpeakerSegment]?
    /// Umbenennungen: speakerID → Anzeigename (nur Meetings).
    var speakerNames: [String: String]?
    /// LLM-Titel (nur Meetings).
    var title: String?
    /// LLM-Zusammenfassung (nur Meetings).
    var summary: String?
    /// Aufnahmedauer in Sekunden (nur Meetings, falls bekannt).
    var durationSeconds: Double?
    /// Dateiname des letzten Second-Brain-Exports (nur Meetings).
    /// Bei Re-Export mit geändertem Namen wird die alte Datei darüber gefunden und gelöscht.
    var exportFilename: String?
    /// Manuell ergänzte Teilnehmer (nur Meetings), z.B. wenn die Sprechererkennung
    /// Personen zusammengelegt hat (Telefon auf laut). Reihenfolge = Eingabereihenfolge.
    var extraParticipants: [String]?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        workflowType: WorkflowType,
        text: String,
        kind: TranscriptKind = .dictation,
        segments: [SpeakerSegment]? = nil,
        speakerNames: [String: String]? = nil,
        title: String? = nil,
        summary: String? = nil,
        durationSeconds: Double? = nil,
        exportFilename: String? = nil,
        extraParticipants: [String]? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.workflowType = workflowType
        self.text = text
        self.kind = kind
        self.segments = segments
        self.speakerNames = speakerNames
        self.title = title
        self.summary = summary
        self.durationSeconds = durationSeconds
        self.exportFilename = exportFilename
        self.extraParticipants = extraParticipants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        workflowType = try container.decode(WorkflowType.self, forKey: .workflowType)
        text = try container.decode(String.self, forKey: .text)
        // Abwärtskompatibel: bestehende Dateien ohne die Meeting-Felder laden weiter.
        kind = try container.decodeIfPresent(TranscriptKind.self, forKey: .kind) ?? .dictation
        segments = try container.decodeIfPresent([SpeakerSegment].self, forKey: .segments)
        speakerNames = try container.decodeIfPresent([String: String].self, forKey: .speakerNames)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        exportFilename = try container.decodeIfPresent(String.self, forKey: .exportFilename)
        extraParticipants = try container.decodeIfPresent([String].self, forKey: .extraParticipants)
    }
}

@Observable
@MainActor
final class TranscriptStore {
    static let shared = TranscriptStore()

    private(set) var entries: [TranscriptEntry] = []

    private static let maxEntries = 1000
    private let storageURL: URL

    init(storageURL: URL = AppSupportPaths.historyURL) {
        self.storageURL = storageURL
        self.entries = Self.load(from: storageURL)
    }

    func add(text: String, workflowType: WorkflowType) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(TranscriptEntry(workflowType: workflowType, text: trimmed), at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
    }

    /// Legt einen Meeting-Eintrag ab. `workflowType` bleibt `.transcription`,
    /// die Unterscheidung läuft über `kind` (Meetings haben keinen eigenen WorkflowType).
    /// Rückgabe: der angelegte Eintrag (z.B. für den Second-Brain-Export), nil bei leerem Text.
    @discardableResult
    func addMeeting(
        text: String,
        segments: [SpeakerSegment]?,
        title: String?,
        summary: String?,
        durationSeconds: Double? = nil
    ) -> TranscriptEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let entry = TranscriptEntry(
            workflowType: .transcription,
            text: trimmed,
            kind: .meeting,
            segments: segments,
            title: title,
            summary: summary,
            durationSeconds: durationSeconds
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        save()
        return entry
    }

    /// Benennt einen Sprecher eines Meeting-Eintrags um, rendert den Text aus den
    /// Segmenten neu und persistiert. Leerer Name entfernt die Umbenennung.
    /// Rückgabe: der aktualisierte Eintrag (z.B. für den erneuten Export).
    @discardableResult
    func rename(entryID: UUID, speakerID: String, to name: String) -> TranscriptEntry? {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return nil }
        var entry = entries[index]

        var names = entry.speakerNames ?? [:]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names.removeValue(forKey: speakerID)
        } else {
            names[speakerID] = trimmed
        }
        entry.speakerNames = names.isEmpty ? nil : names

        if let segments = entry.segments, !segments.isEmpty {
            entry.text = MeetingTranscriptRenderer.renderedText(from: segments, names: entry.speakerNames)
        }

        entries[index] = entry
        save()
        return entry
    }

    /// Benennt den Titel eines Eintrags um (getrimmt) und persistiert.
    /// Leerer Titel ändert nichts. Rückgabe: der aktualisierte Eintrag.
    @discardableResult
    func renameTitle(entryID: UUID, to title: String) -> TranscriptEntry? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = entries.firstIndex(where: { $0.id == entryID }) else { return nil }

        entries[index].title = trimmed
        save()
        return entries[index]
    }

    /// Ergänzt einen manuellen Teilnehmer (getrimmt) und persistiert.
    /// Leerer Name und Duplikate (case-insensitive) werden ignoriert (Rückgabe nil).
    /// Rückgabe: der aktualisierte Eintrag (z.B. für den erneuten Export).
    @discardableResult
    func addParticipant(entryID: UUID, name: String) -> TranscriptEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = entries.firstIndex(where: { $0.id == entryID }) else { return nil }

        var participants = entries[index].extraParticipants ?? []
        guard !participants.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return nil }

        participants.append(trimmed)
        entries[index].extraParticipants = participants
        save()
        return entries[index]
    }

    /// Entfernt einen manuellen Teilnehmer (case-insensitive) und persistiert.
    /// Rückgabe: der aktualisierte Eintrag, nil wenn der Name nicht vorhanden war.
    @discardableResult
    func removeParticipant(entryID: UUID, name: String) -> TranscriptEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = entries.firstIndex(where: { $0.id == entryID }),
              var participants = entries[index].extraParticipants else { return nil }

        let countBefore = participants.count
        participants.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        guard participants.count < countBefore else { return nil }

        entries[index].extraParticipants = participants.isEmpty ? nil : participants
        save()
        return entries[index]
    }

    /// Merkt sich den Dateinamen des letzten Second-Brain-Exports am Eintrag.
    @discardableResult
    func setExportFilename(entryID: UUID, filename: String?) -> TranscriptEntry? {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return nil }
        entries[index].exportFilename = filename
        save()
        return entries[index]
    }

    func delete(_ entry: TranscriptEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func deleteAll() {
        entries.removeAll()
        save()
    }

    private func save() {
        try? AppSupportPaths.ensureAppSupportDirectoryExists()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private static func load(from url: URL) -> [TranscriptEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([TranscriptEntry].self, from: data)) ?? []
    }
}
