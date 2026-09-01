import Combine
import Foundation
import SwiftData

@MainActor
final class TranscriptStore: ObservableObject {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    /// Fires once a mutation has actually landed — after `context.save()`
    /// returns successfully, never before and never on a failed save.
    ///
    /// This is deliberately not `objectWillChange`: that fires (correctly,
    /// per its own contract — see below) at the *top* of `add`/`delete`,
    /// before the mutation happens, so a view whose `.onReceive` runs
    /// synchronously inside that `send()` (Combine dispatches subscribers
    /// synchronously, nested inside the call) would still see the *old*
    /// state — a reload that runs before the transcript exists is exactly
    /// as stale as no reload at all. `didChange` is the signal views should
    /// actually observe to refresh; `objectWillChange` stays exactly as
    /// SwiftUI's convention says it should (fired before the change, for
    /// whatever else may come to rely on that contract) and is left alone.
    let didChange = PassthroughSubject<Void, Never>()

    init(inMemory: Bool = false) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: Transcript.self, configurations: config)
    }

    func all() -> [Transcript] {
        let descriptor = FetchDescriptor<Transcript>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    @discardableResult
    func add(text: String, duration: Double) -> Transcript {
        // No `@Published` property here to piggyback on — this is a plain
        // SwiftData wrapper, so views that want to know about new/removed
        // transcripts (the dashboard, history) have to be told explicitly.
        objectWillChange.send()
        let transcript = Transcript(text: text, durationSeconds: duration)
        context.insert(transcript)
        do {
            try context.save()
            didChange.send()
        } catch {
            NSLog("Reed: failed to save new transcript: \(error)")
        }
        return transcript
    }

    func delete(_ transcript: Transcript) {
        objectWillChange.send()
        context.delete(transcript)
        do {
            try context.save()
            didChange.send()
        } catch {
            NSLog("Reed: failed to save transcript deletion: \(error)")
        }
    }

    func search(_ query: String) -> [Transcript] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all() }
        // Filtering in memory: the history is small, and this avoids the
        // predicate-macro limits on localized comparison.
        return all().filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    func statsInputs() -> [StatsInput] {
        all().map {
            StatsInput(
                createdAt: $0.createdAt,
                durationSeconds: $0.durationSeconds,
                wordCount: $0.wordCount
            )
        }
    }
}
