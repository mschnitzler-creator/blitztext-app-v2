import SwiftUI
import AppKit

struct HistoryWindowView: View {
    let appState: AppState
    @State private var store = TranscriptStore.shared
    @State private var searchText = ""
    @State private var copiedEntryID: UUID?
    @State private var selectedKind: TranscriptKind = .dictation

    private var entriesForSelectedKind: [TranscriptEntry] {
        store.entries.filter { $0.kind == selectedKind }
    }

    private var filteredEntries: [TranscriptEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entriesForSelectedKind }
        return entriesForSelectedKind.filter {
            $0.text.localizedCaseInsensitiveContains(query)
                || ($0.title?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Im Verlauf suchen ...", text: $searchText)
                    .textFieldStyle(.plain)
                Button("Alle löschen", role: .destructive) {
                    store.deleteAll()
                }
                .disabled(store.entries.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Picker("", selection: $selectedKind) {
                Text("Diktate").tag(TranscriptKind.dictation)
                Text("Meetings").tag(TranscriptKind.meeting)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            if filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: selectedKind == .meeting ? "person.2.wave.2" : "text.bubble")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(emptyStateText)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredEntries) { entry in
                            if entry.kind == .meeting {
                                meetingEntryRow(entry)
                            } else {
                                entryRow(entry)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private var emptyStateText: String {
        if entriesForSelectedKind.isEmpty {
            return selectedKind == .meeting
                ? "Noch keine Meetings im Verlauf."
                : "Noch keine Diktate im Verlauf."
        }
        return "Keine Treffer."
    }

    // MARK: - Diktat-Zeile (unverändert zur bisherigen Optik)

    @ViewBuilder
    private func entryRow(_ entry: TranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(entry.workflowType.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
                Spacer()
                copyButton(for: entry)
                deleteButton(for: entry)
            }
            Text(entry.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    // MARK: - Meeting-Zeile (Kopfzeile, editierbarer Titel, Teilnehmer)

    @ViewBuilder
    private func meetingEntryRow(_ entry: TranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(meetingHeaderText(for: entry))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                copyButton(for: entry)
                deleteButton(for: entry)
            }
            MeetingTitleField(entry: entry, store: store, appState: appState)
            if let participants = participantsLine(for: entry) {
                Text(participants)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let summary = entry.summary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Zusammenfassung")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(summary)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            MeetingEntryDetailView(entry: entry, store: store, appState: appState)
            DisclosureGroup {
                Text(entry.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
            } label: {
                Text("Transkript")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    /// Datum + Uhrzeit, plus Dauer falls bekannt: "12. Juni 2026, 14:30 · 32 min".
    private func meetingHeaderText(for entry: TranscriptEntry) -> String {
        var text = entry.createdAt.formatted(date: .abbreviated, time: .shortened)
        if let duration = entry.durationSeconds, duration > 0 {
            text += " \u{00B7} \(max(1, Int((duration / 60).rounded()))) min"
        }
        return text
    }

    /// "mit Thomas, Markus, Heidi": benannte Sprecher in Redereihenfolge plus
    /// manuelle Teilnehmer in Eingabereihenfolge, ohne Duplikate. Ohne Teilnehmer keine Zeile.
    private func participantsLine(for entry: TranscriptEntry) -> String? {
        let participants = MeetingTranscriptRenderer.combinedParticipants(
            segments: entry.segments ?? [],
            names: entry.speakerNames,
            extraParticipants: entry.extraParticipants
        )
        guard !participants.isEmpty else { return nil }
        return "mit " + participants.joined(separator: ", ")
    }

    // MARK: - Geteilte Buttons

    private func copyButton(for entry: TranscriptEntry) -> some View {
        Button {
            copy(entry)
        } label: {
            Label(
                copiedEntryID == entry.id ? "Kopiert" : "Kopieren",
                systemImage: copiedEntryID == entry.id ? "checkmark" : "doc.on.doc"
            )
            .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
    }

    private func deleteButton(for entry: TranscriptEntry) -> some View {
        Button {
            store.delete(entry)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11))
        }
        .buttonStyle(.borderless)
        .help("Eintrag löschen")
    }

    private func copy(_ entry: TranscriptEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        copiedEntryID = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedEntryID == entry.id { copiedEntryID = nil }
        }
    }
}

// MARK: - Re-Export nach Umbenennung

/// Schreibt die Markdown-Datei neu, löscht bei geändertem Dateinamen die alte
/// und merkt den neuen Namen am Eintrag (über die Store-Methode).
/// Rückgabe: Fehlertext für die UI, nil bei Erfolg oder deaktiviertem Export.
@MainActor
private func reexportAfterRename(
    entry: TranscriptEntry,
    store: TranscriptStore,
    appState: AppState
) -> String? {
    let folderPath = appState.appSettings.secondBrainFolderPath
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard appState.appSettings.secondBrainExportEnabled, !folderPath.isEmpty else { return nil }
    do {
        let filename = try SecondBrainExporter.exportReplacingOldFile(
            entry: entry,
            toFolder: folderPath
        )
        store.setExportFilename(entryID: entry.id, filename: filename)
        return nil
    } catch {
        return "Second-Brain-Export fehlgeschlagen: \(error.localizedDescription)"
    }
}

// MARK: - Inline editierbarer Meeting-Titel

private struct MeetingTitleField: View {
    let entry: TranscriptEntry
    let store: TranscriptStore
    let appState: AppState

    @State private var titleText = ""
    @State private var exportErrorText: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Titel", text: $titleText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .focused($isFocused)
                .onSubmit { commit() }

            if let exportErrorText {
                Text(exportErrorText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            titleText = entry.title ?? ""
        }
        .onChange(of: isFocused) { _, focused in
            // Auch beim Verlassen des Feldes übernehmen, nicht nur bei Return.
            if !focused {
                commit()
            }
        }
        .onChange(of: entry.title) { _, newTitle in
            if !isFocused {
                titleText = newTitle ?? ""
            }
        }
    }

    private func commit() {
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedTitle = entry.title ?? ""
        guard !trimmed.isEmpty, trimmed != storedTitle else {
            // Leer oder unverändert: Feld auf den gespeicherten Stand zurücksetzen.
            titleText = storedTitle
            return
        }

        guard let updated = store.renameTitle(entryID: entry.id, to: trimmed) else { return }
        titleText = updated.title ?? ""
        exportErrorText = reexportAfterRename(entry: updated, store: store, appState: appState)
    }
}

// MARK: - Meeting-Details (Zusammenfassung + Sprecher umbenennen)

private struct MeetingEntryDetailView: View {
    let entry: TranscriptEntry
    let store: TranscriptStore
    let appState: AppState

    @State private var isExpanded = false
    @State private var editedNames: [String: String] = [:]
    @State private var newParticipantName = ""
    @State private var exportErrorText: String?
    @FocusState private var focusedSpeakerID: String?

    private var speakerIDs: [String] {
        MeetingTranscriptRenderer.orderedSpeakerIDs(for: entry.segments ?? [])
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if !speakerIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sprecher umbenennen")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)

                        ForEach(Array(speakerIDs.enumerated()), id: \.element) { index, speakerID in
                            HStack(spacing: 8) {
                                Text("Sprecher \(index + 1)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 76, alignment: .leading)

                                TextField(
                                    "Name",
                                    text: Binding(
                                        get: { editedNames[speakerID] ?? "" },
                                        set: { editedNames[speakerID] = $0 }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11))
                                .focused($focusedSpeakerID, equals: speakerID)
                                .onSubmit { commitRename(for: speakerID) }
                            }
                        }
                    }
                }

                extraParticipantsSection

                if let exportErrorText {
                    Text(exportErrorText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 6)
        } label: {
            Text("Details")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .onAppear {
            editedNames = entry.speakerNames ?? [:]
        }
        .onChange(of: focusedSpeakerID) { previous, _ in
            // Auch beim Verlassen des Feldes übernehmen, nicht nur bei Return.
            if let previous {
                commitRename(for: previous)
            }
        }
    }

    /// Manuell ergänzte Teilnehmer: Liste mit Entfernen-Knopf plus Eingabefeld.
    /// Fall: die Sprechererkennung hat Personen zusammengelegt (Telefon auf laut).
    private var extraParticipantsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Weitere Teilnehmer")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(entry.extraParticipants ?? [], id: \.self) { name in
                HStack(spacing: 6) {
                    Text(name)
                        .font(.system(size: 11))
                    Button {
                        removeParticipant(name)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Teilnehmer entfernen")
                }
            }

            HStack(spacing: 8) {
                TextField("Name", text: $newParticipantName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { addParticipant() }
                Button("Hinzufügen") {
                    addParticipant()
                }
                .font(.system(size: 11))
                .disabled(
                    newParticipantName
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
            }
        }
    }

    private func commitRename(for speakerID: String) {
        let newName = editedNames[speakerID] ?? ""
        let storedName = entry.speakerNames?[speakerID] ?? ""
        guard newName.trimmingCharacters(in: .whitespacesAndNewlines) != storedName else { return }

        guard let updated = store.rename(entryID: entry.id, speakerID: speakerID, to: newName) else { return }

        // Export aktualisieren: gleicher Dateiname (Datum + Titel-Slug), Datei wird überschrieben.
        exportErrorText = reexportAfterRename(entry: updated, store: store, appState: appState)
    }

    private func addParticipant() {
        let name = newParticipantName
        newParticipantName = ""
        // Leere Namen und Duplikate ignoriert der Store (Rückgabe nil), kein Re-Export nötig.
        guard let updated = store.addParticipant(entryID: entry.id, name: name) else { return }
        exportErrorText = reexportAfterRename(entry: updated, store: store, appState: appState)
    }

    private func removeParticipant(_ name: String) {
        guard let updated = store.removeParticipant(entryID: entry.id, name: name) else { return }
        exportErrorText = reexportAfterRename(entry: updated, store: store, appState: appState)
    }
}
