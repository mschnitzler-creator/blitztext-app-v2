import Foundation

enum LLMError: LocalizedError {
    case notConfigured
    case networkError(String)
    case apiError(String)
    case noContent

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "OpenAI API Key fehlt. Bitte in den Einstellungen hinterlegen."
        case .networkError(let msg):
            return "Verbindungsproblem: \(msg)"
        case .apiError(let msg):
            return "Fehler von OpenAI: \(msg)"
        case .noContent:
            return "Keine Antwort erhalten. Bitte nochmal versuchen."
        }
    }
}

enum RewriteModel: String {
    case fastEdit = "gpt-4o-mini"
    case rageMode = "gpt-4o"
}

private struct OpenAIChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    struct ResponseFormat: Encodable {
        let type: String

        static let jsonObject = ResponseFormat(type: "json_object")
    }

    let model: String
    let messages: [Message]
    let temperature: Double
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case responseFormat = "response_format"
    }
}

private struct OpenAIChatResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String?
        }

        let message: Message?
    }

    let choices: [Choice]?
}

private struct MeetingSummaryPayload: Decodable {
    let title: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case title
        case summary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        // summary kann trotz JSON-Vorgabe als Array kommen: beides akzeptieren.
        if let text = try? container.decodeIfPresent(String.self, forKey: .summary) {
            summary = text
        } else if let lines = try? container.decodeIfPresent([String].self, forKey: .summary) {
            summary = lines
                .map { $0.hasPrefix("-") ? $0 : "- \($0)" }
                .joined(separator: "\n")
        } else {
            summary = nil
        }
    }
}

private struct OpenAIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}

enum LLMService {
    private static var chatCompletionsURL: URL { ServerConfig.chatCompletionsURL }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Lange Texte: LLM-Antworten können bei langen Diktaten >45s dauern.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    static func improve(
        text: String,
        settings: TextImprovementSettings,
        model: RewriteModel = .fastEdit
    ) async throws -> String {
        try await complete(
            text: text,
            systemPrompt: buildSystemPrompt(settings: settings),
            model: model,
            temperature: 0.3
        )
    }

    static func dampfAblassen(
        text: String,
        systemPrompt: String,
        model: RewriteModel = .rageMode
    ) async throws -> String {
        try await complete(
            text: text,
            systemPrompt: systemPrompt,
            model: model,
            temperature: 0.4
        )
    }

    static func addEmojis(
        text: String,
        settings: EmojiTextSettings,
        model: RewriteModel = .fastEdit
    ) async throws -> String {
        try await complete(
            text: text,
            systemPrompt: buildEmojiSystemPrompt(density: settings.emojiDensity),
            model: model,
            temperature: 0.3
        )
    }

    /// Erstellt Titel und Zusammenfassung für ein Meeting-Transkript.
    /// Ein Chat-Call, Antwort als JSON {"title": "...", "summary": "..."} erzwungen.
    static func summarizeMeeting(transcript: String) async throws -> (title: String, summary: String) {
        let systemPrompt = """
        Du fasst Meeting-Transkripte zusammen. Antworte ausschließlich mit einem JSON-Objekt \
        im Format {"title": "...", "summary": "..."}.
        - title: prägnanter Titel des Meetings, maximal 60 Zeichen.
        - summary: 5 bis 10 Stichpunkte, je Zeile einer, beginnend mit "- ". \
        Inhalt: getroffene Entscheidungen, Aufgaben mit Namen der Verantwortlichen, offene Punkte.
        Keine Erklärungen außerhalb des JSON.
        """

        let content = try await complete(
            text: truncatedTranscript(transcript),
            systemPrompt: systemPrompt,
            model: .fastEdit,
            temperature: 0.2,
            responseFormat: .jsonObject
        )

        guard let parsed = parseMeetingSummary(from: content) else {
            throw LLMError.apiError("Zusammenfassung nicht lesbar.")
        }
        return (String(parsed.title.prefix(60)), parsed.summary)
    }

    /// Über 100.000 Zeichen: nur Anfang und Ende senden, je 40.000 Zeichen.
    static func truncatedTranscript(_ transcript: String, limit: Int = 100_000, partLength: Int = 40_000) -> String {
        guard transcript.count > limit else { return transcript }
        return String(transcript.prefix(partLength))
            + "\n\n[Mittelteil gekürzt]\n\n"
            + String(transcript.suffix(partLength))
    }

    private static func parseMeetingSummary(from content: String) -> (title: String, summary: String)? {
        let candidates = [content, extractedJSONObject(from: content)].compactMap { $0 }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let payload = try? JSONDecoder().decode(MeetingSummaryPayload.self, from: data) else {
                continue
            }
            let title = (payload.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = (payload.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty || !summary.isEmpty {
                return (title, summary)
            }
        }
        return nil
    }

    /// Robustes Fallback-Parsing: JSON-Objekt aus umgebendem Text herauslösen
    /// (z. B. wenn das Modell Markdown-Zäune um die Antwort legt).
    private static func extractedJSONObject(from text: String) -> String? {
        guard let first = text.firstIndex(of: "{"),
              let last = text.lastIndex(of: "}"),
              first < last else {
            return nil
        }
        return String(text[first...last])
    }

    private static func complete(
        text: String,
        systemPrompt: String,
        model: RewriteModel,
        temperature: Double,
        responseFormat: OpenAIChatRequest.ResponseFormat? = nil
    ) async throws -> String {
        guard let apiKey = KeychainService.load(key: .openAIAPIKey) else {
            throw LLMError.notConfigured
        }

        let payload = OpenAIChatRequest(
            model: model.rawValue,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: text),
            ],
            temperature: temperature,
            responseFormat: responseFormat
        )

        var request = URLRequest(url: chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.networkError("Keine gültige Antwort")
        }

        guard httpResponse.statusCode == 200 else {
            throw LLMError.apiError(openAIErrorMessage(from: data) ?? "Status \(httpResponse.statusCode)")
        }

        let result = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let content = result.choices?.first?.message?.content,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.noContent
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func openAIErrorMessage(from data: Data) -> String? {
        (try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data))?.error?.message
    }

    private static func buildEmojiSystemPrompt(density: EmojiTextSettings.EmojiDensity) -> String {
        let densityInstruction: String
        switch density {
        case .wenig:
            densityInstruction = "Setze nur vereinzelt Emojis ein, maximal 1-2 pro Absatz."
        case .mittel:
            densityInstruction = "Setze regelmaessig passende Emojis ein, etwa alle 1-2 Saetze."
        case .viel:
            densityInstruction = "Setze grosszuegig Emojis ein, gerne mehrere pro Satz."
        }

        return "Du erhaeltst ein gesprochenes Transkript. Gib den Text moeglichst originalgetreu zurueck, aber fuege passende Emojis ein. \(densityInstruction) Korrigiere offensichtliche Sprach- und Grammatikfehler. Behalte den Stil und die Bedeutung bei. Gib NUR den Text mit Emojis zurueck, keine Erklaerungen."
    }

    private static func buildSystemPrompt(settings: TextImprovementSettings) -> String {
        if !settings.systemPrompt.isEmpty {
            var prompt = settings.systemPrompt
            if !settings.customTerms.isEmpty {
                prompt += "\n\nWichtig: Diese Eigennamen und Fachbegriffe muessen exakt so geschrieben werden: \(settings.customTerms.joined(separator: ", "))"
            }
            return prompt
        }

        var prompt = """
        Du bist ein Lektor und Schreibassistent. Verbessere den folgenden Text:
        - Korrigiere Rechtschreibung und Grammatik
        - Verbessere die Formulierung und den Lesefluss
        - Behalte die urspruengliche Bedeutung bei
        - Gib NUR den verbesserten Text zurueck, keine Erklaerungen
        """

        switch settings.tone {
        case .formal:
            prompt += "\n- Verwende einen formellen, professionellen Ton"
        case .neutral:
            prompt += "\n- Verwende einen neutralen, klaren Ton"
        case .casual:
            prompt += "\n- Verwende einen lockeren, natuerlichen Ton"
        case .email:
            prompt += "\n- Formatiere den Text als versandfertige E-Mail mit sinnvollen Absaetzen"
            prompt += "\n- Ergaenze Anrede und Grussformel nur, wenn aus dem Diktat erkennbar ist, an wen die E-Mail geht"
            prompt += "\n- Uebernimm Du oder Sie genau so, wie es im Diktat verwendet wird"
            prompt += "\n- Erfinde keine Inhalte, die nicht im Diktat stehen"
            prompt += "\n- Keine Betreffzeile, ausser sie wird ausdruecklich diktiert"
        }

        if !settings.customTerms.isEmpty {
            prompt += "\n\nWichtig: Diese Eigennamen und Fachbegriffe muessen exakt so geschrieben werden: \(settings.customTerms.joined(separator: ", "))"
        }

        if !settings.context.isEmpty {
            prompt += "\n\nKontext: \(settings.context)"
        }

        return prompt
    }
}
