import XCTest
@testable import Blitztext

final class SpeakerSegmenterTests: XCTestCase {
    private func word(
        _ text: String,
        type: String = "word",
        speaker: String? = "speaker_0",
        start: Double,
        end: Double
    ) -> FalWord {
        FalWord(text: text, type: type, speakerID: speaker, start: start, end: end)
    }

    func testGroupsWordsAndSplitsOnSpeakerChange() {
        let words: [FalWord] = [
            word("Hallo", speaker: "speaker_0", start: 0.0, end: 0.4),
            word(" ", type: "spacing", speaker: "speaker_0", start: 0.4, end: 0.5),
            word("zusammen", speaker: "speaker_0", start: 0.5, end: 1.0),
            word("Guten", speaker: "speaker_1", start: 1.2, end: 1.5),
            word(" ", type: "spacing", speaker: "speaker_1", start: 1.5, end: 1.6),
            word("Tag", speaker: "speaker_1", start: 1.6, end: 1.9),
        ]

        let segments = SpeakerSegmenter.segments(from: words)

        XCTAssertEqual(segments, [
            SpeakerSegment(speakerID: "speaker_0", text: "Hallo zusammen", start: 0.0),
            SpeakerSegment(speakerID: "speaker_1", text: "Guten Tag", start: 1.2),
        ])
    }

    func testSplitsOnPauseLongerThanTwoSeconds() {
        let words: [FalWord] = [
            word("Erster", speaker: "speaker_0", start: 0.0, end: 0.5),
            word(" ", type: "spacing", speaker: "speaker_0", start: 0.5, end: 0.6),
            word("Satz", speaker: "speaker_0", start: 0.6, end: 1.0),
            // Pause von 3,5 s beim selben Sprecher: muss splitten.
            word("Zweiter", speaker: "speaker_0", start: 4.5, end: 5.0),
            word(" ", type: "spacing", speaker: "speaker_0", start: 5.0, end: 5.1),
            word("Satz", speaker: "speaker_0", start: 5.1, end: 5.5),
        ]

        let segments = SpeakerSegmenter.segments(from: words)

        XCTAssertEqual(segments, [
            SpeakerSegment(speakerID: "speaker_0", text: "Erster Satz", start: 0.0),
            SpeakerSegment(speakerID: "speaker_0", text: "Zweiter Satz", start: 4.5),
        ])
    }

    func testIgnoresAudioEvents() {
        let words: [FalWord] = [
            word("Vor", speaker: "speaker_0", start: 0.0, end: 0.3),
            word("(lacht)", type: "audio_event", speaker: "speaker_0", start: 0.3, end: 1.1),
            word(" ", type: "spacing", speaker: "speaker_0", start: 1.1, end: 1.2),
            word("danach", speaker: "speaker_0", start: 1.2, end: 1.6),
        ]

        let segments = SpeakerSegmenter.segments(from: words)

        XCTAssertEqual(segments, [
            SpeakerSegment(speakerID: "speaker_0", text: "Vor danach", start: 0.0),
        ])
    }

    func testSpacingBecomesSingleSpaceAndIsTrimmedAtSegmentEnd() {
        let words: [FalWord] = [
            word("Eins", speaker: "speaker_0", start: 0.0, end: 0.3),
            word("\n", type: "spacing", speaker: "speaker_0", start: 0.3, end: 0.4),
            word("zwei", speaker: "speaker_0", start: 0.4, end: 0.7),
            // Spacing am Segmentende darf nicht als Leerzeichen hängen bleiben.
            word(" ", type: "spacing", speaker: "speaker_0", start: 0.7, end: 0.8),
            word("Drei", speaker: "speaker_1", start: 0.9, end: 1.2),
        ]

        let segments = SpeakerSegmenter.segments(from: words)

        XCTAssertEqual(segments, [
            SpeakerSegment(speakerID: "speaker_0", text: "Eins zwei", start: 0.0),
            SpeakerSegment(speakerID: "speaker_1", text: "Drei", start: 0.9),
        ])
    }
}
