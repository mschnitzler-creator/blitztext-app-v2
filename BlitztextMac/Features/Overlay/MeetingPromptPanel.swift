import SwiftUI
import AppKit

/// Schwebendes Frage-Banner am unteren Bildschirmrand (Notion-Stil).
/// Fragt bei erkanntem Meeting, ob die Aufnahme starten soll.
/// Ersetzt die frühere macOS-Mitteilung: die brauchte eine Erlaubnis,
/// die Nutzer oft ablehnen, und war leicht zu übersehen.
@MainActor
final class MeetingPromptPanelController {
    private var panel: NSPanel?
    private var autoHideTask: Task<Void, Never>?

    /// Nach 45 Sekunden ohne Reaktion verschwindet das Banner von selbst.
    private static let autoHideSeconds: UInt64 = 45

    func show(
        appName: String,
        modeLabel: String,
        onRecord: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        let view = MeetingPromptView(
            appName: appName,
            modeLabel: modeLabel,
            onRecord: { [weak self] in
                self?.hide()
                onRecord()
            },
            onDismiss: { [weak self] in
                self?.hide()
                onDismiss()
            }
        )

        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 56),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .statusBar
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            // Buttons müssen klickbar sein, anders als beim Aufnahme-Overlay.
            panel.ignoresMouseEvents = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }
        panel?.contentViewController = NSHostingController(rootView: view)
        position()
        panel?.orderFrontRegardless()
        scheduleAutoHide()
    }

    func hide() {
        autoHideTask?.cancel()
        autoHideTask = nil
        panel?.orderOut(nil)
    }

    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - panel.frame.width / 2
        // Oben mittig, unterhalb der Menüleiste.
        let y = frame.maxY - panel.frame.height - 12
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.autoHideSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }
}

struct MeetingPromptView: View {
    let appName: String
    let modeLabel: String
    let onRecord: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(appName)-Meeting erkannt")
                    .font(.system(size: 12, weight: .bold))
                Text(modeLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Aufzeichnen", action: onRecord)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Ignorieren", action: onDismiss)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial))
        .frame(width: 380, height: 56)
    }
}
