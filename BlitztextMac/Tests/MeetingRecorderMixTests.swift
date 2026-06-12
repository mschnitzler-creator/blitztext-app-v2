import AVFoundation
import XCTest
@testable import Blitztext

final class MeetingRecorderMixTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-mix-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tempDirectory)
        try super.tearDownWithError()
    }

    func testMixCombinesSystemAndMicTrackIntoM4A() async throws {
        let systemURL = tempDirectory.appendingPathComponent("system.caf")
        let micURL = tempDirectory.appendingPathComponent("mic.caf")
        let outputURL = tempDirectory.appendingPathComponent("meeting.m4a")

        // Zwei unterschiedlich lange Sinuston-Dateien: Mix muss die längere Dauer haben.
        try Self.writeSineFile(to: systemURL, frequency: 440, duration: 1.0)
        try Self.writeSineFile(to: micURL, frequency: 880, duration: 1.5)

        let duration = try await MeetingRecorder.mix(
            systemAudioURL: systemURL,
            microphoneURL: micURL,
            to: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThan(fileSize, 0)

        let mixedFile = try AVAudioFile(forReading: outputURL)
        let mixedDuration = Double(mixedFile.length) / mixedFile.processingFormat.sampleRate
        XCTAssertEqual(mixedDuration, 1.5, accuracy: 0.3)
        XCTAssertEqual(duration, 1.5, accuracy: 0.1)
    }

    func testMixFailsWithoutUsableTracks() async throws {
        let missingSystemURL = tempDirectory.appendingPathComponent("fehlt-system.caf")
        let missingMicURL = tempDirectory.appendingPathComponent("fehlt-mic.caf")
        let outputURL = tempDirectory.appendingPathComponent("meeting.m4a")

        do {
            _ = try await MeetingRecorder.mix(
                systemAudioURL: missingSystemURL,
                microphoneURL: missingMicURL,
                to: outputURL
            )
            XCTFail("mix muss ohne Audiospuren einen Fehler werfen")
        } catch let error as MeetingRecorderError {
            guard case .mixdownFailed = error else {
                XCTFail("Unerwarteter Fehler: \(error)")
                return
            }
        }
    }

    // MARK: - Helpers

    private static func writeSineFile(
        to url: URL,
        frequency: Double,
        duration: Double,
        sampleRate: Double = 48000
    ) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw NSError(domain: "MeetingRecorderMixTests", code: 1)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else {
            throw NSError(domain: "MeetingRecorderMixTests", code: 2)
        }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            samples[frame] = Float(sin(2.0 * .pi * frequency * Double(frame) / sampleRate)) * 0.5
        }
        try file.write(from: buffer)
    }
}
