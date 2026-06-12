import XCTest
@testable import Blitztext

@MainActor
final class MeetingAppDetectorTests: XCTestCase {

    // MARK: - Bundle-ID-Matching

    func testIsMeetingAppErkenntBekannteBundleIDs() {
        XCTAssertEqual(MeetingAppDetector.isMeetingApp(bundleID: "us.zoom.xos"), "Zoom")
        XCTAssertEqual(MeetingAppDetector.isMeetingApp(bundleID: "com.microsoft.teams"), "Microsoft Teams")
        XCTAssertEqual(MeetingAppDetector.isMeetingApp(bundleID: "Cisco-Systems.Spark"), "Webex")
    }

    func testIsMeetingAppErkenntPraefixVariantenWieTeams2() {
        // Neues Teams meldet sich als com.microsoft.teams2: Präfix-Match muss greifen.
        XCTAssertEqual(MeetingAppDetector.isMeetingApp(bundleID: "com.microsoft.teams2"), "Microsoft Teams")
        XCTAssertEqual(MeetingAppDetector.isMeetingApp(bundleID: "us.zoom.xos.helper"), "Zoom")
    }

    func testIsMeetingAppIgnoriertUnbekannteBundleIDs() {
        XCTAssertNil(MeetingAppDetector.isMeetingApp(bundleID: "com.apple.Safari"))
        XCTAssertNil(MeetingAppDetector.isMeetingApp(bundleID: "com.microsoft.Word"))
        // Kein Match in falscher Richtung: Bundle-ID kürzer als das Präfix.
        XCTAssertNil(MeetingAppDetector.isMeetingApp(bundleID: "us.zoom"))
        XCTAssertNil(MeetingAppDetector.isMeetingApp(bundleID: ""))
    }

    // MARK: - Dedupe pro App-Lauf

    func testFeuertHoechstensEinmalProAppLauf() {
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        detector.isMeetingActive = { false }
        detector.onMeetingAppDetected = { detectedApps.append($0) }

        detector.handleAppLaunched(bundleID: "us.zoom.xos")
        detector.handleAppLaunched(bundleID: "us.zoom.xos")
        detector.handleAppLaunched(bundleID: "us.zoom.xos")

        XCTAssertEqual(detectedApps, ["Zoom"])
    }

    func testTerminateSetztDedupeFuerNeuenAppLaufZurueck() {
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        detector.isMeetingActive = { false }
        detector.onMeetingAppDetected = { detectedApps.append($0) }

        detector.handleAppLaunched(bundleID: "com.microsoft.teams2")
        detector.handleAppLaunched(bundleID: "com.microsoft.teams2")
        detector.handleAppTerminated(bundleID: "com.microsoft.teams2")
        detector.handleAppLaunched(bundleID: "com.microsoft.teams2")

        XCTAssertEqual(detectedApps, ["Microsoft Teams", "Microsoft Teams"])
    }

    func testKeinCallbackWaehrendLaufendemMeeting() {
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        detector.isMeetingActive = { true }
        detector.onMeetingAppDetected = { detectedApps.append($0) }

        detector.handleAppLaunched(bundleID: "us.zoom.xos")

        XCTAssertTrue(detectedApps.isEmpty)
    }

    func testUnbekannteAppLoestKeinenCallbackAus() {
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        detector.isMeetingActive = { false }
        detector.onMeetingAppDetected = { detectedApps.append($0) }

        detector.handleAppLaunched(bundleID: "com.apple.Safari")

        XCTAssertTrue(detectedApps.isEmpty)
    }

    // MARK: - Google Meet: Fenstertitel-Heuristik

    func testIsMeetWindowErkenntMeetTitelInBekanntenBrowsern() {
        XCTAssertTrue(MeetingAppDetector.isMeetWindow(
            ownerName: "Google Chrome", windowTitle: "Meet – abc-defg-hij"
        ))
        XCTAssertTrue(MeetingAppDetector.isMeetWindow(
            ownerName: "Safari", windowTitle: "Meet - abc-defg-hij"
        ))
        XCTAssertTrue(MeetingAppDetector.isMeetWindow(
            ownerName: "Arc", windowTitle: "Wochenplanung – Google Meet"
        ))
        XCTAssertTrue(MeetingAppDetector.isMeetWindow(
            ownerName: "Microsoft Edge", windowTitle: "Google Meet"
        ))
        XCTAssertTrue(MeetingAppDetector.isMeetWindow(
            ownerName: "Firefox", windowTitle: "Meet – xxx-yyyy-zzz"
        ))
        XCTAssertTrue(MeetingAppDetector.isMeetWindow(
            ownerName: "Brave Browser", windowTitle: "Meet - xxx-yyyy-zzz"
        ))
    }

    func testIsMeetWindowIgnoriertNichtBrowser() {
        XCTAssertFalse(MeetingAppDetector.isMeetWindow(
            ownerName: "Finder", windowTitle: "Google Meet"
        ))
        XCTAssertFalse(MeetingAppDetector.isMeetWindow(
            ownerName: "Slack", windowTitle: "Meet – abc-defg-hij"
        ))
        XCTAssertFalse(MeetingAppDetector.isMeetWindow(
            ownerName: "", windowTitle: "Google Meet"
        ))
    }

    func testIsMeetWindowIgnoriertTitelMitNurMeeting() {
        // "Meeting" allein ist kein Google Meet: kein Treffer.
        XCTAssertFalse(MeetingAppDetector.isMeetWindow(
            ownerName: "Google Chrome", windowTitle: "Meeting-Notizen – Google Docs"
        ))
        XCTAssertFalse(MeetingAppDetector.isMeetWindow(
            ownerName: "Safari", windowTitle: "Meeting - Agenda"
        ))
        XCTAssertFalse(MeetingAppDetector.isMeetWindow(
            ownerName: "Google Chrome", windowTitle: "Wöchentliches Meeting"
        ))
        XCTAssertFalse(MeetingAppDetector.isMeetWindow(
            ownerName: "Google Chrome", windowTitle: "Posteingang"
        ))
        XCTAssertFalse(MeetingAppDetector.isMeetWindow(
            ownerName: "Google Chrome", windowTitle: ""
        ))
    }

    // MARK: - Google Meet: Dedupe über injizierte Sichtungen

    func testMeetSichtungFeuertGenauEinmal() {
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        detector.isMeetingActive = { false }
        detector.onMeetingAppDetected = { detectedApps.append($0) }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        detector.processVisibleMeetWindows(found: true, now: start)
        detector.processVisibleMeetWindows(found: true, now: start.addingTimeInterval(5))
        detector.processVisibleMeetWindows(found: true, now: start.addingTimeInterval(10))

        XCTAssertEqual(detectedApps, ["Google Meet"])
    }

    func testMeetDedupeBleibtBeiKurzerAbwesenheitUnter60Sekunden() {
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        detector.isMeetingActive = { false }
        detector.onMeetingAppDetected = { detectedApps.append($0) }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        detector.processVisibleMeetWindows(found: true, now: start)
        // Tab kurz gewechselt: 30 s kein Meet-Fenster, dann wieder da.
        detector.processVisibleMeetWindows(found: false, now: start.addingTimeInterval(30))
        detector.processVisibleMeetWindows(found: true, now: start.addingTimeInterval(35))

        XCTAssertEqual(detectedApps, ["Google Meet"])
    }

    func testMeetFragtNach60SekundenOhneSichtungWieder() {
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        detector.isMeetingActive = { false }
        detector.onMeetingAppDetected = { detectedApps.append($0) }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        detector.processVisibleMeetWindows(found: true, now: start)
        // 60 s lang kein Meet-Fenster mehr: Dedupe wird zurückgesetzt.
        detector.processVisibleMeetWindows(found: false, now: start.addingTimeInterval(65))
        detector.processVisibleMeetWindows(found: true, now: start.addingTimeInterval(70))

        XCTAssertEqual(detectedApps, ["Google Meet", "Google Meet"])
    }

    // MARK: - Mikrofon-Signal: Dedupe über injizierte Werte

    func testMikroSignalFeuertGenauEinmal() {
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        detector.isMeetingActive = { false }
        detector.onMeetingAppDetected = { detectedApps.append($0) }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        detector.processMicrophoneSignal(
            meetingAppName: "Microsoft Teams", micInUse: true, ownAudioActive: false, now: start
        )
        detector.processMicrophoneSignal(
            meetingAppName: "Microsoft Teams", micInUse: true, ownAudioActive: false,
            now: start.addingTimeInterval(5)
        )
        detector.processMicrophoneSignal(
            meetingAppName: "Microsoft Teams", micInUse: true, ownAudioActive: false,
            now: start.addingTimeInterval(10)
        )

        XCTAssertEqual(detectedApps, ["Microsoft Teams"])
    }

    func testMikroSignalFeuertNichtWaehrendEigenerAufnahme() {
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        detector.isMeetingActive = { false }
        detector.onMeetingAppDetected = { detectedApps.append($0) }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        // Mikro ist an, aber durch die eigene Diktat-Aufnahme belegt: keine Nachfrage.
        detector.processMicrophoneSignal(
            meetingAppName: "Microsoft Teams", micInUse: true, ownAudioActive: true, now: start
        )

        XCTAssertTrue(detectedApps.isEmpty)
    }

    func testMikroSignalSchonfristNachEigenemDiktat() {
        // macOS gibt das Mikro nach einem Diktat verzögert frei: in den ersten
        // 10 s danach darf "Mikro aktiv" kein Banner auslösen (z. B. Wechsel zu Outlook nach eigenem Diktat).
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        detector.isMeetingActive = { false }
        detector.onMeetingAppDetected = { detectedApps.append($0) }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        // Eigenes Diktat läuft.
        detector.processMicrophoneSignal(
            meetingAppName: "Microsoft Teams", micInUse: true, ownAudioActive: true, now: start
        )
        // 5 s später: Diktat vorbei, Mikro hängt noch nach -> Schonfrist, kein Banner.
        detector.processMicrophoneSignal(
            meetingAppName: "Microsoft Teams", micInUse: true, ownAudioActive: false, now: start.addingTimeInterval(5)
        )
        XCTAssertTrue(detectedApps.isEmpty)

        // 15 s später: Schonfrist vorbei, Mikro weiter aktiv -> jetzt ist es ein Meeting-Signal.
        detector.processMicrophoneSignal(
            meetingAppName: "Microsoft Teams", micInUse: true, ownAudioActive: false, now: start.addingTimeInterval(15)
        )
        XCTAssertEqual(detectedApps, ["Microsoft Teams"])
    }

    func testMikroSignalDedupeResetErstNach60SekundenFreiemMikro() {
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        detector.isMeetingActive = { false }
        detector.onMeetingAppDetected = { detectedApps.append($0) }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        detector.processMicrophoneSignal(
            meetingAppName: "Microsoft Teams", micInUse: true, ownAudioActive: false, now: start
        )
        XCTAssertEqual(detectedApps, ["Microsoft Teams"])

        // Mikro nur 30 s frei: Dedupe bleibt, neue Aktivität feuert nicht.
        detector.processMicrophoneSignal(
            meetingAppName: "Microsoft Teams", micInUse: false, ownAudioActive: false,
            now: start.addingTimeInterval(30)
        )
        detector.processMicrophoneSignal(
            meetingAppName: "Microsoft Teams", micInUse: true, ownAudioActive: false,
            now: start.addingTimeInterval(35)
        )
        XCTAssertEqual(detectedApps, ["Microsoft Teams"])

        // Mikro 60 s frei: Dedupe wird zurückgesetzt, neue Aktivität feuert wieder.
        detector.processMicrophoneSignal(
            meetingAppName: "Microsoft Teams", micInUse: false, ownAudioActive: false,
            now: start.addingTimeInterval(100)
        )
        detector.processMicrophoneSignal(
            meetingAppName: "Microsoft Teams", micInUse: true, ownAudioActive: false,
            now: start.addingTimeInterval(105)
        )
        XCTAssertEqual(detectedApps, ["Microsoft Teams", "Microsoft Teams"])
    }

    func testMikroSignalFeuertNichtOhneLaufendeMeetingApp() {
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        detector.isMeetingActive = { false }
        detector.onMeetingAppDetected = { detectedApps.append($0) }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        // Mikro an (z. B. anderes Programm), aber keine Meeting-App läuft.
        detector.processMicrophoneSignal(
            meetingAppName: nil, micInUse: true, ownAudioActive: false, now: start
        )

        XCTAssertTrue(detectedApps.isEmpty)
    }

    func testMikroSignalFragtNachEigenemMeetingEndeWieder() {
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        var meetingActive = false
        detector.isMeetingActive = { meetingActive }
        detector.onMeetingAppDetected = { detectedApps.append($0) }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        detector.processMicrophoneSignal(
            meetingAppName: "Zoom", micInUse: true, ownAudioActive: false, now: start
        )
        XCTAssertEqual(detectedApps, ["Zoom"])

        // Eigenes Meeting läuft: keine Nachfrage.
        meetingActive = true
        detector.processMicrophoneSignal(
            meetingAppName: "Zoom", micInUse: true, ownAudioActive: false,
            now: start.addingTimeInterval(10)
        )
        XCTAssertEqual(detectedApps, ["Zoom"])

        // Meeting endete: neue Mikro-Aktivität darf wieder fragen.
        meetingActive = false
        detector.processMicrophoneSignal(
            meetingAppName: "Zoom", micInUse: true, ownAudioActive: false,
            now: start.addingTimeInterval(20)
        )
        XCTAssertEqual(detectedApps, ["Zoom", "Zoom"])
    }

    func testMikroPfadUndMeetPfadBlockierenSichNicht() {
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        detector.isMeetingActive = { false }
        detector.onMeetingAppDetected = { detectedApps.append($0) }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        // Mikro-Pfad feuert für Teams: blockiert den Meet-Fenster-Pfad nicht.
        detector.processMicrophoneSignal(
            meetingAppName: "Microsoft Teams", micInUse: true, ownAudioActive: false, now: start
        )
        detector.processVisibleMeetWindows(found: true, now: start.addingTimeInterval(5))

        XCTAssertEqual(detectedApps, ["Microsoft Teams", "Google Meet"])
    }

    func testMikrofonMonitorLiefertBoolOhneAbsturz() {
        // Echte CoreAudio-Abfrage: Ergebnis hängt von der Maschine ab,
        // wichtig ist nur, dass der Aufruf nicht crasht und Bool liefert.
        _ = MicrophoneActivityMonitor.isDefaultInputInUse()
    }

    func testMeetKeinCallbackWaehrendLaufendemMeetingAberNachEndeWieder() {
        let detector = MeetingAppDetector()
        var detectedApps: [String] = []
        var meetingActive = false
        detector.isMeetingActive = { meetingActive }
        detector.onMeetingAppDetected = { detectedApps.append($0) }
        let start = Date(timeIntervalSince1970: 1_770_000_000)

        detector.processVisibleMeetWindows(found: true, now: start)
        XCTAssertEqual(detectedApps, ["Google Meet"])

        // Meeting läuft: keine weiteren Nachfragen.
        meetingActive = true
        detector.processVisibleMeetWindows(found: true, now: start.addingTimeInterval(10))
        XCTAssertEqual(detectedApps, ["Google Meet"])

        // Meeting endete: nächste Sichtung darf wieder fragen.
        meetingActive = false
        detector.processVisibleMeetWindows(found: true, now: start.addingTimeInterval(20))
        XCTAssertEqual(detectedApps, ["Google Meet", "Google Meet"])
    }
}
