import AppKit
import SwiftUI

/// The main window's second tab: a searchable, newest-first transcript
/// list.
///
/// Delete is deliberately not a modal confirmation — a modal for a routine,
/// reversible action is friction. Instead the row disappears immediately
/// and an undo bar appears at the bottom; the underlying `TranscriptStore`
/// deletion only actually happens a few seconds later, unless undone. That
/// state machine lives in `PendingDeletionController`, not here — this view
/// only reads its `pending` and calls `delete`/`undo`.
@MainActor
struct HistoryView: View {
    @ObservedObject var store: TranscriptStore
    @StateObject private var pendingDeletion: PendingDeletionController<PendingRow>

    @State private var transcripts: [Transcript] = []
    @State private var query = ""
    @State private var copiedID: UUID?

    /// A row mid-deletion: the transcript itself, plus where it sat in
    /// `transcripts` so undo can put it back in the same place.
    private struct PendingRow {
        let transcript: Transcript
        let index: Int
    }

    init(store: TranscriptStore) {
        self.store = store
        // `store` here is the initializer's own parameter, not `self.store`
        // (reading that before `self` is fully initialized isn't allowed) —
        // it's the same instance either way, just captured before `self`
        // exists.
        _pendingDeletion = StateObject(
            wrappedValue: PendingDeletionController(commit: { row in store.delete(row.transcript) })
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            divider

            Group {
                if transcripts.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let pending = pendingDeletion.pending {
                undoBar(for: pending)
            }
        }
        .background(Theme.Window.ink)
        .onAppear(perform: reload)
        .onChange(of: query) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reload()
        }
        // `TranscriptStore` has no `@Published` properties of its own, so
        // `add`/`delete` call `objectWillChange.send()` explicitly — this is
        // what lets a completed dictation, or a pending deletion committing
        // on its own timeout, update this list immediately instead of only
        // on the next appear/focus.
        .onReceive(store.objectWillChange) { reload() }
    }

    // MARK: - Data

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Re-fetches from the store.
    ///
    /// A transcript with a deletion still pending (inside the undo window)
    /// is filtered back out even though the store hasn't dropped it yet —
    /// otherwise a refresh mid-undo-window would make it reappear on its
    /// own.
    private func reload() {
        let results = trimmedQuery.isEmpty ? store.all() : store.search(query)
        if let pendingID = pendingDeletion.pending?.transcript.id {
            transcripts = results.filter { $0.id != pendingID }
        } else {
            transcripts = results
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Window.inkRaised)
            .frame(height: 1)
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.Window.textDim)
            TextField("Search transcripts", text: $query)
                .textFieldStyle(.plain)
                .foregroundColor(Theme.Window.textPrimary)
        }
        .padding(12)
    }

    // MARK: - Empty states

    /// No transcripts at all: the same plain invitation as the dashboard's
    /// empty state. A search that matched nothing instead says so and
    /// names the query, so the reader knows the store isn't actually empty.
    /// The check is against the *trimmed* query — a search of only spaces
    /// on an empty store should read as "nothing here yet", not as a
    /// literal failed match on whitespace.
    private var emptyState: some View {
        Group {
            if trimmedQuery.isEmpty {
                Text("Press your shortcut and start talking.")
            } else {
                Text("No transcripts match “\(query)”.")
            }
        }
        .font(.system(size: 14))
        .foregroundColor(Theme.Window.textDim)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(transcripts, id: \.id) { transcript in
                    row(transcript)
                    divider
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func row(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(RelativeDate.string(from: transcript.createdAt))
                Text("·")
                Text(DurationFormat.short(transcript.durationSeconds))
                    .font(Theme.monoFont)
                Text("·")
                Text("\(transcript.wordCount) words")
                    .font(Theme.monoFont)

                Spacer()

                Button {
                    copy(transcript)
                } label: {
                    Image(systemName: copiedID == transcript.id ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")

                Button {
                    delete(transcript)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
            .font(.system(size: 11))
            .foregroundColor(Theme.Window.textDim)

            Text(transcript.text)
                .font(.system(size: 13))
                .foregroundColor(Theme.Window.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
    }

    private func copy(_ transcript: Transcript) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript.text, forType: .string)

        copiedID = transcript.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == transcript.id { copiedID = nil }
        }
    }

    // MARK: - Delete + undo

    private func delete(_ transcript: Transcript) {
        guard let index = transcripts.firstIndex(where: { $0.id == transcript.id }) else { return }
        transcripts.remove(at: index)
        pendingDeletion.delete(PendingRow(transcript: transcript, index: index))
    }

    private func undoDelete() {
        guard let row = pendingDeletion.undo() else { return }
        transcripts.insert(row.transcript, at: min(row.index, transcripts.count))
    }

    private func undoBar(for pending: PendingRow) -> some View {
        HStack {
            Text("Transcript deleted.")
                .foregroundColor(Theme.Window.textDim)
            Spacer()
            Button("Undo") { undoDelete() }
                .buttonStyle(.borderless)
                .foregroundColor(Theme.Window.reed)
        }
        .font(.system(size: 12))
        .padding(12)
        .background(Theme.Window.inkRaised)
    }
}
