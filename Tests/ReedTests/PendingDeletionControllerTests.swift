import Testing
@testable import Reed

private struct Note: Equatable {
    let id: Int
}

@MainActor
private final class Recorder {
    var committed: [Note] = []
    func commit(_ note: Note) { committed.append(note) }
}

@MainActor
@Test func deleteSchedulesACommitAfterTheWindow() async throws {
    let recorder = Recorder()
    let controller = PendingDeletionController<Note>(
        window: .milliseconds(5), commit: recorder.commit
    )

    controller.delete(Note(id: 1))
    // Scheduled, not immediate: nothing has committed synchronously yet.
    #expect(recorder.committed.isEmpty)

    await controller.pendingCommitTask?.value
    #expect(recorder.committed == [Note(id: 1)])
}

@MainActor
@Test func undoBeforeTheDeadlineCancelsTheCommitAndTheItemSurvives() async throws {
    let recorder = Recorder()
    let controller = PendingDeletionController<Note>(
        window: .milliseconds(50), commit: recorder.commit
    )

    controller.delete(Note(id: 1))
    let scheduled = controller.pendingCommitTask
    let restored = controller.undo()

    #expect(restored == Note(id: 1))
    #expect(controller.pending == nil)

    // Let the (cancelled) task actually finish before asserting nothing
    // committed, rather than trusting a timing race.
    await scheduled?.value
    #expect(recorder.committed.isEmpty)
}

@MainActor
@Test func aSecondDeleteCommitsThePreviousItemImmediately() async throws {
    let recorder = Recorder()
    let controller = PendingDeletionController<Note>(
        window: .seconds(5), commit: recorder.commit
    )

    controller.delete(Note(id: 1))
    controller.delete(Note(id: 2))

    // Immediately, synchronously — no need to await anything: the first
    // item is bumped out of the single pending slot by the second delete,
    // not by its own timeout.
    #expect(recorder.committed == [Note(id: 1)])
    #expect(controller.pending == Note(id: 2))
}

@MainActor
@Test func aTimeoutCommitsExactlyOnce() async throws {
    let recorder = Recorder()
    let controller = PendingDeletionController<Note>(
        window: .milliseconds(5), commit: recorder.commit
    )

    controller.delete(Note(id: 1))
    await controller.pendingCommitTask?.value

    #expect(recorder.committed == [Note(id: 1)])
    #expect(controller.pending == nil)
}
