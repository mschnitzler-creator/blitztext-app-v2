import XCTest
@testable import Blitztext

final class MeetingTranscriptRendererTests: XCTestCase {
    func testRendersNumberedSpeakersInOrderOfFirstSpeech() {
        // speaker_0 spricht zuerst → "Sprecher 1", speaker_1 danach → "Sprecher 2".
        let segments = [
            SpeakerSegment(speakerID: "speaker_0", text: "Hallo zusammen", start: 0.0),
            SpeakerSegment(speakerID: "speaker_1", text: "Guten Morgen", start: 2.0),
            SpeakerSegment(speakerID: "speaker_0", text: "Fangen wir an", start: 4.0),
        ]

        let rendered = MeetingTranscriptRenderer.renderedText(from: segments)

        XCTAssertEqual(
            rendered,
            "Sprecher 1: Hallo zusammen\n\nSprecher 2: Guten Morgen\n\nSprecher 1: Fangen wir an"
        )
    }

    func testNumbersSpeakersByFirstSpeechTimeNotByID() {
        // Wenn speaker_1 zuerst redet, ist er trotzdem "Sprecher 1".
        let segments = [
            SpeakerSegment(speakerID: "speaker_1", text: "Ich starte", start: 0.0),
            SpeakerSegment(speakerID: "speaker_0", text: "Ich antworte", start: 3.0),
        ]

        let rendered = MeetingTranscriptRenderer.renderedText(from: segments)

        XCTAssertEqual(rendered, "Sprecher 1: Ich starte\n\nSprecher 2: Ich antworte")
    }

    func testEmptySegmentsRenderEmptyString() {
        XCTAssertEqual(MeetingTranscriptRenderer.renderedText(from: []), "")
    }

    func testAppliesSpeakerNamesAndKeepsNumbersForUnnamedSpeakers() {
        let segments = [
            SpeakerSegment(speakerID: "speaker_0", text: "Hallo", start: 0.0),
            SpeakerSegment(speakerID: "speaker_1", text: "Moin", start: 2.0),
        ]

        let rendered = MeetingTranscriptRenderer.renderedText(
            from: segments,
            names: ["speaker_0": "Marc"]
        )

        XCTAssertEqual(rendered, "Marc: Hallo\n\nSprecher 2: Moin")
    }

    func testCombinedParticipantsOrdersSpeakersFirstThenManualWithoutDuplicates() {
        // Sprecher nach Redereihenfolge, danach manuelle Teilnehmer in Eingabereihenfolge.
        let segments = [
            SpeakerSegment(speakerID: "speaker_1", text: "Ich starte", start: 0.0),
            SpeakerSegment(speakerID: "speaker_0", text: "Ich antworte", start: 3.0),
        ]

        let combined = MeetingTranscriptRenderer.combinedParticipants(
            segments: segments,
            names: ["speaker_1": "Thomas", "speaker_0": "Markus"],
            extraParticipants: ["Heidi", "markus", "Peter"]
        )

        // "markus" ist Duplikat des benannten Sprechers (case-insensitive) und fällt weg.
        XCTAssertEqual(combined, ["Thomas", "Markus", "Heidi", "Peter"])
    }

    func testCombinedParticipantsSkipsUnnamedSpeakersAndWorksWithoutSegments() {
        let segments = [
            SpeakerSegment(speakerID: "speaker_0", text: "Hallo", start: 0.0),
            SpeakerSegment(speakerID: "speaker_1", text: "Moin", start: 2.0),
        ]

        // Nur speaker_1 ist benannt, speaker_0 bleibt nummeriert und taucht nicht auf.
        XCTAssertEqual(
            MeetingTranscriptRenderer.combinedParticipants(
                segments: segments,
                names: ["speaker_1": "Heidi"],
                extraParticipants: nil
            ),
            ["Heidi"]
        )

        // Ohne Segmente (lokale Transkription) zählen nur die manuellen Teilnehmer.
        XCTAssertEqual(
            MeetingTranscriptRenderer.combinedParticipants(
                segments: [],
                names: nil,
                extraParticipants: ["Thomas"]
            ),
            ["Thomas"]
        )

        XCTAssertEqual(
            MeetingTranscriptRenderer.combinedParticipants(
                segments: [],
                names: nil,
                extraParticipants: nil
            ),
            []
        )
    }

    func testOrderedSpeakerIDsFollowFirstSpeechOrder() {
        let segments = [
            SpeakerSegment(speakerID: "speaker_1", text: "Ich starte", start: 0.0),
            SpeakerSegment(speakerID: "speaker_0", text: "Ich antworte", start: 3.0),
            SpeakerSegment(speakerID: "speaker_1", text: "Weiter", start: 5.0),
        ]

        XCTAssertEqual(
            MeetingTranscriptRenderer.orderedSpeakerIDs(for: segments),
            ["speaker_1", "speaker_0"]
        )
    }
}
