import XCTest
@testable import Blitztext

final class SecondBrainExporterTests: XCTestCase {

    // MARK: - Hilfen

    /// Datum aus lokalen Komponenten, damit die Tests in jeder Zeitzone stabil sind.
    private func localDate(
        year: Int, month: Int, day: Int, hour: Int, minute: Int
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    // MARK: - Slug

    func testSlugLowercasesConvertsUmlautsAndStripsSymbols() {
        XCTAssertEqual(
            SecondBrainExporter.slug(from: "Zinsbindung läuft aus – Größe & Maße!"),
            "zinsbindung-laeuft-aus-groesse-masse"
        )
    }

    func testSlugFallsBackToMeetingForEmptyOrSymbolOnlyTitles() {
        XCTAssertEqual(SecondBrainExporter.slug(from: ""), "meeting")
        XCTAssertEqual(SecondBrainExporter.slug(from: "   "), "meeting")
        XCTAssertEqual(SecondBrainExporter.slug(from: "???!!!"), "meeting")
    }

    func testSlugTruncatesToSixtyCharactersWithoutTrailingHyphen() {
        let longTitle = String(repeating: "abcde ", count: 20) // 120 Zeichen
        let slug = SecondBrainExporter.slug(from: longTitle)
        XCTAssertLessThanOrEqual(slug.count, 60)
        XCTAssertFalse(slug.hasSuffix("-"))
        XCTAssertTrue(slug.hasPrefix("abcde-abcde"))
    }

    // MARK: - Dateiname

    func testFilenameUsesDateTimeAndTitleSlug() {
        let entry = TranscriptEntry(
            createdAt: localDate(year: 2026, month: 6, day: 12, hour: 14, minute: 30),
            workflowType: .transcription,
            text: "Sprecher 1: Hallo",
            kind: .meeting,
            title: "Budget Meeting Q3"
        )

        XCTAssertEqual(
            SecondBrainExporter.filename(for: entry),
            "2026-06-12_1430_budget-meeting-q3.md"
        )
    }

    func testFilenameFallsBackToMeetingSlugWithoutTitle() {
        let entry = TranscriptEntry(
            createdAt: localDate(year: 2026, month: 1, day: 5, hour: 9, minute: 5),
            workflowType: .transcription,
            text: "Nur Text",
            kind: .meeting
        )

        XCTAssertEqual(SecondBrainExporter.filename(for: entry), "2026-01-05_0905_meeting.md")
    }

    // MARK: - Markdown: Frontmatter + Struktur + speakerNames

    func testMarkdownRendersFrontmatterSectionsAndAppliesSpeakerNames() {
        let entry = TranscriptEntry(
            createdAt: localDate(year: 2026, month: 6, day: 12, hour: 14, minute: 30),
            workflowType: .transcription,
            text: "Sprecher 1: Hallo zusammen\n\nSprecher 2: Guten Morgen",
            kind: .meeting,
            segments: [
                SpeakerSegment(speakerID: "speaker_0", text: "Hallo zusammen", start: 0.0),
                SpeakerSegment(speakerID: "speaker_1", text: "Guten Morgen", start: 3.0),
            ],
            speakerNames: ["speaker_0": "Marc"],
            title: "Budget Meeting",
            summary: "- Budget freigegeben\n- Nächster Termin offen",
            durationSeconds: 1800
        )

        let markdown = SecondBrainExporter.markdown(for: entry)

        XCTAssertTrue(markdown.hasPrefix("---\n"), "Frontmatter muss am Anfang stehen")
        XCTAssertTrue(markdown.contains("datum: 2026-06-12T14:30:00"))
        XCTAssertTrue(markdown.contains("dauer: 30 min"))
        XCTAssertTrue(markdown.contains("modus: cloud"))
        XCTAssertTrue(markdown.contains("# Budget Meeting"))
        XCTAssertTrue(markdown.contains("## Zusammenfassung"))
        XCTAssertTrue(markdown.contains("- Budget freigegeben"))
        XCTAssertTrue(markdown.contains("## Transkript"))
        // Umbenannter Sprecher mit Name, nicht umbenannter mit Nummer nach Redereihenfolge.
        XCTAssertTrue(markdown.contains("**Marc:** Hallo zusammen"))
        XCTAssertTrue(markdown.contains("**Sprecher 2:** Guten Morgen"))
        XCTAssertFalse(markdown.contains("**Sprecher 1:**"))
    }

    func testMarkdownWithoutSegmentsAndSummaryUsesPlainTextAndLocalMode() {
        let entry = TranscriptEntry(
            createdAt: localDate(year: 2026, month: 6, day: 12, hour: 8, minute: 0),
            workflowType: .transcription,
            text: "Lokales Transkript ohne Sprecher.",
            kind: .meeting
        )

        let markdown = SecondBrainExporter.markdown(for: entry)

        XCTAssertTrue(markdown.contains("modus: lokal"))
        XCTAssertFalse(markdown.contains("dauer:"), "Ohne bekannte Dauer keine dauer-Zeile")
        XCTAssertFalse(markdown.contains("## Zusammenfassung"))
        XCTAssertTrue(markdown.contains("# Meeting vom 12.06.2026"))
        XCTAssertTrue(markdown.contains("## Transkript"))
        XCTAssertTrue(markdown.contains("Lokales Transkript ohne Sprecher."))
        XCTAssertFalse(markdown.contains("**Sprecher"))
    }

    func testMarkdownFrontmatterListsNamedSpeakersAndManualParticipants() {
        let entry = TranscriptEntry(
            createdAt: localDate(year: 2026, month: 6, day: 12, hour: 14, minute: 30),
            workflowType: .transcription,
            text: "Thomas: Hallo\n\nMarkus: Moin",
            kind: .meeting,
            segments: [
                SpeakerSegment(speakerID: "speaker_0", text: "Hallo", start: 0.0),
                SpeakerSegment(speakerID: "speaker_1", text: "Moin", start: 2.0),
            ],
            speakerNames: ["speaker_0": "Thomas", "speaker_1": "Markus"],
            title: "Teilnehmer-Meeting",
            extraParticipants: ["Heidi"]
        )

        let markdown = SecondBrainExporter.markdown(for: entry)

        XCTAssertTrue(markdown.contains("teilnehmer: Thomas, Markus, Heidi"))
        // Die Zeile gehört ins Frontmatter, vor das schließende "---".
        let frontmatter = markdown.components(separatedBy: "---")[1]
        XCTAssertTrue(frontmatter.contains("teilnehmer: Thomas, Markus, Heidi"))
    }

    func testMarkdownWithoutParticipantsHasNoTeilnehmerLine() {
        let entry = TranscriptEntry(
            createdAt: localDate(year: 2026, month: 6, day: 12, hour: 8, minute: 0),
            workflowType: .transcription,
            text: "Sprecher 1: Hallo",
            kind: .meeting,
            segments: [SpeakerSegment(speakerID: "speaker_0", text: "Hallo", start: 0.0)]
        )

        XCTAssertFalse(SecondBrainExporter.markdown(for: entry).contains("teilnehmer:"))
    }

    // MARK: - Datei schreiben

    func testExportWritesMarkdownFileIntoFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("second-brain-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let entry = TranscriptEntry(
            createdAt: localDate(year: 2026, month: 6, day: 12, hour: 14, minute: 30),
            workflowType: .transcription,
            text: "Sprecher 1: Hallo",
            kind: .meeting,
            segments: [SpeakerSegment(speakerID: "speaker_0", text: "Hallo", start: 0.0)],
            title: "Kurzes Meeting"
        )

        let url = try SecondBrainExporter.export(entry: entry, toFolder: folder.path)

        XCTAssertEqual(url.lastPathComponent, "2026-06-12_1430_kurzes-meeting.md")
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, SecondBrainExporter.markdown(for: entry))
    }

    func testReexportNachTitelaenderungLoeschtAlteDatei() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("second-brain-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var entry = TranscriptEntry(
            createdAt: localDate(year: 2026, month: 6, day: 12, hour: 14, minute: 30),
            workflowType: .transcription,
            text: "Sprecher 1: Hallo",
            kind: .meeting,
            title: "Alter Titel"
        )
        let oldURL = try SecondBrainExporter.export(entry: entry, toFolder: folder.path)
        XCTAssertEqual(oldURL.lastPathComponent, "2026-06-12_1430_alter-titel.md")
        entry.exportFilename = oldURL.lastPathComponent

        entry.title = "Neuer Titel"
        let newFilename = try SecondBrainExporter.exportReplacingOldFile(
            entry: entry, toFolder: folder.path
        )

        XCTAssertEqual(newFilename, "2026-06-12_1430_neuer-titel.md")
        let newURL = folder.appendingPathComponent(newFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldURL.path),
            "Alte Datei muss nach der Titel-Umbenennung gelöscht sein"
        )
    }

    func testReexportOhneNamensaenderungUeberschreibtDieselbeDatei() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("second-brain-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var entry = TranscriptEntry(
            createdAt: localDate(year: 2026, month: 6, day: 12, hour: 14, minute: 30),
            workflowType: .transcription,
            text: "Sprecher 1: Hallo",
            kind: .meeting,
            segments: [SpeakerSegment(speakerID: "speaker_0", text: "Hallo", start: 0.0)],
            title: "Gleicher Titel"
        )
        let oldURL = try SecondBrainExporter.export(entry: entry, toFolder: folder.path)
        entry.exportFilename = oldURL.lastPathComponent

        // Sprecher-Umbenennung ändert den Dateinamen nicht: gleiche Datei, neuer Inhalt.
        entry.speakerNames = ["speaker_0": "Marc"]
        let newFilename = try SecondBrainExporter.exportReplacingOldFile(
            entry: entry, toFolder: folder.path
        )

        XCTAssertEqual(newFilename, oldURL.lastPathComponent)
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(contents, [newFilename])
        let written = try String(contentsOf: oldURL, encoding: .utf8)
        XCTAssertTrue(written.contains("**Marc:** Hallo"))
    }
}
