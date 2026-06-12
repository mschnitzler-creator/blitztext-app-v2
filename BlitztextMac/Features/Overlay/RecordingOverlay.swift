import SwiftUI
import AppKit

/// Kleines schwebendes Statusfenster am unteren Bildschirmrand,
/// sichtbar während Aufnahme und Verarbeitung (wie bei Wispr Flow).
@MainActor
final class RecordingOverlayController {
    private var panel: NSPanel?
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func update(for status: MenuBarStatus) {
        guard appState.appSettings.showRecordingOverlay else {
            hide()
            return
        }

        let dictationVisible: Bool
        switch status {
        case .recording, .processing:
            dictationVisible = true
        case .idle, .success, .error:
            dictationVisible = false
        }

        if dictationVisible || appState.meetingWorkflow.isRecording {
            show()
        } else {
            hide()
        }
    }

    private func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 230, height: 44),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.contentViewController = NSHostingController(
                rootView: RecordingOverlayView(appState: appState)
            )
            self.panel = panel
        }
        position()
        panel?.orderFrontRegardless()
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - panel.frame.width / 2
        let y = frame.minY + 12
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func hide() {
        panel?.orderOut(nil)
    }
}

struct RecordingOverlayView: View {
    let appState: AppState

    private var isRecording: Bool {
        if case .recording = appState.menuBarStatus { return true }
        return false
    }

    /// Diktat-Anzeige hat Vorrang, wenn Diktat und Meeting gleichzeitig laufen.
    private var isDictationVisible: Bool {
        switch appState.menuBarStatus {
        case .recording, .processing:
            return true
        case .idle, .success, .error:
            return false
        }
    }

    private var audioLevel: Float {
        (appState.activeWorkflow as? TranscriptionWorkflow)?.audioLevel ?? 0
    }

    var body: some View {
        HStack(spacing: 8) {
            if isDictationVisible {
                if isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 9, height: 9)
                    LevelBarsView(level: audioLevel)
                    Text("Aufnahme läuft")
                        .font(.system(size: 11, weight: .medium))
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Wird transkribiert ...")
                        .font(.system(size: 11, weight: .medium))
                }
            } else if case .recording(let since) = appState.meetingWorkflow.phase {
                Circle()
                    .fill(Color.red)
                    .frame(width: 9, height: 9)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Meeting läuft \u{00B7} \(MenuBarView.meetingTimerText(since: since, now: context.date))")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(.ultraThinMaterial))
        .frame(width: 230, height: 44)
    }
}

private struct LevelBarsView: View {
    let level: Float

    private static let weights: [CGFloat] = [0.6, 0.85, 1.0, 0.85, 0.6]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 3, height: barHeight(index))
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.08), value: level)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let minHeight: CGFloat = 4
        let maxHeight: CGFloat = 16
        return minHeight + (maxHeight - minHeight) * CGFloat(level) * Self.weights[index]
    }
}
