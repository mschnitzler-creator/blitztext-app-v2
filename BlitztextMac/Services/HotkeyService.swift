import Cocoa
import Observation

enum HotkeyMode: String, Codable, CaseIterable, Identifiable {
    case hold    // Tasten halten = aufnehmen, loslassen = stoppen
    case toggle  // Einmal drücken = starten, nochmal/Escape = stoppen

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold: return "Halten"
        case .toggle: return "Drücken"
        }
    }

    var description: String {
        switch self {
        case .hold: return "Tasten halten zum Aufnehmen, loslassen zum Stoppen"
        case .toggle: return "Einmal drücken zum Starten, nochmal oder Escape zum Stoppen"
        }
    }
}

enum HotkeyEvent {
    case down(WorkflowType)  // Keys pressed
    case up(WorkflowType)    // Keys released (for hold mode)
    case cancel              // Escape pressed
}

// C-Callback für den F13-Event-Tap. Muss auf Dateiebene liegen (C-Funktionszeiger).
// Der Tap hängt am Main-RunLoop, der Callback läuft also auf dem Main-Thread.
private func f13TapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<HotkeyService>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { service.reenableF13Tap() }
        return Unmanaged.passUnretained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    guard keyCode == 105 else { return Unmanaged.passUnretained(event) }

    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let isDown = type == .keyDown
    MainActor.assumeIsolated {
        if isDown {
            if !isRepeat { service.handleF13Down() }
        } else {
            service.handleF13Up()
        }
    }
    // F13 schlucken: Event geht NICHT an die aktive App weiter (sonst Piepton).
    return nil
}

@Observable
@MainActor
final class HotkeyService {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var keyMonitor: Any?
    private var activeCombo: WorkflowType?  // Which combo is currently held
    private var f13Active = false           // Dictation was started via F13

    private var f13EventTap: CFMachPort?
    private var f13RunLoopSource: CFRunLoopSource?

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?
    var f13DictationEnabled = false {
        didSet {
            guard oldValue != f13DictationEnabled else { return }
            if f13DictationEnabled {
                startF13Tap()
            } else {
                stopF13Tap()
            }
        }
    }

    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleFlags(event)
            }
            return event
        }
        // Escape key monitor for toggle mode
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in
                if event.keyCode == 53 { // Escape
                    self?.handleEscape()
                }
            }
        }
        if f13DictationEnabled, f13EventTap == nil {
            startF13Tap()
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        globalMonitor = nil
        localMonitor = nil
        keyMonitor = nil
        stopF13Tap()
    }

    // MARK: - F13 Event Tap

    private func startF13Tap() {
        guard f13EventTap == nil else { return }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: f13TapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Ohne Bedienungshilfen-Freigabe gibt es keinen Tap. Die Freigabe
            // wird ohnehin fürs Auto-Einfügen benötigt und beim Diktat erfragt.
            return
        }

        f13EventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        f13RunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopF13Tap() {
        if let tap = f13EventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = f13RunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        f13EventTap = nil
        f13RunLoopSource = nil
        f13Active = false
    }

    func reenableF13Tap() {
        if let tap = f13EventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func handleF13Down() {
        guard f13DictationEnabled, activeCombo == nil else { return }
        f13Active = true
        activeCombo = .transcription
        onHotkeyEvent?(.down(.transcription))
    }

    func handleF13Up() {
        guard f13Active else { return }
        f13Active = false
        activeCombo = nil
        onHotkeyEvent?(.up(.transcription))
    }

    // MARK: - Modifier-Kombos (fn + ...)

    private func handleFlags(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // fn + Shift + Control -> local transcription
        if flags == [.function, .shift, .control] {
            if activeCombo == nil {
                activeCombo = .localTranscription
                onHotkeyEvent?(.down(.localTranscription))
            }
            return
        }

        // fn + Shift -> transcription
        if flags == [.function, .shift] {
            if activeCombo == nil {
                activeCombo = .transcription
                onHotkeyEvent?(.down(.transcription))
            }
            return
        }

        // fn + Control -> Textverbesserer
        if flags == [.function, .control] {
            if activeCombo == nil {
                activeCombo = .textImprover
                onHotkeyEvent?(.down(.textImprover))
            }
            return
        }

        // fn + Option -> Rage Mode
        if flags == [.function, .option] {
            if activeCombo == nil {
                activeCombo = .dampfAblassen
                onHotkeyEvent?(.down(.dampfAblassen))
            }
            return
        }

        // fn + Command -> Emoji Mode
        if flags == [.function, .command] {
            if activeCombo == nil {
                activeCombo = .emojiText
                onHotkeyEvent?(.down(.emojiText))
            }
            return
        }

        // Keys released -- fire up event.
        // Skip while F13 holds the dictation: a modifier tap must not end it.
        if let combo = activeCombo, !f13Active {
            activeCombo = nil
            onHotkeyEvent?(.up(combo))
        }
    }

    private func handleEscape() {
        activeCombo = nil
        f13Active = false
        onHotkeyEvent?(.cancel)
    }
}
