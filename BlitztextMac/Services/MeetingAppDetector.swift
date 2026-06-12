import AppKit
import Observation

/// Erkennt den Start bekannter Meeting-Apps über NSWorkspace und meldet sie per Callback.
/// Google Meet läuft im Browser ohne eigene Bundle-ID: dafür pollt ein Timer alle 5 s
/// die sichtbaren Fenstertitel (lesbar nur mit Bildschirmaufnahme-Berechtigung,
/// die die App fürs Meeting ohnehin hat; ohne Berechtigung läuft das Polling leer).
/// Apps wie Microsoft Teams laufen dauerhaft im Hintergrund, ihr Start löst nichts aus:
/// derselbe Timer prüft darum zusätzlich, ob eine bekannte Meeting-App läuft UND das
/// Standard-Mikrofon aktiv ist (ohne eigene Aufnahme), und meldet dann die App.
@Observable
@MainActor
final class MeetingAppDetector {
    /// Präfix-Match, damit Varianten wie com.microsoft.teams2 (neues Teams) mit abgedeckt sind.
    private static let knownApps: [(bundleIDPrefix: String, displayName: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("Cisco-Systems.Spark", "Webex"),
    ]

    /// Browser, in denen Google Meet laufen kann (kCGWindowOwnerName).
    private static let meetBrowsers: Set<String> = [
        "Google Chrome", "Safari", "Arc", "Microsoft Edge", "Firefox", "Brave Browser",
    ]

    /// Nach einem Prompt erst wieder fragen, wenn so lange kein Meet-Fenster zu sehen
    /// war (Meet-Pfad) bzw. das Mikrofon so lange frei war (Mikrofon-Pfad).
    private static let meetResetInterval: TimeInterval = 60

    /// Abstand zwischen zwei Fensterlisten-Abfragen.
    private static let meetPollInterval: TimeInterval = 5

    /// Feuert beim ersten erkannten Start einer Meeting-App (einmal pro App-Lauf).
    var onMeetingAppDetected: ((String) -> Void)?

    /// Injizierter Zustand: läuft gerade eine Meeting-Aufnahme? Dann keine Nachfrage.
    var isMeetingActive: (() -> Bool)?

    /// Injizierter Zustand: läuft gerade eine eigene Audio-Aufnahme (Diktat)?
    /// Dann ist das Mikrofon durch uns belegt und kein Hinweis auf ein Meeting.
    var isOwnAudioActive: (() -> Bool) = { false }

    /// Bundle-IDs, für die in diesem App-Lauf schon gemeldet wurde.
    /// Wird beim Beenden der jeweiligen App wieder geräumt.
    private var notifiedBundleIDs: Set<String> = []
    private var observers: [NSObjectProtocol] = []

    // Meet-Polling-Zustand
    private var meetPollTimer: Timer?
    private var hasNotifiedMeet = false
    private var lastMeetSightingAt: Date?
    private var meetingWasActive = false

    // Mikrofon-Polling-Zustand (eigener Dedupe, blockiert den Meet-Pfad nicht)
    private var hasNotifiedMic = false
    private var lastMicActivityAt: Date?
    private var micMeetingWasActive = false
    private var lastOwnAudioAt: Date?

    /// macOS gibt das Mikrofon nach eigenen Aufnahmen erst verzögert frei.
    /// Direkt nach einem Diktat ist "Mikro aktiv" darum kein Meeting-Signal.
    private static let ownAudioCooldown: TimeInterval = 10

    /// Liefert den Anzeigenamen, wenn die Bundle-ID zu einer bekannten Meeting-App gehört.
    static func isMeetingApp(bundleID: String) -> String? {
        for app in knownApps where bundleID.hasPrefix(app.bundleIDPrefix) {
            return app.displayName
        }
        return nil
    }

    /// Deutet ein sichtbares Fenster auf ein laufendes Google Meet hin?
    /// Treffer nur in bekannten Browsern, und nur wenn der Titel "Google Meet"
    /// enthält oder mit "Meet – "/"Meet - " beginnt (Meet-Tab-Titel sind
    /// "Meet – xxx-yyyy-zzz"). Das Wort "Meeting" allein ist KEIN Treffer.
    static func isMeetWindow(ownerName: String, windowTitle: String) -> Bool {
        guard meetBrowsers.contains(ownerName) else { return false }
        if windowTitle.contains("Google Meet") { return true }
        return windowTitle.hasPrefix("Meet \u{2013} ") || windowTitle.hasPrefix("Meet - ")
    }

    // MARK: - Observer-Lebenszyklus

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let bundleID = Self.bundleID(from: notification) else { return }
            Task { @MainActor [weak self] in
                self?.handleAppLaunched(bundleID: bundleID)
            }
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let bundleID = Self.bundleID(from: notification) else { return }
            Task { @MainActor [weak self] in
                self?.handleAppTerminated(bundleID: bundleID)
            }
        })

        startMeetPolling()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
        stopMeetPolling()
    }

    // MARK: - Kernlogik (testbar mit injizierten Events)

    func handleAppLaunched(bundleID: String) {
        guard let appName = Self.isMeetingApp(bundleID: bundleID) else { return }
        guard !notifiedBundleIDs.contains(bundleID) else { return }
        notifiedBundleIDs.insert(bundleID)

        guard !(isMeetingActive?() ?? false) else { return }
        onMeetingAppDetected?(appName)
    }

    func handleAppTerminated(bundleID: String) {
        notifiedBundleIDs.remove(bundleID)
    }

    /// Kernlogik des Meet-Pollings, testbar mit injizierten Sichtungen.
    /// Dedupe: Nach einem Prompt erst wieder fragen, wenn 60 s lang kein
    /// Meet-Fenster mehr zu sehen war oder ein Meeting lief und endete.
    func processVisibleMeetWindows(found: Bool, now: Date) {
        if isMeetingActive?() ?? false {
            // Während laufender Aufnahme keine Nachfrage, nur den Zustand merken.
            meetingWasActive = true
            return
        }

        if meetingWasActive {
            // Ein Meeting lief und endete: die nächste Sichtung darf wieder fragen.
            meetingWasActive = false
            hasNotifiedMeet = false
            lastMeetSightingAt = nil
        }

        if found {
            lastMeetSightingAt = now
            guard !hasNotifiedMeet else { return }
            hasNotifiedMeet = true
            onMeetingAppDetected?("Google Meet")
        } else if hasNotifiedMeet,
                  let lastSeen = lastMeetSightingAt,
                  now.timeIntervalSince(lastSeen) >= Self.meetResetInterval {
            hasNotifiedMeet = false
            lastMeetSightingAt = nil
        }
    }

    /// Kernlogik der Mikrofon-Erkennung, testbar mit injizierten Werten.
    /// Feuert, wenn eine bekannte Meeting-App läuft, das Standard-Mikrofon aktiv ist
    /// und weder ein eigenes Meeting noch eine eigene Diktat-Aufnahme läuft.
    /// Dedupe (getrennt vom Meet-Pfad): Nach einem Prompt erst wieder feuern, wenn
    /// das Mikrofon 60 s lang frei war oder ein eigenes Meeting lief und endete.
    func processMicrophoneSignal(
        meetingAppName: String?,
        micInUse: Bool,
        ownAudioActive: Bool,
        now: Date
    ) {
        if isMeetingActive?() ?? false {
            // Während laufender Aufnahme keine Nachfrage, nur den Zustand merken.
            micMeetingWasActive = true
            return
        }

        if micMeetingWasActive {
            // Ein Meeting lief und endete: neue Mikrofon-Aktivität darf wieder fragen.
            micMeetingWasActive = false
            hasNotifiedMic = false
            lastMicActivityAt = nil
        }

        if ownAudioActive {
            lastOwnAudioAt = now
        }

        if micInUse {
            // Mikro belegt (egal durch wen): zählt nicht als "frei" für den Reset.
            lastMicActivityAt = now
            let inOwnAudioCooldown = lastOwnAudioAt.map {
                now.timeIntervalSince($0) < Self.ownAudioCooldown
            } ?? false
            guard !ownAudioActive,
                  !inOwnAudioCooldown,
                  let appName = meetingAppName,
                  !hasNotifiedMic else { return }
            hasNotifiedMic = true
            onMeetingAppDetected?(appName)
        } else if hasNotifiedMic,
                  let lastActivity = lastMicActivityAt,
                  now.timeIntervalSince(lastActivity) >= Self.meetResetInterval {
            hasNotifiedMic = false
            lastMicActivityAt = nil
        }
    }

    // MARK: - Polling (Timer: Meet-Fenster + Mikrofon)

    private func startMeetPolling() {
        guard meetPollTimer == nil else { return }
        let timer = Timer(timeInterval: Self.meetPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollMeetWindows()
                self?.pollMicrophone()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meetPollTimer = timer
    }

    private func stopMeetPolling() {
        meetPollTimer?.invalidate()
        meetPollTimer = nil
    }

    private func pollMeetWindows() {
        // Während einer laufenden Aufnahme die Fensterliste gar nicht erst abfragen.
        let found = (isMeetingActive?() ?? false) ? false : Self.hasVisibleMeetWindow()
        processVisibleMeetWindows(found: found, now: Date())
    }

    private func pollMicrophone() {
        // Läuft nur, solange der Timer läuft (Detection enabled). Während einer
        // laufenden Aufnahme weder App-Liste noch CoreAudio abfragen.
        let meetingActive = isMeetingActive?() ?? false
        let appName = meetingActive ? nil : Self.runningMeetingAppName()
        let micInUse = meetingActive ? false : MicrophoneActivityMonitor.isDefaultInputInUse()
        processMicrophoneSignal(
            meetingAppName: appName,
            micInUse: micInUse,
            ownAudioActive: isOwnAudioActive(),
            now: Date()
        )
    }

    /// Anzeigename der ersten laufenden bekannten Meeting-App, sonst nil.
    private static func runningMeetingAppName() -> String? {
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier,
               let name = isMeetingApp(bundleID: bundleID) {
                return name
            }
        }
        return nil
    }

    /// Liest die sichtbaren Fenster über CGWindowList. Ohne Bildschirmaufnahme-
    /// Berechtigung fehlt kCGWindowName: dann gibt es nie einen Treffer, kein Fehler.
    private static func hasVisibleMeetWindow() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        return windows.contains { window in
            guard let ownerName = window[kCGWindowOwnerName as String] as? String,
                  let windowTitle = window[kCGWindowName as String] as? String else { return false }
            return isMeetWindow(ownerName: ownerName, windowTitle: windowTitle)
        }
    }

    private nonisolated static func bundleID(from notification: Notification) -> String? {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier
    }
}
