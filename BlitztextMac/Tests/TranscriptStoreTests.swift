import XCTest
@testable import Blitztext

@MainActor
final class TranscriptStoreTests: XCTestCase {
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-test-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    func testAddInsertsNewestFirstAndPersists() {
        let store = TranscriptStore(storageURL: tempURL)
        store.add(text: "Erster Text", workflowType: .transcription)
        store.add(text: "Zweiter Text", workflowType: .transcription)

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries[0].text, "Zweiter Text")

        let reloaded = TranscriptStore(storageURL: tempURL)
        XCTAssertEqual(reloaded.entries.count, 2)
        XCTAssertEqual(reloaded.entries[0].text, "Zweiter Text")
    }

    func testAddIgnoresEmptyText() {
        let store = TranscriptStore(storageURL: tempURL)
        store.add(text: "   \n", workflowType: .transcription)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testLoadsLegacyHistoryWithoutMeetingFields() throws {
        // Altes history.json-Format aus Etappe 1: kein kind, keine Meeting-Felder.
        let legacyJSON = """
        [{"id":"6F1E0E5A-2B8E-4C3B-9D2A-1A2B3C4D5E6F",
          "createdAt":"2026-06-01T10:00:00Z",
          "workflowType":"transcription",
          "text":"Alter Eintrag"}]
        """
        try Data(legacyJSON.utf8).write(to: tempURL)

        let store = TranscriptStore(storageURL: tempURL)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].text, "Alter Eintrag")
        XCTAssertEqual(store.entries[0].kind, .dictation)
        XCTAssertNil(store.entries[0].segments)
        XCTAssertNil(store.entries[0].speakerNames)
        XCTAssertNil(store.entries[0].summary)
    }

    func testMeetingFieldsRoundTrip() throws {
        // Festes Datum ohne Subsekunden: ISO8601 speichert nur ganze Sekunden.
        let entry = TranscriptEntry(
            createdAt: Date(timeIntervalSince1970: 1_770_000_000),
            workflowType: .transcription,
            text: "Meeting-Transkript",
            kind: .meeting,
            segments: [SpeakerSegment(speakerID: "speaker_0", text: "Hallo", start: 0)],
            speakerNames: ["speaker_0": "Marc"],
            summary: "Kurze Zusammenfassung"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([entry])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([TranscriptEntry].self, from: data)

        XCTAssertEqual(decoded, [entry])
        XCTAssertEqual(decoded[0].kind, .meeting)
        XCTAssertEqual(decoded[0].speakerNames?["speaker_0"], "Marc")
    }

    func testRenameSpeakerUpdatesNamesRerendersTextAndPersists() {
        let store = TranscriptStore(storageURL: tempURL)
        store.addMeeting(
            text: "Sprecher 1: Hallo\n\nSprecher 2: Moin",
            segments: [
                SpeakerSegment(speakerID: "speaker_0", text: "Hallo", start: 0),
                SpeakerSegment(speakerID: "speaker_1", text: "Moin", start: 2),
            ],
            title: "Test-Meeting",
            summary: nil
        )
        let entryID = store.entries[0].id

        let updated = store.rename(entryID: entryID, speakerID: "speaker_0", to: "Marc")

        XCTAssertEqual(updated?.speakerNames?["speaker_0"], "Marc")
        XCTAssertEqual(store.entries[0].text, "Marc: Hallo\n\nSprecher 2: Moin")

        let reloaded = TranscriptStore(storageURL: tempURL)
        XCTAssertEqual(reloaded.entries[0].speakerNames?["speaker_0"], "Marc")
        XCTAssertEqual(reloaded.entries[0].text, "Marc: Hallo\n\nSprecher 2: Moin")
    }

    func testRenameWithEmptyNameRemovesMappingAndRestoresNumber() {
        let store = TranscriptStore(storageURL: tempURL)
        store.addMeeting(
            text: "Sprecher 1: Hallo",
            segments: [SpeakerSegment(speakerID: "speaker_0", text: "Hallo", start: 0)],
            title: nil,
            summary: nil
        )
        let entryID = store.entries[0].id

        store.rename(entryID: entryID, speakerID: "speaker_0", to: "Marc")
        store.rename(entryID: entryID, speakerID: "speaker_0", to: "   ")

        XCTAssertNil(store.entries[0].speakerNames?["speaker_0"])
        XCTAssertEqual(store.entries[0].text, "Sprecher 1: Hallo")
    }

    func testRenameTitleTrimsPersistsAndReturnsUpdatedEntry() {
        let store = TranscriptStore(storageURL: tempURL)
        store.addMeeting(
            text: "Sprecher 1: Hallo",
            segments: [SpeakerSegment(speakerID: "speaker_0", text: "Hallo", start: 0)],
            title: "Alter Titel",
            summary: nil
        )
        let entryID = store.entries[0].id

        let updated = store.renameTitle(entryID: entryID, to: "  Neuer Titel  ")

        XCTAssertEqual(updated?.title, "Neuer Titel")
        XCTAssertEqual(store.entries[0].title, "Neuer Titel")

        let reloaded = TranscriptStore(storageURL: tempURL)
        XCTAssertEqual(reloaded.entries[0].title, "Neuer Titel")
    }

    func testRenameTitleIgnoresEmptyTitleAndUnknownID() {
        let store = TranscriptStore(storageURL: tempURL)
        store.addMeeting(
            text: "Sprecher 1: Hallo",
            segments: nil,
            title: "Bleibt",
            summary: nil
        )
        let entryID = store.entries[0].id

        XCTAssertNil(store.renameTitle(entryID: entryID, to: "   \n"))
        XCTAssertEqual(store.entries[0].title, "Bleibt")
        XCTAssertNil(store.renameTitle(entryID: UUID(), to: "Egal"))
    }

    func testSetExportFilenamePersists() {
        let store = TranscriptStore(storageURL: tempURL)
        store.addMeeting(text: "Sprecher 1: Hallo", segments: nil, title: "Test", summary: nil)
        let entryID = store.entries[0].id

        let updated = store.setExportFilename(entryID: entryID, filename: "2026-06-12_1430_test.md")

        XCTAssertEqual(updated?.exportFilename, "2026-06-12_1430_test.md")

        let reloaded = TranscriptStore(storageURL: tempURL)
        XCTAssertEqual(reloaded.entries[0].exportFilename, "2026-06-12_1430_test.md")
    }

    func testAddParticipantTrimsAppendsAndPersists() {
        let store = TranscriptStore(storageURL: tempURL)
        store.addMeeting(text: "Sprecher 1: Hallo", segments: nil, title: "Test", summary: nil)
        let entryID = store.entries[0].id

        let first = store.addParticipant(entryID: entryID, name: "  Thomas  ")
        let second = store.addParticipant(entryID: entryID, name: "Heidi")

        XCTAssertEqual(first?.extraParticipants, ["Thomas"])
        XCTAssertEqual(second?.extraParticipants, ["Thomas", "Heidi"])

        let reloaded = TranscriptStore(storageURL: tempURL)
        XCTAssertEqual(reloaded.entries[0].extraParticipants, ["Thomas", "Heidi"])
    }

    func testAddParticipantIgnoresEmptyNameDuplicatesAndUnknownID() {
        let store = TranscriptStore(storageURL: tempURL)
        store.addMeeting(text: "Sprecher 1: Hallo", segments: nil, title: "Test", summary: nil)
        let entryID = store.entries[0].id

        XCTAssertNil(store.addParticipant(entryID: entryID, name: "   \n"))
        store.addParticipant(entryID: entryID, name: "Thomas")
        // Duplikat case-insensitive: "thomas" wird nicht erneut aufgenommen.
        XCTAssertNil(store.addParticipant(entryID: entryID, name: "thomas"))
        XCTAssertEqual(store.entries[0].extraParticipants, ["Thomas"])
        XCTAssertNil(store.addParticipant(entryID: UUID(), name: "Egal"))
    }

    func testRemoveParticipantRemovesCaseInsensitiveAndPersists() {
        let store = TranscriptStore(storageURL: tempURL)
        store.addMeeting(text: "Sprecher 1: Hallo", segments: nil, title: "Test", summary: nil)
        let entryID = store.entries[0].id
        store.addParticipant(entryID: entryID, name: "Thomas")
        store.addParticipant(entryID: entryID, name: "Heidi")

        let updated = store.removeParticipant(entryID: entryID, name: "THOMAS")

        XCTAssertEqual(updated?.extraParticipants, ["Heidi"])

        let reloaded = TranscriptStore(storageURL: tempURL)
        XCTAssertEqual(reloaded.entries[0].extraParticipants, ["Heidi"])
    }

    func testRemoveLastParticipantClearsFieldAndUnknownNameReturnsNil() {
        let store = TranscriptStore(storageURL: tempURL)
        store.addMeeting(text: "Sprecher 1: Hallo", segments: nil, title: "Test", summary: nil)
        let entryID = store.entries[0].id
        store.addParticipant(entryID: entryID, name: "Thomas")

        XCTAssertNil(store.removeParticipant(entryID: entryID, name: "Unbekannt"))

        let updated = store.removeParticipant(entryID: entryID, name: "Thomas")
        XCTAssertNil(updated?.extraParticipants)
        XCTAssertNil(store.entries[0].extraParticipants)
    }

    func testDeleteRemovesEntry() {
        let store = TranscriptStore(storageURL: tempURL)
        store.add(text: "Bleibt", workflowType: .transcription)
        store.add(text: "Geht weg", workflowType: .transcription)
        store.delete(store.entries[0])
        XCTAssertEqual(store.entries.map(\.text), ["Bleibt"])
    }
}
