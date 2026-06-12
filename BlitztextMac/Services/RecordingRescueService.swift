import Foundation
import OSLog

private let rescueLogger = Logger(subsystem: "app.blitztext.mac", category: "RecordingRescue")

/// Verschiebt eine Aufnahme nach einem Fehler in den Ordner "gerettete-aufnahmen",
/// damit lange Diktate und Meetings nicht verloren gehen.
enum RecordingRescueService {
    static func rescue(recordingAt url: URL, filenamePrefix: String = "aufnahme") -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let rescueDirectory = AppSupportPaths.appSupportDirectoryURL
            .appendingPathComponent("gerettete-aufnahmen", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let targetURL = rescueDirectory.appendingPathComponent(
            "\(filenamePrefix)-\(formatter.string(from: Date())).m4a"
        )

        do {
            try FileManager.default.createDirectory(at: rescueDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: targetURL)
            return targetURL
        } catch {
            rescueLogger.error("Rescue failed: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }
}
