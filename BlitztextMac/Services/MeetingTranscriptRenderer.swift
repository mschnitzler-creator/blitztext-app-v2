import Foundation

/// Rendert Sprecher-Segmente zu lesbarem Transkript-Text.
/// Nummerierung 1-basiert nach erster Redezeit: wer zuerst spricht, ist "Sprecher 1".
/// Optional werden Umbenennungen (speakerID → Name) angewendet; nicht umbenannte
/// Sprecher behalten ihre Nummer aus der Redereihenfolge.
enum MeetingTranscriptRenderer {
    /// Sprecher-IDs in Reihenfolge der ersten Redezeit (für die Umbenennen-UI).
    static func orderedSpeakerIDs(for segments: [SpeakerSegment]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for segment in segments where !seen.contains(segment.speakerID) {
            seen.insert(segment.speakerID)
            ordered.append(segment.speakerID)
        }
        return ordered
    }

    /// speakerID → Anzeigename: umbenannter Name falls vorhanden, sonst "Sprecher N".
    static func speakerLabels(
        for segments: [SpeakerSegment],
        names: [String: String]? = nil
    ) -> [String: String] {
        var labels: [String: String] = [:]
        for (index, speakerID) in orderedSpeakerIDs(for: segments).enumerated() {
            let custom = names?[speakerID]?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let custom, !custom.isEmpty {
                labels[speakerID] = custom
            } else {
                labels[speakerID] = "Sprecher \(index + 1)"
            }
        }
        return labels
    }

    /// Teilnehmerliste für Anzeige und Export: erst benannte Sprecher nach
    /// Redereihenfolge, dann manuelle Teilnehmer in Eingabereihenfolge.
    /// Unbenannte Sprecher fallen weg, Duplikate (case-insensitive) auch.
    static func combinedParticipants(
        segments: [SpeakerSegment],
        names: [String: String]?,
        extraParticipants: [String]?
    ) -> [String] {
        let speakerNames = orderedSpeakerIDs(for: segments).compactMap { speakerID -> String? in
            guard let name = names?[speakerID]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return name
        }

        var seen = Set<String>()
        var combined: [String] = []
        for name in speakerNames + (extraParticipants ?? []) {
            guard seen.insert(name.lowercased()).inserted else { continue }
            combined.append(name)
        }
        return combined
    }

    static func renderedText(
        from segments: [SpeakerSegment],
        names: [String: String]? = nil
    ) -> String {
        let labels = speakerLabels(for: segments, names: names)

        let blocks = segments.map { segment in
            "\(labels[segment.speakerID] ?? "Sprecher"): \(segment.text)"
        }

        return blocks.joined(separator: "\n\n")
    }
}
