import AVFoundation
import Foundation
import OSLog
import ScreenCaptureKit

private let meetingLogger = Logger(subsystem: "app.blitztext.mac", category: "MeetingRecorder")

enum MeetingRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case noDisplay
    case screenCaptureUnavailable(String)
    case microphoneUnavailable(String)
    case mixdownFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Es läuft bereits eine Meeting-Aufnahme."
        case .notRecording:
            return "Es läuft keine Meeting-Aufnahme."
        case .noDisplay:
            return "Kein Display für die Systemaudio-Aufnahme gefunden."
        case .screenCaptureUnavailable(let msg):
            return "Systemaudio-Aufnahme nicht möglich: \(msg) "
                + "Bitte Bildschirmaufnahme für Blitztext erlauben: "
                + "Systemeinstellungen > Datenschutz & Sicherheit > Bildschirmaufnahme."
        case .microphoneUnavailable(let msg):
            return "Mikrofon-Aufnahme nicht möglich: \(msg)"
        case .mixdownFailed(let msg):
            return "Aufnahmen konnten nicht zusammengeführt werden: \(msg)"
        }
    }
}

/// Nimmt Systemaudio (ScreenCaptureKit) und Mikrofon (AVAudioEngine) parallel in zwei
/// caf-Dateien auf. `stop()` mischt beide Spuren zu einer m4a und liefert URL + Dauer.
final class MeetingRecorder: NSObject, SCStreamDelegate {
    private(set) var isRecording = false

    private var stream: SCStream?
    private var systemAudioWriter: SystemAudioWriter?
    private let sampleHandlerQueue = DispatchQueue(label: "app.blitztext.mac.meeting-system-audio")

    private var engine: AVAudioEngine?

    private var systemAudioURL: URL?
    private var microphoneURL: URL?
    private var startDate: Date?

    // MARK: - Start

    func start() async throws {
        guard !isRecording else { throw MeetingRecorderError.alreadyRecording }

        let tempDirectory = FileManager.default.temporaryDirectory
        let sessionID = UUID().uuidString
        let systemURL = tempDirectory.appendingPathComponent("meeting-system-\(sessionID).caf")
        let micURL = tempDirectory.appendingPathComponent("meeting-mic-\(sessionID).caf")

        // 1. Systemaudio über ScreenCaptureKit. Der erste Aufruf löst den macOS-Dialog
        //    "Bildschirmaufnahme erlauben" aus, darüber läuft die Systemaudio-Freigabe.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw MeetingRecorderError.screenCaptureUnavailable(error.localizedDescription)
        }
        guard let display = content.displays.first else {
            throw MeetingRecorderError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 1
        // Video wird nicht gebraucht, aber die Konfiguration verlangt eine Größe.
        configuration.width = 2
        configuration.height = 2

        let writer = SystemAudioWriter(fileURL: systemURL)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            // Nur Audio-Output anhängen, kein Video-Output.
            try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: sampleHandlerQueue)
            try await stream.startCapture()
        } catch {
            throw MeetingRecorderError.screenCaptureUnavailable(error.localizedDescription)
        }

        // 2. Mikrofon parallel über AVAudioEngine-Tap in eine zweite caf-Datei.
        let engine = AVAudioEngine()
        do {
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw MeetingRecorderError.microphoneUnavailable("Kein Eingabegerät gefunden.")
            }
            let micFile = try AVAudioFile(
                forWriting: micURL,
                settings: format.settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                do {
                    try micFile.write(from: buffer)
                } catch {
                    meetingLogger.error("Mikrofon-Schreibfehler: \(error.localizedDescription, privacy: .private)")
                }
            }
            engine.prepare()
            try engine.start()
        } catch let error as MeetingRecorderError {
            try? await stream.stopCapture()
            throw error
        } catch {
            try? await stream.stopCapture()
            throw MeetingRecorderError.microphoneUnavailable(error.localizedDescription)
        }

        self.stream = stream
        self.systemAudioWriter = writer
        self.engine = engine
        self.systemAudioURL = systemURL
        self.microphoneURL = micURL
        self.startDate = Date()
        isRecording = true
        meetingLogger.info("Meeting-Aufnahme gestartet")
    }

    // MARK: - Stop

    /// Beendet die Aufnahme, mischt System- und Mikrofonspur zu einer m4a in temp.
    func stop() async throws -> (audioURL: URL, duration: TimeInterval) {
        guard isRecording else { throw MeetingRecorderError.notRecording }
        isRecording = false

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        // Datei-Handle des System-Writers auf der sampleHandlerQueue schließen,
        // damit kein Buffer mehr nach dem Schließen geschrieben wird.
        sampleHandlerQueue.sync { [systemAudioWriter] in
            systemAudioWriter?.finish()
        }
        systemAudioWriter = nil

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }

        guard let systemAudioURL, let microphoneURL else {
            throw MeetingRecorderError.mixdownFailed("Aufnahmedateien fehlen.")
        }
        let recordingSeconds = startDate.map { Date().timeIntervalSince($0) } ?? 0
        startDate = nil

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-\(UUID().uuidString).m4a")

        defer {
            try? FileManager.default.removeItem(at: systemAudioURL)
            try? FileManager.default.removeItem(at: microphoneURL)
            self.systemAudioURL = nil
            self.microphoneURL = nil
        }

        let duration = try await Self.mix(
            systemAudioURL: systemAudioURL,
            microphoneURL: microphoneURL,
            to: outputURL
        )
        meetingLogger.info("Meeting-Aufnahme beendet: \(Int(recordingSeconds)) s aufgenommen, Mix \(Int(duration)) s")
        return (outputURL, duration)
    }

    /// Bricht die Aufnahme ab und verwirft beide Spuren ohne Mixdown.
    func discard() async {
        isRecording = false
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        sampleHandlerQueue.sync { [systemAudioWriter] in
            systemAudioWriter?.finish()
        }
        systemAudioWriter = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        if let systemAudioURL {
            try? FileManager.default.removeItem(at: systemAudioURL)
            self.systemAudioURL = nil
        }
        if let microphoneURL {
            try? FileManager.default.removeItem(at: microphoneURL)
            self.microphoneURL = nil
        }
        startDate = nil
    }

    // MARK: - Mixdown

    /// Mischt zwei Audiodateien über AVMutableComposition zu einer m4a.
    /// Statisch und ohne Instanz-Zustand, damit der Mixdown im Unit-Test prüfbar ist.
    /// Rückgabe: Dauer der längeren Spur in Sekunden.
    static func mix(systemAudioURL: URL, microphoneURL: URL, to outputURL: URL) async throws -> TimeInterval {
        let composition = AVMutableComposition()
        var maxDuration = CMTime.zero

        for sourceURL in [systemAudioURL, microphoneURL] {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
            let asset = AVURLAsset(url: sourceURL)
            guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first else { continue }
            let assetDuration = try await asset.load(.duration)
            guard assetDuration > .zero else { continue }
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                throw MeetingRecorderError.mixdownFailed("Audiospur konnte nicht angelegt werden.")
            }
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: assetDuration),
                of: assetTrack,
                at: .zero
            )
            maxDuration = CMTimeMaximum(maxDuration, assetDuration)
        }

        guard !composition.tracks.isEmpty else {
            throw MeetingRecorderError.mixdownFailed("Keine verwertbare Audiospur vorhanden.")
        }

        // Sprachoptimierter Export statt AVAssetExportPresetAppleM4A (~128 kbps):
        // mono, 16 kHz, AAC 32 kbps. Das reicht für die Transkription (Scribe/Whisper
        // rechnen ohnehin auf 16 kHz herunter) und hält die Datei klein (~14 MB/h statt
        // ~58 MB/h), damit lange Meetings nicht am Upload-/Body-Limit scheitern.
        try await Self.exportSpeechM4A(composition: composition, to: outputURL)

        return maxDuration.seconds
    }

    /// Liest die gemischte Komposition als PCM und schreibt sie als sprachoptimierte
    /// AAC-m4a (mono, 16 kHz, 32 kbps) über AVAssetReader/AVAssetWriter. Ein Export-Preset
    /// lässt die Bitrate nicht einstellen, darum der manuelle Reader-zu-Writer-Pfad.
    private static func exportSpeechM4A(composition: AVComposition, to outputURL: URL) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        let audioTracks = composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw MeetingRecorderError.mixdownFailed("Keine verwertbare Audiospur vorhanden.")
        }

        let reader = try AVAssetReader(asset: composition)
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        // Audio-Mix-Output summiert die parallelen Spuren (System + Mikrofon) zu einer.
        let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: pcmSettings)
        mixOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(mixOutput) else {
            throw MeetingRecorderError.mixdownFailed("Audio-Mix-Output konnte nicht erstellt werden.")
        }
        reader.add(mixOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw MeetingRecorderError.mixdownFailed("Audio-Writer-Input konnte nicht erstellt werden.")
        }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw MeetingRecorderError.mixdownFailed(reader.error?.localizedDescription ?? "Lesen fehlgeschlagen.")
        }
        guard writer.startWriting() else {
            throw MeetingRecorderError.mixdownFailed(writer.error?.localizedDescription ?? "Schreiben fehlgeschlagen.")
        }
        writer.startSession(atSourceTime: .zero)

        let queue = DispatchQueue(label: "app.blitztext.mac.meeting-export")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard let buffer = mixOutput.copyNextSampleBuffer() else {
                        // Quelle erschöpft: Reader-Status prüfen, dann sauber abschließen.
                        if reader.status == .failed {
                            continuation.resume(throwing: MeetingRecorderError.mixdownFailed(
                                reader.error?.localizedDescription ?? "Lesen fehlgeschlagen."))
                            return
                        }
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: MeetingRecorderError.mixdownFailed(
                                    writer.error?.localizedDescription ?? "Export abgebrochen."))
                            }
                        }
                        return
                    }
                    if !writerInput.append(buffer) {
                        reader.cancelReading()
                        continuation.resume(throwing: MeetingRecorderError.mixdownFailed(
                            writer.error?.localizedDescription ?? "Audio-Append fehlgeschlagen."))
                        return
                    }
                }
            }
        }
    }

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        meetingLogger.error("SCStream gestoppt: \(error.localizedDescription, privacy: .private)")
    }
}

// MARK: - SystemAudioWriter

/// Schreibt SCStream-Audio-Buffer in eine caf-Datei. Lebt komplett auf der
/// sampleHandlerQueue, die Datei wird lazy aus dem Format des ersten Buffers erzeugt.
private final class SystemAudioWriter: NSObject, SCStreamOutput {
    private let fileURL: URL
    private var audioFile: AVAudioFile?
    private var loggedWriteError = false

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let pcmBuffer = Self.pcmBuffer(from: sampleBuffer) else { return }

        do {
            if audioFile == nil {
                audioFile = try AVAudioFile(
                    forWriting: fileURL,
                    settings: pcmBuffer.format.settings,
                    commonFormat: pcmBuffer.format.commonFormat,
                    interleaved: pcmBuffer.format.isInterleaved
                )
            }
            try audioFile?.write(from: pcmBuffer)
        } catch {
            if !loggedWriteError {
                loggedWriteError = true
                meetingLogger.error("Systemaudio-Schreibfehler: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Schließt die Datei. Muss auf der sampleHandlerQueue laufen.
    func finish() {
        audioFile = nil
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = sampleBuffer.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }
}
