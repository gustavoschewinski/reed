import Foundation

/// The "delete now, undo within a window" state machine behind
/// `HistoryView`'s per-row delete button — extracted out of the view so it
/// can be unit tested without driving SwiftUI.
///
/// Rules: exactly one pending slot. A second `delete(_:)` while something is
/// still pending commits that first item immediately rather than losing
/// track of it. `undo()` cancels the scheduled commit and hands the item
/// back. Left alone for `window`, the item commits on its own — exactly
/// once, even if its `Task` is cancelled after it has already started
/// running.
///
/// `@Published pending` is what the view observes (via `@ObservedObject`/
/// `@StateObject`) to show or hide the undo bar and keep it in sync with a
/// commit that fires on its own. `pendingCommitTask` is exposed (not
/// `private`) purely as a test seam: production never reads it, but a test
/// can `await` it to know the scheduled commit has actually run instead of
/// racing a real sleep.
@MainActor
final class PendingDeletionController<Item>: ObservableObject {
    @Published private(set) var pending: Item?
    private(set) var pendingCommitTask: Task<Void, Never>?

    private let window: Duration
    private let commit: (Item) -> Void

    /// Bumped on every `delete`/`undo`. A commit that fires for a
    /// generation that has since moved on (superseded by a second delete,
    /// or undone) is a no-op — belt-and-braces alongside `Task.cancel()`,
    /// which can't retroactively stop a continuation already past its
    /// suspension point.
    private var generation = 0

    init(window: Duration = .seconds(5), commit: @escaping (Item) -> Void) {
        self.window = window
        self.commit = commit
    }

    /// Moves `item` into the single pending slot, removing whatever was
    /// there before by committing it for real right away.
    func delete(_ item: Item) {
        if let previous = pending {
            pendingCommitTask?.cancel()
            commit(previous)
        }

        pending = item
        generation += 1
        let thisGeneration = generation

        pendingCommitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.window)
            guard !Task.isCancelled else { return }
            self.commitIfCurrent(generation: thisGeneration)
        }
    }

    /// Cancels the scheduled commit and hands back the item to reinstate,
    /// or `nil` if nothing was pending.
    @discardableResult
    func undo() -> Item? {
        guard let item = pending else { return nil }
        pendingCommitTask?.cancel()
        pendingCommitTask = nil
        pending = nil
        generation += 1
        return item
    }

    private func commitIfCurrent(generation: Int) {
        guard generation == self.generation, let item = pending else { return }
        commit(item)
        pending = nil
        pendingCommitTask = nil
    }
}
