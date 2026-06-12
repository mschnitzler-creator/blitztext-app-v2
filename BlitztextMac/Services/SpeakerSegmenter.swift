import Foundation

/// Ein Wort-Token aus der fal.ai-Scribe-Antwort (Proxy-Route /v1/meeting/transcriptions).
struct FalWord: Codable, Equatable {
    let text: String
    /// "word", "spacing" oder "audio_event"
    let type: String
    let speakerID: String?
    let start: Double?
    let end: Double?

    enum CodingKeys: String, CodingKey {
        case text
        case type
        case speakerID = "speaker_id"
        case start
        case end
    }

    init(text: String, type: String, speakerID: String?, start: Double?, end: Double?) {
        self.text = text
        self.type = type
        self.speakerID = speakerID
        self.start = start
        self.end = end
    }
}

/// Zusammenhängender Redeabschnitt eines Sprechers.
struct SpeakerSegment: Codable, Equatable {
    let speakerID: String
    let text: String
    let start: Double
}

/// Gruppiert fal-Wort-Tokens zu Sprecher-Segmenten. Pure Funktion, kein Zustand.
enum SpeakerSegmenter {
    /// Pause zwischen zwei Wörtern, ab der ein neues Segment beginnt (Sekunden).
    static let pauseThreshold: Double = 2.0

    static func segments(from words: [FalWord]) -> [SpeakerSegment] {
        var result: [SpeakerSegment] = []
        var currentSpeaker: String?
        var currentText = ""
        var currentStart: Double = 0
        var lastWordEnd: Double?
        var pendingSpace = false

        func closeCurrentSegment() {
            defer {
                currentSpeaker = nil
                currentText = ""
                pendingSpace = false
            }
            guard let speaker = currentSpeaker else { return }
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            result.append(SpeakerSegment(speakerID: speaker, text: trimmed, start: currentStart))
        }

        for word in words {
            switch word.type {
            case "audio_event":
                // Geräusch-Marker (Lachen, Musik) gehören nicht ins Transkript.
                continue

            case "spacing":
                // Spacing wird zu genau einem Leerzeichen vor dem nächsten Wort.
                if currentSpeaker != nil {
                    pendingSpace = true
                }

            case "word":
                let speaker = word.speakerID ?? currentSpeaker ?? "speaker_0"
                let start = word.start ?? lastWordEnd ?? 0
                let pause = lastWordEnd.map { start - $0 } ?? 0

                if currentSpeaker == nil {
                    currentSpeaker = speaker
                    currentStart = start
                } else if speaker != currentSpeaker || pause > pauseThreshold {
                    closeCurrentSegment()
                    currentSpeaker = speaker
                    currentStart = start
                }

                if pendingSpace, !currentText.isEmpty {
                    currentText += " "
                }
                pendingSpace = false
                currentText += word.text
                lastWordEnd = word.end ?? start

            default:
                // Unbekannte Token-Typen ignorieren statt raten.
                continue
            }
        }

        closeCurrentSegment()
        return result
    }
}
