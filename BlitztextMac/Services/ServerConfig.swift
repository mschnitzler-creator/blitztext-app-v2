import Foundation

/// Basis-URL für alle Cloud-Aufrufe. Standard ist die offizielle OpenAI-API,
/// dann genügt ein OpenAI API Key und alles außer der Meeting-Transkription funktioniert.
///
/// Wer den optionalen Blitztext-Server betreibt (siehe server/README.md), trägt dessen
/// URL in den Einstellungen ein. Der Server schützt den OpenAI-Key (in der App steckt
/// dann nur ein App-Passwort) und stellt zusätzlich die Meeting-Route
/// `/v1/meeting/transcriptions` mit Sprechererkennung (ElevenLabs Scribe v2) bereit.
enum ServerConfig {
    static let defaultsKey = "serverBaseURL"
    static let openAIBaseURL = URL(string: "https://api.openai.com")!

    static var baseURL: URL {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return openAIBaseURL
        }
        let normalized = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard let url = URL(string: normalized),
              url.scheme == "https" || url.scheme == "http",
              url.host != nil else {
            return openAIBaseURL
        }
        return url
    }

    /// Eigener Server konfiguriert? Nur dann gibt es die Meeting-Route.
    static var isCustomServer: Bool { baseURL != openAIBaseURL }

    static var transcriptionsURL: URL { baseURL.appendingPathComponent("v1/audio/transcriptions") }
    static var chatCompletionsURL: URL { baseURL.appendingPathComponent("v1/chat/completions") }
    static var meetingTranscriptionsURL: URL { baseURL.appendingPathComponent("v1/meeting/transcriptions") }
}
