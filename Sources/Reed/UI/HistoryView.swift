import AppKit
import SwiftUI

/// The main window's second tab: a searchable, newest-first transcript
/// list.
///
/// Delete is deliberately not a modal confirmation — a modal for a routine,
/// reversible action is friction. Instead the row disappears immediately
/// and an undo bar appears at the bottom; the underlying `TranscriptStore`
/// deletion only actually happens a few seconds later, unless undone.
@MainActor
struct HistoryView: View {
    @ObservedObject var store: TranscriptStore

    @State private var transcripts: [Transcript] = []
    @State private var query = ""
    @State private var pendingDeletion: PendingDeletion?
    @State private var copiedID: UUID?

    /// How long the undo bar stays up before the deletion actually commits
    /// to the store.
    private static let undoWindow: Duration = .seconds(5)

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

            if let pendingDeletion {
                undoBar(for: pendingDeletion)
            }
        }
        .background(Theme.Window.ink)
        .onAppear(perform: reload)
        .onChange(of: query) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reload()
        }
    }

    // MARK: - Data

    /// Re-fetches from the store. `TranscriptStore` publishes no change
    /// events of its own (it has no `@Published` state — `add`/`delete`
    /// mutate SwiftData directly), so this view refreshes itself on
    /// appearance and whenever the window regains focus rather than relying
    /// on Combine to notice a change.
    ///
    /// A transcript with a deletion still pending (inside the undo window)
    /// is filtered back out even though the store hasn't dropped it yet —
    /// otherwise a window-focus refresh mid-undo-window would make it
    /// reappear on its own.
    private func reload() {
        let results = query.isEmpty ? store.all() : store.search(query)
        if let pendingDeletion {
            transcripts = results.filter { $0.id != pendingDeletion.transcript.id }
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
    private var emptyState: some View {
        Group {
            if query.isEmpty {
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

    private struct PendingDeletion {
        let transcript: Transcript
        let index: Int
        let task: Task<Void, Never>
    }

    private func delete(_ transcript: Transcript) {
        guard let index = transcripts.firstIndex(where: { $0.id == transcript.id }) else { return }
        transcripts.remove(at: index)

        // Only one undo slot: if a previous pending deletion hasn't
        // committed yet, commit it now rather than silently drop it.
        if let previous = pendingDeletion {
            previous.task.cancel()
            store.delete(previous.transcript)
        }

        let task = Task { @MainActor in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            store.delete(transcript)
            pendingDeletion = nil
        }
        pendingDeletion = PendingDeletion(transcript: transcript, index: index, task: task)
    }

    private func undoDelete() {
        guard let pending = pendingDeletion else { return }
        pending.task.cancel()
        transcripts.insert(pending.transcript, at: min(pending.index, transcripts.count))
        pendingDeletion = nil
    }

    private func undoBar(for pending: PendingDeletion) -> some View {
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
