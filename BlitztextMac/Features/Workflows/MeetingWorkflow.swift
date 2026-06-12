import Foundation
import Observation
import OSLog

private let meetingWorkflowLogger = Logger(subsystem: "app.blitztext.mac", category: "MeetingWorkflow")

/// Transkriptionsweg für Meetings: Cloud (Scribe v2 mit Sprechern) oder lokal (WhisperKit, ohne Sprecher).
enum MeetingMode: String, Codable {
    case cloud
    case local
}

enum MeetingPhase: Equatable {
    case idle
    case recording(since: Date)
    case transcribing
    case done
    case error(String)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

/// Steuert eine Meeting-Aufnahme von Start bis Verlauf-Eintrag.
/// Bewusst KEIN `Workflow`-Protokoll und keine `WorkflowType`-Erweiterung:
/// Meetings laufen unabhängig von der Hotkey-/Menü-Logik der Diktate.
@Observable
@MainActor
final class MeetingWorkflow {
    private(set) var phase: MeetingPhase = .idle {
        didSet {
            guard oldValue != phase else { return }
            onPhaseChange?(phase)
        }
    }
    var onPhaseChange: ((MeetingPhase) -> Void)?

    /// Liefert die aktuelle Export-Konfiguration (Second Brain) zum Zeitpunkt des Speicherns.
    /// Wird von AppState gesetzt, damit der Workflow keine Settings-Abhängigkeit braucht.
    var exportConfiguration: (() -> (enabled: Bool, folderPath: String))?

    private let recorder = MeetingRecorder()
    private var mode: MeetingMode = .cloud
    private var language: String = "de"
    private var localModelName: String = LocalTranscriptionService.recommendedFastModelName
    private var isStarting = false

    var isRecording: Bool { phase.isRecording }

    // MARK: - Steuerung

    func start(mode: MeetingMode, language: String, localModelName: String) {
        guard case .idle = phase, !isStarting else { return }
        self.mode = mode
        self.language = language
        self.localModelName = localModelName
        isStarting = true

        Task {
            defer { isStarting = false }
            do {
                // Erste Nutzung löst den macOS-Dialog "Bildschirmaufnahme erlauben" aus.
                try await recorder.start()
                phase = .recording(since: Date())
            } catch {
                phase = .error(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard case .recording = phase else { return }
        phase = .transcribing
        Task { await processRecording() }
    }

    /// Abbruch während der Aufnahme: beide Spuren verwerfen, kein Mixdown.
    func cancel() {
        guard case .recording = phase else { return }
        phase = .idle
        Task { await recorder.discard() }
    }

    /// Done-/Error-Anzeige bestätigt: zurück auf idle.
    func acknowledge() {
        switch phase {
        case .done, .error:
            phase = .idle
        default:
            break
        }
    }

    // MARK: - Verarbeitung

    private func processRecording() async {
        let audioURL: URL
        let duration: TimeInterval
        do {
            let result = try await recorder.stop()
            audioURL = result.audioURL
            duration = result.duration
        } catch {
            meetingWorkflowLogger.error("Meeting-Stop fehlgeschlagen: \(error.localizedDescription, privacy: .private)")
            phase = .error(error.localizedDescription)
            return
        }

        do {
            switch mode {
            case .cloud:
                try await transcribeCloud(audioURL: audioURL, duration: duration)
            case .local:
                try await transcribeLocal(audioURL: audioURL, duration: duration)
            }
            // Erfolg: m4a wird nicht mehr gebraucht.
            try? FileManager.default.removeItem(at: audioURL)
            phase = .done
        } catch {
            meetingWorkflowLogger.error("Meeting-Transkription fehlgeschlagen: \(error.localizedDescription, privacy: .private)")
            // Aufnahme NICHT löschen: in gerettete-aufnahmen verschieben, damit nichts verloren ist.
            if let rescuedURL = RecordingRescueService.rescue(recordingAt: audioURL, filenamePrefix: "meeting") {
                phase = .error("\(error.localizedDescription) – Aufnahme gesichert unter: \(rescuedURL.path)")
            } else {
                phase = .error(error.localizedDescription)
            }
        }
    }

    private func transcribeCloud(audioURL: URL, duration: TimeInterval) async throws {
        let result = try await MeetingTranscriptionService.transcribe(audioURL: audioURL)
        let segments = SpeakerSegmenter.segments(from: result.words)
        let text = segments.isEmpty
            ? result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            : MeetingTranscriptRenderer.renderedText(from: segments)
        guard !text.isEmpty else {
            throw MeetingTranscriptionError.apiError("Keine Sprache im Meeting erkannt.")
        }

        // Zusammenfassungs-Fehler ist nicht fatal: Eintrag dann ohne Titel/Zusammenfassung.
        let title: String?
        let summary: String?
        do {
            let result = try await Self.summarize(transcript: text)
            title = result.title
            summary = result.summary
        } catch {
            meetingWorkflowLogger.error("Meeting-Zusammenfassung fehlgeschlagen: \(error.localizedDescription, privacy: .private)")
            title = nil
            summary = nil
        }

        let entry = TranscriptStore.shared.addMeeting(
            text: text,
            segments: segments.isEmpty ? nil : segments,
            title: title,
            summary: summary,
            durationSeconds: duration > 0 ? duration : nil
        )
        exportToSecondBrain(entry)
    }

    /// Titel + Zusammenfassung über den LLM-Proxy.
    private static func summarize(transcript: String) async throws -> (title: String?, summary: String?) {
        let result = try await LLMService.summarizeMeeting(transcript: transcript)
        return (
            result.title.isEmpty ? nil : result.title,
            result.summary.isEmpty ? nil : result.summary
        )
    }

    private func transcribeLocal(audioURL: URL, duration: TimeInterval) async throws {
        // Lokal heißt lokal: kein LLM-Call für Zusammenfassung, keine Sprecher.
        let text = try await LocalTranscriptionService.shared.transcribe(
            audioURL: audioURL,
            language: language,
            modelName: localModelName
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw MeetingTranscriptionError.apiError("Keine Sprache im Meeting erkannt.")
        }

        let entry = TranscriptStore.shared.addMeeting(
            text: text,
            segments: nil,
            title: nil,
            summary: nil,
            durationSeconds: duration > 0 ? duration : nil
        )
        exportToSecondBrain(entry)
    }

    /// Schreibt den Eintrag als Markdown ins Second Brain, wenn der Export aktiviert
    /// und ein Ordner gewählt ist. Fehler sind nicht fatal: der Verlauf-Eintrag bleibt,
    /// der Fehler landet nur im Log und nie im Phase-Text des Erfolgspfads.
    private func exportToSecondBrain(_ entry: TranscriptEntry?) {
        guard let entry,
              let config = exportConfiguration?(),
              config.enabled else { return }
        let folderPath = config.folderPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderPath.isEmpty else { return }

        do {
            let url = try SecondBrainExporter.export(entry: entry, toFolder: folderPath)
            // Dateinamen am Eintrag merken: Re-Exporte nach Umbenennung finden so die alte Datei.
            TranscriptStore.shared.setExportFilename(entryID: entry.id, filename: url.lastPathComponent)
            meetingWorkflowLogger.info("Second-Brain-Export geschrieben: \(url.lastPathComponent, privacy: .public)")
        } catch {
            meetingWorkflowLogger.error("Second-Brain-Export fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
        }
    }
}
