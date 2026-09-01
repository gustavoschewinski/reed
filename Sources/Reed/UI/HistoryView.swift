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
    @FocusState private var searchFocused: Bool

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
            searchBar
            Rule()

            Group {
                if transcripts.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The undo bar floats over the list rather than pushing it up. A
        // band that displaces the content makes every row jump the moment
        // you delete one, which is exactly when you're still reading them.
        .overlay(alignment: .bottom) {
            if let pending = pendingDeletion.pending {
                undoToast(for: pending)
                    .padding(Theme.Space.lg)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: pendingDeletion.pending != nil)
        .onAppear(perform: reload)
        .onChange(of: query) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            reload()
        }
        // `store.didChange` — not `objectWillChange` — fires after a
        // mutation has actually landed (see its doc comment on
        // `TranscriptStore`), so this is what lets a completed dictation,
        // or a pending deletion committing on its own timeout, update this
        // list immediately with correct data, instead of either reading
        // stale state or waiting for the next appear/focus.
        .onReceive(store.didChange) { reload() }
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

    // MARK: - Search

    /// A borderless field that only draws an outline once it has focus.
    /// At rest it's a magnifier and a placeholder, which is all a search
    /// field on a list of forty items needs to be; the outline appears
    /// exactly when it means something, namely that typing will go here.
    private var searchBar: some View {
        HStack(spacing: Theme.Space.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(Theme.Window.textDim)

            TextField("Search transcripts", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Window.textPrimary)
                .focused($searchFocused)

            if !query.isEmpty {
                IconButton(systemName: "xmark.circle.fill", help: "Clear search") {
                    query = ""
                }
            }

            if !transcripts.isEmpty {
                Text(countLabel)
                    .font(Theme.Typography.dataSmall)
                    .foregroundColor(Theme.Window.textDim)
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(
                    searchFocused ? Theme.Window.reed : Color.clear,
                    lineWidth: 1
                )
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.md)
    }

    private var countLabel: String {
        transcripts.count == 1 ? "1" : transcripts.count.formatted()
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
                EmptyState(
                    systemImage: "waveform",
                    title: "Press your shortcut and start talking.",
                    detail: "Everything you dictate is kept here, on this Mac."
                )
            } else {
                EmptyState(
                    systemImage: "magnifyingglass",
                    title: "No transcripts match “\(query)”.",
                    detail: "Try a shorter search."
                )
            }
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(transcripts, id: \.id) { transcript in
                    HistoryRow(
                        transcript: transcript,
                        isCopied: copiedID == transcript.id,
                        copy: { copy(transcript) },
                        delete: { delete(transcript) }
                    )
                    Rule()
                }
            }
            .padding(.horizontal, Theme.Space.xl)
        }
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

    private func undoToast(for pending: PendingRow) -> some View {
        HStack(spacing: Theme.Space.lg) {
            Text("Transcript deleted.")
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Window.textPrimary)
            Button("Undo") { undoDelete() }
                .buttonStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Window.reed)
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.md)
        // The one element in the window that floats above another surface,
        // so it's the one that gets its own material — it has to stay
        // readable over whichever row it happens to cover.
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.floating, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.floating, style: .continuous)
                .strokeBorder(Theme.Window.hairline, lineWidth: 1)
        }
    }
}

// MARK: - Row

/// One transcript: when it happened and how big it was, then the text.
///
/// Copy and delete only appear under the pointer. They're always in the
/// view tree — hidden by opacity, not by a branch — so VoiceOver still
/// reaches them, and a pointer close enough to click one is by definition
/// close enough to have revealed it.
@MainActor
private struct HistoryRow: View {
    let transcript: Transcript
    let isCopied: Bool
    let copy: () -> Void
    let delete: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Text(RelativeDate.string(from: transcript.createdAt))
                    .font(Theme.Typography.caption)
                Separator()
                Text(DurationFormat.short(transcript.durationSeconds))
                    .font(Theme.Typography.dataSmall)
                Separator()
                Text("\(transcript.wordCount) words")
                    .font(Theme.Typography.dataSmall)

                Spacer()

                HStack(spacing: Theme.Space.xs) {
                    IconButton(
                        systemName: isCopied ? "checkmark" : "doc.on.doc",
                        help: "Copy",
                        tint: isCopied ? Theme.Window.reed : Theme.Window.textDim,
                        action: copy
                    )
                    IconButton(systemName: "trash", help: "Delete", action: delete)
                }
                // Copy holds its checkmark for a beat after the click, and
                // that confirmation has to survive the pointer leaving.
                .opacity(isHovered || isCopied ? 1 : 0)
            }
            .foregroundColor(Theme.Window.textDim)

            Text(transcript.text)
                .font(Theme.Typography.body)
                .foregroundColor(Theme.Window.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Theme.Space.md)
        .hoverHighlight($isHovered)
    }
}

/// The dot between two pieces of row metadata.
private struct Separator: View {
    var body: some View {
        Text("·")
            .font(Theme.Typography.caption)
            .foregroundColor(Theme.Window.textDim.opacity(0.6))
    }
}
