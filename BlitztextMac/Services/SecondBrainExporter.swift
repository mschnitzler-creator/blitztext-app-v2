import Foundation

/// Schreibt Meeting-Einträge als Markdown-Dateien ins Second Brain.
/// Rendern (pure Funktionen) und Datei-Schreiben sind getrennt, damit das
/// Format ohne Dateisystem testbar bleibt.
enum SecondBrainExporter {

    // MARK: - Slug

    /// Dateinamen-Slug aus dem Titel: lowercase, Umlaute zu ae/oe/ue/ss,
    /// alles Nicht-Alphanumerische zu Bindestrich, max. 60 Zeichen.
    /// Fallback bei leerem Ergebnis: "meeting".
    static func slug(from title: String) -> String {
        var text = title.lowercased()
        for (umlaut, replacement) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] {
            text = text.replacingOccurrences(of: umlaut, with: replacement)
        }

        var result = ""
        var lastWasHyphen = true // unterdrückt führende Bindestriche
        for scalar in text.unicodeScalars {
            let isASCIIAlphanumeric = (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
            if isASCIIAlphanumeric {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }

        result = String(result.prefix(60))
        while result.hasSuffix("-") {
            result.removeLast()
        }
        return result.isEmpty ? "meeting" : result
    }

    // MARK: - Dateiname

    /// `YYYY-MM-DD_HHMM_<titel-slug>.md`, Zeit in lokaler Zeitzone.
    static func filename(for entry: TranscriptEntry) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let datePart = formatter.string(from: entry.createdAt)
        return "\(datePart)_\(slug(from: entry.title ?? "")).md"
    }

    // MARK: - Markdown (pure Render-Funktion)

    static func markdown(for entry: TranscriptEntry) -> String {
        var lines: [String] = ["---"]
        lines.append("datum: \(Self.isoFormatter.string(from: entry.createdAt))")
        if let duration = entry.durationSeconds, duration > 0 {
            lines.append("dauer: \(max(1, Int((duration / 60).rounded()))) min")
        }
        let participants = MeetingTranscriptRenderer.combinedParticipants(
            segments: entry.segments ?? [],
            names: entry.speakerNames,
            extraParticipants: entry.extraParticipants
        )
        if !participants.isEmpty {
            lines.append("teilnehmer: \(participants.joined(separator: ", "))")
        }
        lines.append("modus: \(entry.segments?.isEmpty == false ? "cloud" : "lokal")")
        lines.append("---")
        lines.append("")
        lines.append("# \(headline(for: entry))")

        if let summary = entry.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            lines.append("")
            lines.append("## Zusammenfassung")
            lines.append("")
            lines.append(summary)
        }

        lines.append("")
        lines.append("## Transkript")
        lines.append("")
        lines.append(transcriptBody(for: entry))
        lines.append("")

        return lines.joined(separator: "\n")
    }

    private static func headline(for entry: TranscriptEntry) -> String {
        let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            return title
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "dd.MM.yyyy"
        return "Meeting vom \(formatter.string(from: entry.createdAt))"
    }

    private static func transcriptBody(for entry: TranscriptEntry) -> String {
        guard let segments = entry.segments, !segments.isEmpty else {
            // Lokal transkribierte Meetings haben keine Sprecher: reiner Text.
            return entry.text
        }

        let labels = MeetingTranscriptRenderer.speakerLabels(
            for: segments,
            names: entry.speakerNames
        )
        return segments
            .map { "**\(labels[$0.speakerID] ?? "Sprecher"):** \($0.text)" }
            .joined(separator: "\n\n")
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    // MARK: - Datei schreiben

    /// Schreibt die Markdown-Datei in den Zielordner (legt ihn bei Bedarf an).
    /// Eine bestehende Datei gleichen Namens wird überschrieben.
    @discardableResult
    static func export(entry: TranscriptEntry, toFolder folderPath: String) throws -> URL {
        let expandedPath = (folderPath as NSString).expandingTildeInPath
        let folderURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let fileURL = folderURL.appendingPathComponent(filename(for: entry))
        try Data(markdown(for: entry).utf8).write(to: fileURL, options: .atomic)
        return fileURL
    }

    /// Re-Export nach Titel- oder Sprecher-Umbenennung: schreibt die Datei neu.
    /// Weicht der neue Dateiname vom gespeicherten `exportFilename` ab
    /// (Titel-Umbenennung ändert den Slug), wird die alte Datei gelöscht.
    /// Rückgabe: der Dateiname der geschriebenen Datei (für den Eintrag merken).
    @discardableResult
    static func exportReplacingOldFile(
        entry: TranscriptEntry,
        toFolder folderPath: String
    ) throws -> String {
        let fileURL = try export(entry: entry, toFolder: folderPath)
        let newFilename = fileURL.lastPathComponent

        if let oldFilename = entry.exportFilename, oldFilename != newFilename {
            let oldURL = fileURL.deletingLastPathComponent().appendingPathComponent(oldFilename)
            try? FileManager.default.removeItem(at: oldURL)
        }
        return newFilename
    }
}
