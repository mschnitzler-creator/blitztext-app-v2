import Foundation

enum MeetingTranscriptionError: LocalizedError {
    case noFile
    case notConfigured
    case networkError(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .noFile:
            return "Keine Meeting-Aufnahme gefunden"
        case .notConfigured:
            return "App-Passwort fehlt. Bitte in den Einstellungen hinterlegen."
        case .networkError(let msg):
            return "Netzwerkfehler: \(msg)"
        case .apiError(let msg):
            return "Transkriptions-Fehler: \(msg)"
        }
    }
}

/// Antwort der Proxy-Route /v1/meeting/transcriptions (fal.ai Scribe v2, 1:1 durchgereicht).
struct MeetingTranscriptionResult: Decodable {
    let text: String
    let words: [FalWord]
}

private struct MeetingProxyErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}

/// Lädt eine fertige Meeting-m4a zum konfigurierten Blitztext-Server hoch und liefert das
/// Scribe-Ergebnis mit Sprecher-Wörtern. Löscht die Datei NICHT, der Workflow
/// entscheidet über Löschen (Erfolg) oder Retten (Fehler).
enum MeetingTranscriptionService {
    private static var endpointURL: URL { ServerConfig.meetingTranscriptionsURL }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Der Proxy pollt fal.ai bis zu 8 Minuten. Die App sieht nur einen langen POST.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()

    static func transcribe(audioURL: URL, language: String = "deu") async throws -> MeetingTranscriptionResult {
        guard let apiKey = KeychainService.load(key: .openAIAPIKey) else {
            throw MeetingTranscriptionError.notConfigured
        }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw MeetingTranscriptionError.noFile
        }
        guard ServerConfig.isCustomServer else {
            throw MeetingTranscriptionError.networkError(
                "Cloud-Meeting-Transkription braucht einen eigenen Blitztext-Server (siehe server/README.md). Alternativ: Modus 'Lokal' nutzen."
            )
        }

        return try await Task.detached(priority: .userInitiated) {
            guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
                throw MeetingTranscriptionError.networkError("Ungültige Proxy-URL")
            }
            components.queryItems = [URLQueryItem(name: "language", value: language)]
            guard let requestURL = components.url else {
                throw MeetingTranscriptionError.networkError("Ungültige Proxy-URL")
            }

            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 120
            request.cachePolicy = .reloadIgnoringLocalCacheData

            let audioData = try Data(contentsOf: audioURL, options: [.mappedIfSafe])

            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.upload(for: request, from: audioData)
            } catch {
                throw MeetingTranscriptionError.networkError(error.localizedDescription)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw MeetingTranscriptionError.networkError("Ungültige Antwort")
            }
            guard httpResponse.statusCode == 200 else {
                throw MeetingTranscriptionError.apiError(
                    proxyErrorMessage(from: data) ?? "Status \(httpResponse.statusCode)"
                )
            }

            do {
                return try JSONDecoder().decode(MeetingTranscriptionResult.self, from: data)
            } catch {
                throw MeetingTranscriptionError.apiError("Antwort nicht lesbar: \(error.localizedDescription)")
            }
        }.value
    }

    private static func proxyErrorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(MeetingProxyErrorResponse.self, from: data))?.error?.message
    }
}
